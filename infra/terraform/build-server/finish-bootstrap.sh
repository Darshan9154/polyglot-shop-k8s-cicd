#!/bin/bash
# finish-bootstrap.sh - completes the steps that did not run because the first
# eksctl checksum check aborted the bootstrap. Safe to re-run: every step checks
# before it installs.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH="$PATH:/root/.local/bin:/home/ubuntu/.local/bin"
OS_ARCH="$(dpkg --print-architecture)"
REPOSITORY_URL='https://github.com/aws-containers/retail-store-sample-app.git'
REPOSITORY_DIR='/opt/retail-store/source/retail-store-sample-app'
EKSCTL_INSTALLED=false

echo "==> eksctl"
if command -v eksctl >/dev/null 2>&1; then
  echo "already installed"
  EKSCTL_INSTALLED=true
else
  TMP="$(mktemp -d)"
  TARBALL="$(basename "$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_${OS_ARCH}.tar.gz")")"
  echo "asset resolved to ${TARBALL}"
  for attempt in 1 2; do
    if curl -fsSL "https://github.com/eksctl-io/eksctl/releases/latest/download/${TARBALL}" -o "${TMP}/${TARBALL}" \
       && curl -fsSL https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_checksums.txt -o "${TMP}/eksctl_checksums.txt"; then
      LINE="$(grep -F "${TARBALL}" "${TMP}/eksctl_checksums.txt" || true)"
      if [ -z "${LINE}" ]; then
        echo "attempt ${attempt}: no checksum line for ${TARBALL}"
        continue
      fi
      ACTUAL="$(sha256sum "${TMP}/${TARBALL}" | awk '{print $1}')"
      EXPECTED="$(echo "${LINE}" | awk '{print $1}')"
      if [ "${ACTUAL}" != "${EXPECTED}" ]; then
        echo "attempt ${attempt}: checksum mismatch"
        continue
      fi
      tar -xzf "${TMP}/${TARBALL}" -C "${TMP}"
      install -o root -g root -m 0755 "${TMP}/eksctl" /usr/local/bin/eksctl
      EKSCTL_INSTALLED=true
      echo "installed and checksum verified"
      break
    else
      echo "attempt ${attempt}: download failed"
    fi
  done
  rm -rf "${TMP}"
fi

echo "==> terraform"
if command -v terraform >/dev/null 2>&1; then
  echo "already installed"
else
  SUITE="$(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs)"
  wget -qO- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
  echo "deb [arch=${OS_ARCH} signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${SUITE} main" > /etc/apt/sources.list.d/hashicorp.list
  apt-get update -y >/dev/null
  apt-get install -y --no-install-recommends terraform
fi

echo "==> trivy"
if command -v trivy >/dev/null 2>&1; then
  echo "already installed"
else
  wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | gpg --dearmor | tee /usr/share/keyrings/trivy.gpg >/dev/null
  echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" > /etc/apt/sources.list.d/trivy.list
  apt-get update -y >/dev/null
  apt-get install -y --no-install-recommends trivy
fi

echo "==> checkov"
if command -v checkov >/dev/null 2>&1 || [ -x /root/.local/bin/checkov ]; then
  echo "already installed"
else
  apt-get install -y --no-install-recommends pipx
  pipx ensurepath
  if ! pipx install checkov; then
    echo "WARN: pipx install failed; falling back to pip3"
    pip3 install --break-system-packages checkov
  fi
fi

echo "==> ssm agent"
snap list amazon-ssm-agent >/dev/null 2>&1 && echo "snap package present" || echo "using preinstalled deb agent"

echo "==> clone"
mkdir -p "$(dirname "${REPOSITORY_DIR}")"
if [ -d "${REPOSITORY_DIR}/.git" ]; then
  git -C "${REPOSITORY_DIR}" fetch --depth 1 origin || true
else
  git clone --depth 1 "${REPOSITORY_URL}" "${REPOSITORY_DIR}"
fi
git -C "${REPOSITORY_DIR}" remote set-url origin "${REPOSITORY_URL}"
chown -R ubuntu:ubuntu "${REPOSITORY_DIR}"

echo "==> write readiness marker"
{
  echo "bootstrap_complete=$(date -Is)"
  echo "eksctl_installed=${EKSCTL_INSTALLED}"
  echo "repository=${REPOSITORY_URL}"
  echo "repository_dir=${REPOSITORY_DIR}"
} > /var/lib/retail-store-bootstrap.status

echo "==> versions"
for t in docker "docker compose" git aws kubectl helm terraform trivy checkov; do
  printf '%-16s: ' "${t}"
  ${t} --version 2>&1 | head -n 1
done
eksctl version 2>/dev/null || echo "eksctl not installed"
