#!/bin/bash
# jar-versions2.sh - list dependency versions inside each fat jar using the JRE
# that already ships in the application image (unzip is not installed there).
set -uo pipefail
for svc in cart orders ui; do
  echo "=== ${svc} (from BOOT-INF/lib) ==="
  docker run --rm --entrypoint /opt/java/openjdk/bin/jar "deployment-me-${svc}:latest" tf app.jar 2>/dev/null \
    | grep -E 'BOOT-INF/lib/(tomcat-embed-core|spring-webmvc|spring-webflux|thymeleaf|jackson-databind|netty-handler|amqp-client)-' \
    | sed 's|BOOT-INF/lib/||' | sort | head -n 10
  echo "--- if that was empty, try java -version path discovery ---"
  docker run --rm --entrypoint sh "deployment-me-${svc}:latest" -c 'command -v java; ls -d /opt/java/* 2>/dev/null | head -n 2' 2>&1 | head -n 3
done
