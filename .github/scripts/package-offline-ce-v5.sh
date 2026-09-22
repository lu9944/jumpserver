#!/usr/bin/env bash
set -Eeuo pipefail

mode=${1:?usage: package-offline-ce-v5.sh package|verify PACKAGE_DIR}
package_dir=${2:?usage: package-offline-ce-v5.sh package|verify PACKAGE_DIR}
image_dir="${package_dir}/scripts/images"
docker_dir="${package_dir}/scripts/docker"

images=(
  jumpserver/chen:v5.0.0-ce
  jumpserver/core:v5.0.0-ce
  jumpserver/kael:v5.0.0-ce
  jumpserver/koko:v5.0.0-ce
  openbao/openbao:2.6.0
  postgres:16.15-bookworm
  redis:7.4.10-bookworm
  jumpserver/web:v5.0.0-ce
)

[[ -f "${package_dir}/scripts/const.sh" ]] || {
  echo "Installer v5.0.0 was not extracted into ${package_dir}" >&2
  exit 1
}
[[ $(uname -m) == x86_64 ]] || {
  echo 'This package targets Linux x86_64 only' >&2
  exit 1
}

write_settings() {
  cat > "${package_dir}/static.env" <<'EOF'
export VERSION="v5.0.0-ce"
export NAMESPACE="jumpserver"
export USE_XPACK="0"
export MAGNUS_ENABLED="0"
export RAZOR_ENABLED="0"
export JDMC_ENABLED="0"
export VIDEO_ENABLED="0"
export NEC_ENABLED="0"
export XRDP_ENABLED="0"
EOF

  {
    printf 'version=v5.0.0-ce\nplatform=linux/amd64\nnamespace=jumpserver\n\n'
    for image in "${images[@]}"; do
      printf '%s.zst\n' "${image##*/}"
    done
  } > "${package_dir}/OFFLINE_IMAGES.txt"
}

download_checked() {
  local url=$1 expected=$2 destination=$3
  curl --fail --location --retry 3 --retry-delay 5 --output "${destination}" "${url}"
  printf '%s  %s\n' "${expected}" "${destination}" | sha256sum --check --status
}

verify_package() {
  local image basename archive id_file expected_hash actual_hash

  [[ $(grep -c '^.*\.zst$' "${package_dir}/OFFLINE_IMAGES.txt") -eq ${#images[@]} ]]
  grep -Fxq 'export VERSION="v5.0.0-ce"' "${package_dir}/static.env"
  grep -Fxq 'export USE_XPACK="0"' "${package_dir}/static.env"
  printf '%s  %s\n' "${DOCKER_BIN_SHA256}" "${docker_dir}/docker.tar.gz" | sha256sum --check
  printf '%s  %s\n' "${COMPOSE_BIN_SHA256}" "${docker_dir}/docker-compose" | sha256sum --check

  for image in "${images[@]}"; do
    basename=${image##*/}
    archive="${image_dir}/${basename}.zst"
    id_file="${image_dir}/${basename}.sha256"
    [[ -s "${archive}" && -s "${id_file}" && -s "${archive}.sha256" ]]
    [[ $(<"${id_file}") =~ ^sha256:[a-f0-9]{64}$ ]]
    grep -Fxq "${basename}.zst" "${package_dir}/OFFLINE_IMAGES.txt"
    expected_hash=$(awk 'NR == 1 { print $1 }' "${archive}.sha256")
    actual_hash=$(sha256sum "${archive}" | awk '{ print $1 }')
    [[ "${expected_hash}" == "${actual_hash}" ]] || {
      echo "SHA-256 mismatch: ${archive}" >&2
      exit 1
    }
    zstd --test --quiet "${archive}"
  done
}

case "${mode}" in
  package)
    write_settings
    ;;
  verify)
    ;;
  *)
    echo "Unknown mode: ${mode}" >&2
    exit 1
    ;;
esac

# The upstream installer pins the Docker and Compose binaries and their checksums.
# shellcheck source=/dev/null
source "${package_dir}/scripts/const.sh"

if [[ "${mode}" == package ]]; then
  mkdir -p "${image_dir}" "${docker_dir}"
  docker info >/dev/null
  download_checked "${DOCKER_BIN_URL}" "${DOCKER_BIN_SHA256}" "${docker_dir}/docker.tar.gz"
  download_checked "${COMPOSE_BIN_URL}" "${COMPOSE_BIN_SHA256}" "${docker_dir}/docker-compose"
  chmod +x "${docker_dir}/docker-compose"

  for image in "${images[@]}"; do
    basename=${image##*/}
    archive="${image_dir}/${basename}.zst"
    echo "Packaging ${image}"
    docker pull --platform linux/amd64 "${image}"
    image_id=$(docker image inspect --format '{{.ID}}' "${image}")
    docker save "${image}" | zstd -T0 -3 --quiet -o "${archive}"
    printf '%s\n' "${image_id}" > "${image_dir}/${basename}.sha256"
    (cd "${image_dir}" && sha256sum "${basename}.zst" > "${basename}.zst.sha256")

    # Exercise the same compressed archive path that the offline installer loads.
    docker image rm "${image}" >/dev/null
    docker load --input "${archive}"
    loaded_id=$(docker image inspect --format '{{.ID}}' "${image}")
    [[ "${loaded_id}" == "${image_id}" ]]
    docker image rm "${image}" >/dev/null
  done
fi

verify_package
echo 'Offline CE package verified'
