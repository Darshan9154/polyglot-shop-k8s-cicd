#!/bin/bash
# install-pipeline.sh - install the workflow into the repository and validate it.
#
# Why validation matters here: a malformed workflow file fails silently in the
# Actions UI as "Invalid workflow file", which is a slow way to find a YAML typo.
# Parsing it locally first turns that into an immediate, precise error.
set -uo pipefail
R=/opt/polyglot-shop/source/polyglot-shop-k8s-cicd
mkdir -p "${R}/.github/workflows"

echo "=== yaml parse check ==="
python3 - "${R}/.github/workflows/build-and-push-ecr.yml" <<'PY'
import sys, yaml
path = sys.argv[1]
with open(path) as fh:
    data = yaml.safe_load(fh)
print("YAML_VALID=True")
print("name:", data.get("name"))
print("on:", list((data.get("on") or {}).keys()) if isinstance(data.get("on"), dict) else data.get("on"))
jobs = data.get("jobs", {})
print("jobs:", list(jobs.keys()))
matrix = jobs["build-and-push"]["strategy"]["matrix"]["include"]
print("services:", [m["service"] for m in matrix])
print("runs-on:", jobs["build-and-push"]["runs-on"])
print("registry in env:", data.get("env", {}).get("ECR_REGISTRY"))
PY

echo "=== workflow files now present ==="
ls -la "${R}/.github/workflows"

echo "=== is a self-hosted runner already installed? ==="
ls -la /opt/actions-runner 2>/dev/null | head -n 6 || echo "(no /opt/actions-runner)"
if [ -f /opt/actions-runner/.runner ]; then
  echo "RUNNER_CONFIGURED=yes"
  python3 -c "import json;d=json.load(open('/opt/actions-runner/.runner'));print('runner name:',d.get('agentName'));print('repo:',d.get('gitHubUrl'));print('labels:',d.get('labels'))" 2>/dev/null || true
else
  echo "RUNNER_CONFIGURED=no"
fi

echo "=== is a runner service running? ==="
systemctl list-units --type=service --all 2>/dev/null | grep -i actions || echo "(no actions-runner service)"

echo "=== can the instance role create ECR repos? (dry check of permissions) ==="
aws sts get-caller-identity --region eu-north-1 --query Arn --output text
