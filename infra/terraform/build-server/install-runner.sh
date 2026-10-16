#!/bin/bash
# install-runner.sh - install and register the GitHub Actions self-hosted runner.
#
# Why the runner lives here at all: the deploy job runs `helm upgrade` against the EKS cluster,
# and from inside the VPC the cluster's API endpoint resolves to its PRIVATE address. A
# GitHub-hosted runner is outside the VPC and would fail at the first kubectl call with a
# connection timeout. The runner has to be in the network, and this is the machine that is.
#
# Why it runs as the ubuntu user rather than root: the runner executes arbitrary code from the
# repository's workflows. Running it unprivileged limits what a compromised workflow can do to
# the host. The ubuntu user is in the docker group, which is what the image build needs.
#
# Why the service is installed rather than the runner left in the foreground: a runner started
# from a shell dies when the shell ends, and the pipeline then reports a queued job that never
# starts. Installing it as a systemd service means it survives disconnection and restarts on boot.
set -uo pipefail

RUNNER_VERSION="2.338.0"
RUNNER_DIR="/opt/actions-runner"
REPO_URL="https://github.com/Darshan9154/polyglot-shop-k8s-cicd"
RUNNER_NAME="polyglot-build-server"
# The token is written here by the caller rather than embedded, so that this script contains no
# credential and can be committed.
TOKEN_FILE="/root/runner-token.txt"

echo "=== prerequisites ==="
# The runner needs libicu and a few standard libraries. Amazon Linux 2 provides them, but a
# missing library fails at configure time with a message about a shared object rather than about
# the dependency, so this is checked explicitly first.
if ! ldconfig -p | grep -q libicu; then
  echo "libicu missing; installing"
  yum install -y libicu >/dev/null 2>&1 || echo "WARNING: could not install libicu"
else
  echo "libicu present"
fi
command -v docker >/dev/null 2>&1 && echo "docker present: $(docker --version)" || echo "WARNING: docker not found"
command -v helm   >/dev/null 2>&1 && echo "helm present: $(helm version --short)"   || echo "WARNING: helm not found"
command -v kubectl >/dev/null 2>&1 && echo "kubectl present: $(kubectl version --client -o json 2>/dev/null | head -c 60)" || echo "WARNING: kubectl not found"

echo
echo "=== stop and remove any previous runner, so this is idempotent ==="
if [ -x "${RUNNER_DIR}/svc.sh" ]; then
  cd "${RUNNER_DIR}" && ./svc.sh stop >/dev/null 2>&1 || true
  ./svc.sh uninstall >/dev/null 2>&1 || true
fi
rm -rf "${RUNNER_DIR}"

echo
echo "=== download the runner (${RUNNER_VERSION}) ==="
mkdir -p "${RUNNER_DIR}"
chown ubuntu:ubuntu "${RUNNER_DIR}"
cd "${RUNNER_DIR}"
sudo -u ubuntu curl -fsSL -o runner.tar.gz \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
  || { echo "DOWNLOAD FAILED"; exit 1; }
echo "downloaded: $(stat -c %s runner.tar.gz) bytes"
sudo -u ubuntu tar xzf runner.tar.gz || { echo "EXTRACT FAILED"; exit 1; }
rm -f runner.tar.gz
echo "extracted files: $(ls -1 | wc -l)"

echo
echo "=== register with GitHub ==="
if [ ! -s "${TOKEN_FILE}" ]; then
  echo "NO TOKEN at ${TOKEN_FILE}"
  exit 1
fi
# Why the token is read into a variable and the file removed immediately: the registration token
# is valid for one hour and can register a runner against the repository. Leaving it on disk is
# an unnecessary exposure, and the runner does not need it after registration.
TOKEN="$(cat "${TOKEN_FILE}")"
rm -f "${TOKEN_FILE}"

# Why --unattended: without it config.sh asks interactive questions and blocks forever in a
# non-interactive session such as this one.
sudo -u ubuntu ./config.sh \
  --url "${REPO_URL}" \
  --token "${TOKEN}" \
  --name "${RUNNER_NAME}" \
  --labels self-hosted,linux,x64 \
  --work "${RUNNER_DIR}/_work" \
  --unattended 2>&1 | tail -n 6

if [ ! -f "${RUNNER_DIR}/.runner" ]; then
  echo "REGISTRATION FAILED - no .runner file produced"
  exit 1
fi
echo "registration confirmed: .runner exists"

echo
echo "=== install as a service so it survives a disconnect and a reboot ==="
./svc.sh install ubuntu 2>&1 | tail -n 2
./svc.sh start 2>&1 | tail -n 2

echo
echo "=== service status ==="
./svc.sh status 2>&1 | head -n 6

echo
echo "=== runner identity ==="
python3 -c "import json;d=json.load(open('${RUNNER_DIR}/.runner'));print('name  :',d.get('agentName'));print('repo  :',d.get('gitHubUrl'));print('labels:',d.get('labels'))" 2>/dev/null || cat "${RUNNER_DIR}/.runner"
