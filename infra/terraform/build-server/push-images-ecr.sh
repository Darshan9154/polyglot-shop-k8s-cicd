#!/bin/bash
# push-images-ecr.sh - push the locally built, working images to Amazon ECR.
#
# Why from the instance: its IAM role already holds ECR push permission, so no AWS
# access key is needed anywhere. This also proves the exact commands and registry
# path before they are encoded into the CI/CD pipeline.
#
# Why these five images: they are the ones built from the repository on this host and
# verified running via Compose (healthy containers, storefront serving 12 catalog
# products). Nothing is rebuilt here, so the tested bytes are what gets pushed.
set -uo pipefail

AWS_REGION=eu-north-1
REGISTRY=536882095289.dkr.ecr.eu-north-1.amazonaws.com
PREFIX=polyglot-shop
SHA="$(cat /root/image-sha 2>/dev/null || echo unknown)"
MANIFEST=/root/ecr-push-manifest.txt
: > "${MANIFEST}"

echo "=== images present locally ==="
docker images --format '{{.Repository}}:{{.Tag}} {{.ID}} {{.Size}}' | grep '^deployment-me-' || echo "(none)"

echo "=== ensure one ECR repository per service ==="
for svc in cart catalog checkout orders ui; do
  repo="${PREFIX}/${svc}"
  if aws ecr describe-repositories --region "${AWS_REGION}" --repository-names "${repo}" >/dev/null 2>&1; then
    echo "  ${repo}: exists"
  else
    # Why scanOnPush: every pushed image gets an ECR-side vulnerability scan too.
    aws ecr create-repository --region "${AWS_REGION}" \
      --repository-name "${repo}" \
      --image-scanning-configuration scanOnPush=true >/dev/null \
      && echo "  ${repo}: created"
  fi
done

echo "=== log in to ECR (password is short-lived, from the instance role) ==="
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}" \
  && echo "LOGIN=ok" || { echo "LOGIN=failed"; exit 1; }

echo "=== tag and push ==="
for svc in cart catalog checkout orders ui; do
  local_img="deployment-me-${svc}:latest"
  if ! docker image inspect "${local_img}" >/dev/null 2>&1; then
    echo "  ${svc}: MISSING locally, skipped"
    continue
  fi

  # Why a git-SHA tag: the image traces back to the exact code that built it.
  # Why also :latest: convenient for a first look, but deployments should use the SHA.
  for tag in "${SHA}" latest; do
    remote="${REGISTRY}/${PREFIX}/${svc}:${tag}"
    docker tag "${local_img}" "${remote}"
    if docker push "${remote}" >/tmp/push-"${svc}"-"${tag}".log 2>&1; then
      echo "  ${svc}:${tag} pushed"
    else
      echo "  ${svc}:${tag} PUSH FAILED"
      tail -n 3 /tmp/push-"${svc}"-"${tag}".log
    fi
  done

  # Why the digest: a tag can be moved; the digest identifies the exact bytes.
  digest="$(aws ecr describe-images --region "${AWS_REGION}" \
    --repository-name "${PREFIX}/${svc}" \
    --image-ids imageTag="${SHA}" \
    --query 'imageDetails[0].imageDigest' --output text 2>/dev/null)"
  size="$(aws ecr describe-images --region "${AWS_REGION}" \
    --repository-name "${PREFIX}/${svc}" \
    --image-ids imageTag="${SHA}" \
    --query 'imageDetails[0].imageSizeInBytes' --output text 2>/dev/null)"
  echo "${PREFIX}/${svc} sha=${SHA} digest=${digest} bytes=${size}" >> "${MANIFEST}"
done

echo
echo "=== push manifest ==="
cat "${MANIFEST}"

echo
echo "=== repositories in ECR ==="
aws ecr describe-repositories --region "${AWS_REGION}" \
  --query 'repositories[].repositoryName' --output text

echo
echo "=== image count per repository ==="
for svc in cart catalog checkout orders ui; do
  n="$(aws ecr describe-images --region "${AWS_REGION}" \
    --repository-name "${PREFIX}/${svc}" \
    --query 'length(imageDetails)' --output text 2>/dev/null)"
  echo "  ${PREFIX}/${svc}: ${n} image(s)"
done
