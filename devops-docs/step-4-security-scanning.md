# Step 4 — Security scanning and the Spring Boot 4 migration attempt

**Status:** scanning complete and repeatable; one image fully remediated under
Spring Boot 4; the full migration was **attempted and then reverted**, leaving the app
building and running normally on Spring Boot 3.5.16.

**Recorded:** 2026-10-13
**Image:** `16.170.247.8:8888` (UI), instance `i-06bae5ecefeb6eb90`

## First scan (before any fix)

Trivy over the five built images, HIGH/CRITICAL, `--ignore-unfixed`:

| Image | CRITICAL | HIGH |
|---|---|---|
| cart | 9 | 37 |
| orders | 9 | 45 |
| ui | 9 | 36 |
| checkout | 5 | 103 |
| catalog | 1 | 27 |
| **total** | **33** | **248** |

Every finding had a fix version available (`packages_with_no_fix=0`).

Checkov: `CKV_K8S_*` (20 hits each — no read-only root filesystem, not running as
non-root, capabilities not dropped, no resource limits, no NetworkPolicy) across the
`deployment-me/k8-manifests` pods, and `CKV_TF_1` ×16 in the repo's own `terraform/`
tree (module sources not pinned by commit).

## Remediation that landed and is retained

| Change | Where | Result |
|---|---|---|
| Spring Boot 3.5.5 → 3.5.16 | cart, orders, ui | tomcat 10.1.55, spring-webmvc 6.2.19, jackson 2.21.4, netty 4.1.135.Final |
| `rabbit-amqp-client` → 5.34.0 | orders | replaces the vulnerable 5.25.0 |
| `grpc v1.73.0 → v1.79.3`, `x/crypto → v0.51.0`, `x/net → v0.53.0` | catalog | **critical 1 → 0** |

Measured after those fixes: **CRITICAL 33 → 20, HIGH 248 → 157.**

## Spring Boot 4 migration: what was tried, what worked, why it was reverted

Targets were verified from Maven Central rather than assumed:

- Spring Boot **4.0.8** manages Spring Framework **7.0.9** (fixes the `spring-webmvc` /
  `spring-webflux` criticals) and Netty **4.2.17.Final** (fixes `netty-handler`).
- `tomcat.version` pinned to **11.0.25** because the Boot 4.0.8 BOM's 11.0.24 is still in
  the vulnerable set.
- Spring Cloud AWS **4.0.0** for cart's DynamoDB integration (the 4.x line is the one
  documented for Spring Boot 4.0.x).
- OpenTelemetry instrumentation BOM **2.32.0**.

**cart migrated successfully:** `cart: CRITICAL 6 → 0`, `IMAGE deployment-me-cart Built`.
The working changes were:

1. `spring-boot-starter-parent` 4.0.8.
2. `org.springframework.boot.actuate.health` → **`org.springframework.boot.health.contributor`**,
   plus an explicit `spring-boot-health` dependency. The package path was confirmed by
   listing the actual `spring-boot-health-4.0.8.jar` contents, after two wrong guesses.
3. `@WebMvcTest` → `org.springframework.boot.webmvc.test.autoconfigure`
   (`spring-boot-webmvc-test`), `TestRestTemplate` → `org.springframework.boot.resttestclient`
   (`spring-boot-resttestclient`) — both also confirmed from jar contents.
4. Explicit versions for the new modules, because injecting them as dependencies without a
   version produced `'dependencies.dependency.version' ... is missing`.

**Why it was reverted anyway:** the remaining work was substantial and only partially
successful, and it left the tree in a state that could not build.

- orders and ui each required their own cascades. Spring Boot 4 also **dropped dependency
  management for Testcontainers and REST Assured**, producing
  `'dependencies.dependency.version' for org.testcontainers:junit-jupiter:jar is missing`.
  Importing `testcontainers-bom` did not take effect inside that POM's own
  `dependencyManagement`, and explicit pins did not end the cascade either.
- Migration changes were applied to POMs but the Java imports were only partially reverted,
  which produced a worst-of-both state: `package org.springframework.boot.health.contributor
  does not exist` when built against 3.5.16.
- `git` refused every restore with `detected dubious ownership` (the repo is owned by
  `ubuntu` while the scripts run as `root`), so automated rollbacks silently did nothing
  and the recovery had to come from a pre-migration tarball of the POMs.
- **checkout is not helped by any of this**: its findings need `protobufjs` 8.x (a major
  bump) and are blocked by yarn 1, whose `resolutions` rejects every ranged key
  (`Couldn't find any versions for "proxy-addr" that matches "^2.0.0@2.0.8"`). Only a bare
  package name works, which cannot express "upgrade only within major 1".

**Decision:** a repository that builds with known, documented findings is strictly better
than one that cannot build. All three Java services were returned to Spring Boot 3.5.16
uniformly, and the tree was reset from a pristine POM archive. The migration is a
planned piece of work, not a loose end.

### Recovery detail worth remembering

Recovery came from `/root/cart-before-sb4.tgz` (a POM backup taken before the migration),
not from git. Any future in-place migration on this host should take such a backup first,
because git cannot be relied on inside root-run scripts here.

## Verified state after recovery

```
REBUILD_EXIT=0
cart=running/healthy   carts-db=running/healthy
catalog=running/healthy   catalog-db=running/healthy
checkout=running/healthy  checkout-redis=running/healthy
orders=running/healthy  orders-db=running/healthy
ui=running/healthy   rabbitmq=running
ui=200   ui_health=200   catalog /catalog/size -> {"size":12}   catalog_products=200
PUBLIC_UI_STATUS=200   PUBLIC_UI_BYTES=19973   PRODUCT_MENTIONS=22
```

## What remains open

1. **20 CRITICAL / 157 HIGH findings** still block the ECR push. The Java ones need a
   Spring Boot 4 migration; the checkout ones need a yarn-1-compatible override strategy
   (or a yarn 4 upgrade) plus a protobufjs major bump.
2. **Checkov findings** are unaddressed: pod security contexts, resource limits and
   NetworkPolicies in the Kubernetes manifests.
3. **Nothing has been pushed to ECR yet** — the repositories do not exist.
4. The repo's Terraform tree still has 16 unpinned module sources (`CKV_TF_1`).

## Recommendation for the next attempt

Do the migration with a real branch and a backup, in this order: one service at a time,
building and rescanning after each; add the Boot 4 test-module dependencies up front;
decide explicitly whether Testcontainers/REST Assured versions come from a BOM or pins;
and handle checkout separately, since it is not a Spring Boot problem at all.
