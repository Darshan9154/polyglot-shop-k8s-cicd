#!/bin/bash
# install-eksctl.sh - install eksctl with checksum verification and arch fallback.
# Run standalone so its output is not overwritten by a larger script's redirect.
set -uo pipefail
OS_ARCH="$(dpkg --print-architecture)"

echo "arch=${OS_ARCH}"
if command -v eksctl >/dev/null 2>&1; then
  echo "already installed: $(eksctl version)"
  exit 0
fi

latest_tag="$(curl -fsSL https://api.github.com/repos/eksctl-io/eksctl/releases/latest | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)"
echo "latest_tag=${latest_tag}"

TMP="$(mktemp -d)"
checksums_ok=false
curl -fsSL "https://github.com/eksctl-io/eksctl/releases/download/${latest_tag}/eksctl_checksums.txt" -o "${TMP}/eksctl_checksums.txt" && checksums_ok=true
if [ "${checksums_ok}" != true ]; then
  curl -fsSL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_checksums.txt" -o "${TMP}/eksctl_checksums.txt" && checksums_ok=true
fi
echo "checksums_downloaded=${checksums_ok}"
[ "${checksums_ok}" = true ] && grep -c . "${TMP}/eksctl_checksums.txt" | sed 's/^/checksum_lines=/'

for name in "eksctl_Linux_${OS_ARCH}" "eksctl_linux_${OS_ARCH}"; do
  for base in "https://github.com/eksctl-io/eksctl/releases/download/${latest_tag}" "https://github.com/eksctl-io/eksctl/releases/latest/download"; do
    echo "trying: ${base}/${name}.tar.gz"
    if curl -fsSL "${base}/${name}.tar.gz" -o "${TMP}/asset.tar.gz"; then
      echo "download ok, bytes=$(wc -c < "${TMP}/asset.tar.gz")"
      line="$(grep -F "${name}.tar.gz" "${TMP}/eksctl_checksums.txt" || true)"
      actual="$(sha256sum "${TMP}/asset.tar.gz" | awk '{print $1}')"
      expected="$(echo "${line}" | awk '{print $1}')"
      echo "actual=${actual}"
      echo "expected=${expected}"
      if [ -n "${expected}" ] && [ "${actual}" = "${expected}" ]; then
        tar -xzf "${TMP}/asset.tar.gz" -C "${TMP}"
        if [ -f "${TMP}/eksctl" ]; then
          install -o root -g root -m 0755 "${TMP}/eksctl" /usr/local/bin/eksctl
          echo "eksctl_installed=$(eksctl version 2>&1)"
          rm -rf "${TMP}"
          exit 0
        fi
        echo "tarball extracted but no eksctl binary inside"
      else
        echo "checksum mismatch or missing line for ${name}"
      fi
    fi
  done
done

echo "EKSCTL_INSTALL=failed"
rm -rf "${TMP}"
exit 1
