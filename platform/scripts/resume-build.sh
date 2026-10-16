#!/bin/bash
# resume-build.sh - install the two tools that the first bootstrap aborted on,
# then build every image from deployment-me/docker-compose.yml.
# Safe to re-run: each step checks state first and the build is idempotent.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH="$PATH:/root/.local/bin:/home/ubuntu/.local/bin"
OS_ARCH="$(dpkg --print-architecture)"
REPO_DIR='/opt/polyglot-shop/source/polyglot-shop-k8s-cicd'
DEPLOY_DIR="${REPO_DIR}/deployment-me"

echo "===== eksctl ====="
if command -v eksctl >/dev/null 2>&1; then
  echo "already installed: $(eksctl version 2>/dev/null)"
else
  TMP="$(mktemp -d)"
  TARBALL="eksctl_Linux_${OS_ARCH}.tar.gz"
  ok=false
  for attempt in 1 2; do
    if curl -fsSL "https://github.com/eksctl-io/eksctl/releases/latest/download/${TARBALL}" -o "${TMP}/${TARBALL}" \
       && curl -fsSL https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_checksums.txt -o "${TMP}/eksctl_checksums.txt"; then
      LINE="$(grep -F "${TARBALL}" "${TMP}/eksctl_checksums.txt" || true)"
      if [ -z "${LINE}" ]; then echo "attempt ${attempt}: no checksum line"; continue; fi
      ACTUAL="$(sha256sum "${TMP}/${TARBALL}" | awk '{print $1}')"
      EXPECTED="$(echo "${LINE}" | awk '{print $1}')"
      if [ "${ACTUAL}" != "${EXPECTED}" ]; then echo "attempt ${attempt}: checksum mismatch"; continue; fi
      tar -xzf "${TMP}/${TARBALL}" -C "${TMP}"
      install -o root -g root -m 0755 "${TMP}/eksctl" /usr/local/bin/eksctl
      echo "installed and checksum verified"
      ok=true
      break
    fi
  done
  rm -rf "${TMP}"
  [ "${ok}" = true ] || echo "WARN: eksctl still not installed"
fi

echo "===== checkov ====="
if command -v checkov >/dev/null 2>&1; then
  echo "already installed"
else
  apt-get install -y --no-install-recommends pipx >/dev/null
  pipx ensurepath >/dev/null 2>&1 || true
  if pipx install checkov; then
    echo "installed via pipx"
  else
    echo "WARN: pipx failed; falling back to pip3"
    pip3 install --break-system-packages checkov || echo "WARN: checkov install failed"
  fi
fi

echo "===== build ====="
cd "${DEPLOY_DIR}" || exit 1
echo "memory available: $(free -m | awk '/Mem:/{print $7}') MiB"
echo "disk free: $(df -h / | awk 'NR==2{print $4}')"

if docker compose build 2>&1; then
  echo "BUILD_STATUS=success"
else
  echo "BUILD_STATUS=failed"
fi

echo "===== images ====="
docker images --format '{{.Repository}}:{{.Tag}} {{.Size}}'
