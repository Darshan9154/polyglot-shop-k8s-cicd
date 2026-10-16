#!/bin/bash
# fix-go.sh - bump the vulnerable Go modules using a compiler that matches the
# catalog image build. amazonlinux:2023 installs go1.26.8, so the throwaway
# updater uses a modern Go too; the earlier attempt failed only because the
# updater container had Go 1.23 while grpc v1.79.3 requires >= 1.24.
set -uo pipefail
R=/opt/polyglot-shop/source/polyglot-shop-k8s-cicd
cd "${R}" || exit 1

echo "=== before ==="
grep -E '^go |^toolchain |google.golang.org/grpc|golang.org/x/(crypto|net)' "${R}/src/catalog/go.mod"

docker run --rm -v "${R}/src/catalog":/app -w /app golang:1.25-bookworm sh -c '
set -e
export GOTOOLCHAIN=auto
go get google.golang.org/grpc@v1.79.3
go get golang.org/x/crypto@v0.52.0
go get golang.org/x/net@v0.53.0
go mod tidy
' 2>&1 | tail -n 10

echo "=== after ==="
grep -E '^go |^toolchain |google.golang.org/grpc|golang.org/x/(crypto|net)' "${R}/src/catalog/go.mod"
chown -R ubuntu:ubuntu "${R}/src/catalog"
echo "=== files changed ==="
ls -la "${R}/src/catalog/go.mod" "${R}/src/catalog/go.sum"
