# TLDR

Condensed from [README.md](README.md). Read that for the reasoning behind any of this.

**What:** a local, offline harness that mirrors an AWS production topology in containers, so zero-downtime deployments can be rehearsed without touching AWS. Terraform in `/terraform/` provisions the cloud twin of the same design.

## Local → AWS

| Local | AWS |
| --- | --- |
| Node.js edge router running the real CloudFront Function source | CloudFront + CloudFront Functions |
| `cloudfront` module shim over `/edge/kvs/*.yaml` | CloudFront KeyValueStore |
| NGINX, production + test listeners over `upstream blue`/`green` | ALB, target groups, CodeDeploy test listener |
| Paired `service-app-blue`/`-green` containers | ECS, Service Connect, CodeDeploy |
| Function-stub containers behind the ALB | AWS Lambda |
| SeaweedFS (`assets-bucket`, `uploads-bucket`) | S3 |
| Prism, driven by `/postman/` | Backend microservice APIs |

## Blue/green model

Canary means **testers and CI only** — never a percentage of customers. So there are **no traffic weights anywhere**:

- **Production listener** → active pool (customers) · **Test listener** → standby pool (testers, CI)
- Validate on the test listener, then **atomically swap** which pool production names. No intermediate percentages; the old pool stays warm for rollback.
- Deterministic routing means **no stickiness cookie** is needed.
- The test listener needs a security group scoped to tester/CI CIDRs — a separate port is not a boundary by itself.

The ALB is the **single deployment control point**.

## Edge / KVS

KVS is for **URI rewrites only** (vanity URLs and legacy path migrations), not deployment routing. `/edge/kvs/routing.yaml` is a list of `{from, to}` pairs, compiled to key=`from`, value=`to`; the shim reads it locally and Terraform seeds the real store from the same file.

Constraints that shape the design: functions get 10 KB code / 2 MB / ~1 ms, no network or filesystem; KVS keys 512 B, values 1 KB, store 5 MB, one store per function. **No environment variables** — the store ID is substituted into the source at load time, identically for local and Terraform. Functions can't be APM-instrumented; `console.log` is the only telemetry.

Edge must be **Node.js**, not OpenResty — CF Functions are JavaScript and the harness runs the real source unmodified.

## Tooling bars

Every component must be **free for commercial use** (permissive licence, no copyleft or paid gating) **and nimble** (small image, low RAM, fast start; no JVM). Hence SeaweedFS over MinIO, Prism over WireMock.

## Status

Planning. `postman/` and `terraform/` are empty; `ai/tasks/simple-ui.md` is a stub. The Postman collection is the next piece — everything else derives from it. Deliberately excluded: API Gateway, weighted/percentage canaries.
