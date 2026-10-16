#!/bin/bash
# install-eksctl2.sh - finish the eksctl install using the recovered download.
# The tarball matched its published digest; the earlier failure was only because
# the checksum file lists two lines for this asset (the tarball and a .sig), so
# the expected digest must be taken from the first matching line only.
set -uo pipefail
OS_ARCH="$(dpkg --print-architecture)"
ASSET="eksctl_Linux_${OS_ARCH}.tar.gz"

TMP="$(ls -d /tmp/tmp.* 2>/dev/null | while read -r d; do [ -f "${d}/${ASSET}" ] && echo "${d}"; done | head -n 1)"
echo "recovered_tmp_dir=${TMP}"
if [ -z "${TMP}" ]; then
  TMP="$(mktemp -d)"
  curl -fsSL "https://github.com/eksctl-io/eksctl/releases/latest/download/${ASSET}" -o "${TMP}/${ASSET}"
fi

if [ ! -f "${TMP}/eksctl_checksums.txt" ]; then
  curl -fsSL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_checksums.txt" -o "${TMP}/eksctl_checksums.txt"
fi

echo "asset_bytes=$(wc -c < "${TMP}/${ASSET}")"
echo "matching checksum lines:"
grep -F "${ASSET}" "${TMP}/eksctl_checksums.txt" | sed 's/^/  /'

EXPECTED="$(grep -F "${ASSET}" "${TMP}/eksctl_checksums.txt" | head -n 1 | awk '{print $1}')"
ACTUAL="$(sha256sum "${TMP}/${ASSET}" | awk '{print $1}')"
echo "expected=${EXPECTED}"
echo "actual=${ACTUAL}"

if [ -z "${EXPECTED}" ] || [ "${EXPECTED}" != "${ACTUAL}" ]; then
  echo "EKSCTL_INSTALL=failed_checksum"
  exit 1
fi

tar -xzf "${TMP}/${ASSET}" -C "${TMP}"
install -o root -g root -m 0755 "${TMP}/eksctl" /usr/local/bin/eksctl
rm -rf "${TMP}"
echo "eksctl_version=$(eksctl version 2>&1)"
echo "EKSCTL_INSTALL=success"
