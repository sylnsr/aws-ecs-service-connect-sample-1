# TLDR

Condensed from [README.md](README.md). Read that for the reasoning behind any of this.

**What:** a local, offline harness that mirrors an AWS production topology in containers, so zero-downtime deployments can be rehearsed without touching AWS. Terraform in `/stub-tf/` provisions the cloud twin of the same design.

## Local → AWS

| Local                                                           | AWS                                          |
|-----------------------------------------------------------------|----------------------------------------------|
| Node.js edge router running the real CloudFront Function source | CloudFront + CloudFront Functions            |
| `cloudfront` module shim over `/edge/kvs/*.yaml`                | CloudFront KeyValueStore                     |
| NGINX, production + test listeners over `upstream blue`/`green` | ALB, target groups, CodeDeploy test listener |
| Paired `service-app-blue`/`-green` containers                   | ECS, Service Connect, CodeDeploy             |
| Function-stub containers behind the ALB                         | AWS Lambda                                   |
| SeaweedFS (`assets-bucket`, `uploads-bucket`)                   | S3                                           |
| Prism, driven by `/postman/`                                    | Backend microservice APIs                    |

## Blue/green model

Canary means **testers and CI only** — never a percentage of customers. So there are **no traffic weights anywhere**:

- **Production listener** → active pool (customers) · **Test listener** → standby pool (testers, CI)
- Validate on the test listener, then **atomically swap** which pool production names. No intermediate percentages; the old pool stays warm for rollback.
- Deterministic routing means **no stickiness cookie** is needed.
- The test listener needs a security group scoped to tester/CI CIDRs — a separate port is not a boundary by itself.

The ALB is the **single deployment control point**. Blue and green are **roles (active/standby) that alternate every release**, not fixed environments — the pool that just went live is the next release's canary target.

## Release pipeline

Three ADO pipelines, split by cadence: **infra** (Terraform, on infra change + scheduled drift plan), **KVS content** (routing.yaml edits), **release** (per deploy). Only the release pipeline runs on a normal deploy. Terraform provisions the machinery; **CodeDeploy operates it** — anything CodeDeploy mutates at deploy time (listener `default_action`, service `task_definition`) needs `ignore_changes` in Terraform. The CodeDeploy termination wait is the rollback window. Full detail and diagrams in [docs/release-process.md](docs/release-process.md).

## Edge / KVS

KVS is for **URI rewrites only** (vanity URLs and legacy path migrations), not deployment routing. `/edge/kvs/routing.yaml` is a list of `{from, to}` pairs, compiled to key=`from`, value=`to`; the shim reads it locally and Terraform seeds the real store from the same file.

Constraints that shape the design: functions get 10 KB code / 2 MB / ~1 ms, no network or filesystem; KVS keys 512 B, values 1 KB, store 5 MB, one store per function. **No environment variables** — the store ID is substituted into the source at load time, identically for local and Terraform. Functions can't be APM-instrumented; `console.log` is the only telemetry.

Edge must be **Node.js**, not OpenResty — CF Functions are JavaScript and the harness runs the real source unmodified.

## Tooling bars

Every component must be **free for commercial use** (permissive licence, no copyleft or paid gating) **and nimble** (small image, low RAM, fast start; no JVM). Hence SeaweedFS over MinIO, Prism over WireMock.

## The apps

The Postman collection is the **source of truth** and everything else derives from it:

```
postman/awuca.postman_collection.json
   ├── Prism mock            no code, instant, stateless
   ├── playwright-tests/     contract specs GENERATED from the collection at runtime
   ├── python-backend/       FastAPI; must satisfy the same saved examples
   └── vue-frontend/         Vue 3 + Vite; consumes the same API
```

| Directory | What |
| --- | --- |
| `postman/` | 18 requests, 24 saved examples, 8 customer purposes. Collection v2.1. |
| `playwright-tests/` | One suite, two tags. `@contract` (generated, runs against Prism *and* Python) · `@stateful` (Python only — Prism is stateless by design). |
| `python-backend/` | FastAPI. `STORE=yaml` locally, `STORE=dynamodb` on ECS. Split into an ECS app and a loyalty Lambda per §2A. |
| `vue-frontend/` | Vue 3. Relative API paths only — one CloudFront distribution serves the bundle and the API, so the artifact is environment-independent. |
| `stub-tf/` | The AWS twin. Authored, never applied. |

## Running it locally

**Podman (or Docker) is the only host requirement.** No Node, Python or Terraform install — every script runs in a container, so clean-up is removing an image.

```bash
./prism/start.sh -d                          # mock from the collection      :4010
./python-backend/test.sh                     # pytest, no server needed
./python-backend/build.sh                    # ECS + Lambda images
./python-backend/run.sh -d                   # the app                       :8080
./playwright-tests/run.sh --project=prism        # baseline: tests vs the mock
./playwright-tests/run.sh --project=python-local # the same tests vs the app
./vue-frontend/run.sh                        # UI                            :5173
./stub-tf/validate.sh                        # fmt + validate, no credentials
```

Containers share an `awuca` network and address each other by name (`awuca-prism`, `awuca-backend-blue`) rather than `localhost` — that is the only arrangement that behaves identically on Debian and Mac, the two target hosts. Each script also takes `--stop` or `-h`.

**The cycle this demonstrates:** edit the collection → restart Prism, which serves the new shape with no code → the generated contract tests go red against the app → make the app green. The collection is the only place a shape is declared, so the mock, the tests, the backend and the frontend cannot silently disagree.

Two invariants that fall out of it, both learned the hard way and recorded so they are not reintroduced:

- **Two examples on one endpoint must differ in their *request*.** A 200 and a 404 with byte-identical requests are satisfiable by Prism (it replays whichever you ask for) and impossible for any real backend.
- **Seed data is part of the contract.** `acc-0001` is enrolled with a pending closure; `acc-0002` is neither. That asymmetry is what lets success and not-found examples coexist.

## Status

Everything above is **authored but unexecuted** — the authoring environment has no Python, Node, Podman or Terraform. Execution is staged for a human operator via HITL+ (`ai/work/ask.sh` → `ai/work/answer.md`), which just calls the scripts listed above rather than reimplementing them, so a green run is evidence about the commands a developer actually types. Each app directory has a `MEMORY.md` listing precisely what remains unverified.

`ai/tasks/simple-ui.md` is a stub. Deliberately excluded: API Gateway, weighted/percentage canaries.
