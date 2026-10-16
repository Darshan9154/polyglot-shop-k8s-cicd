#!/bin/bash
# migrate-cart-sb4.sh - migrate the cart service to Spring Boot 4 and build it.
#
# Version choices, and why:
#   Spring Boot 4.0.8      - manages Spring Framework 7.0.9 (fixes the critical
#                            spring-webmvc CVEs) and Netty 4.2.17.Final (fixes the
#                            netty-handler CVE).
#   spring-cloud-aws 4.0.0 - the 4.x line is the one documented for Spring Boot
#                            4.0.x, and cart depends on it for DynamoDB.
#   OTel BOM 2.32.0        - current instrumentation BOM, required because the
#                            2.17 line targets Spring Framework 6.
#   tomcat 11.0.25 override- the Boot 4.0.8 BOM pins 11.0.24, which is still in the
#                            vulnerable set for CVE-2026-65182/65905/68525.
set -uo pipefail
R=/opt/polyglot-shop/source/polyglot-shop-k8s-cicd
POM="${R}/src/cart/pom.xml"
cp -a "${POM}" /root/cart-pom.backup

# Backup of the whole service so this is reversible regardless of git.
tar czf /root/cart-before-sb4.tgz -C "${R}/src" cart 2>/dev/null || true

python3 - "${POM}" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()

def sub_once(pattern, repl, label):
    global text
    new, n = re.subn(pattern, repl, text, count=1)
    print(f"  {label}: {n} replacement(s)")
    text = new

sub_once(r'(<artifactId>spring-boot-starter-parent</artifactId>\s*<version>)3\.5\.16(</version>)',
         r'\g<1>4.0.8\g<2>', "spring-boot parent 3.5.16 -> 4.0.8")
sub_once(r'(<artifactId>spring-cloud-aws-dependencies</artifactId>\s*<version>)3\.[0-9.]+(</version>)',
         r'\g<1>4.0.0\g<2>', "spring-cloud-aws -> 4.0.0")
sub_once(r'(<artifactId>opentelemetry-instrumentation-bom</artifactId>\s*<version>)2\.17\.0(</version>)',
         r'\g<1>2.32.0\g<2>', "otel instrumentation bom -> 2.32.0")

# Why the extra property: a single property is the supported way to override a
# dependency version that Boot's BOM manages.
if 'tomcat.version' not in text:
    sub_once(r'(<java\.version>21</java\.version>)',
             r'\g<1>\n    <tomcat.version>11.0.25</tomcat.version>', "added tomcat.version=11.0.25")

open(path, "w").write(text)
PY

echo "=== resulting key versions in cart pom ==="
grep -nE 'spring-boot-starter-parent|<version>4\.0\.8|spring-cloud-aws-dependencies|<version>4\.0\.0|opentelemetry-instrumentation-bom|2\.32\.0|tomcat.version' "${POM}" | head -n 12

echo "=== build cart image ==="
cd "${R}/deployment-me" || exit 1
if docker compose build cart 2>&1 | tail -n 25; then
  echo "CART_BUILD=success"
else
  echo "CART_BUILD=failed"
fi
