#!/bin/bash
# jar-versions.sh - read the real dependency versions baked into each fat jar.
# Trusting the parent pom is not enough; the artifact is the ground truth.
set -uo pipefail
for svc in cart orders ui; do
  img="deployment-me-${svc}:latest"
  echo "=== ${svc} ==="
  docker run --rm --entrypoint sh "${img}" -c \
    'unzip -l app.jar 2>/dev/null | grep -E "BOOT-INF/lib/(tomcat-embed-core|spring-webmvc|spring-webflux|thymeleaf|jackson-databind|netty-handler|amqp-client)-" | awk "{print \$4}" | sed "s|BOOT-INF/lib/||"' 2>&1 | head -n 12
done
echo "=== checkout ==="
docker run --rm --entrypoint sh deployment-me-checkout:latest -c 'cat package.json 2>/dev/null | head -n 3; node -e "console.log(process.version)" 2>/dev/null' 2>&1 | head -n 5
