# Hybrid AWS Architecture & Blue/Green Simulation Harness

This repository contains a local, containerized simulation environment designed to mirror an AWS production architecture—incorporating **CloudFront, CloudFront Functions, an Application Load Balancer (ALB), AWS Lambda, ECS Containers utilizing Service Connect, S3, and Blue/Green deployment routing**. It leverages exported Postman collections to drive local API mock servers, allowing offline development and testing of zero-downtime deployment patterns.

Short version available in [TLDR.md](./TLDR.md)

---

## **1. Architecture Overview**

The local stack replicates a cloud-native AWS topology inside a Docker Compose environment to mimic edge routing, load balancing, service mesh orchestration, and blue/green traffic shifts.

| Layer              | Local Simulation                                                                         | AWS Equivalent                                                        |
|--------------------|------------------------------------------------------------------------------------------|-----------------------------------------------------------------------|
| **Edge**           | Node.js router executing the actual CloudFront Function source at ingress (see §2D)      | CloudFront distribution + CloudFront Functions                        |
| **Edge Config**    | `cloudfront` module shim over `/edge/kvs/*.yaml`, in-process, no extra container         | CloudFront KeyValueStore                                              |
| **Load Balancing** | NGINX with production and test listeners over `upstream blue` / `upstream green`         | ALB, target groups, production + CodeDeploy test listener             |
| **Orchestration**  | Paired `service-app-blue` / `service-app-green` containers on isolated internal networks | ECS cluster, task definitions, Service Connect, CodeDeploy blue/green |
| **Serverless**     | Function-stub containers reached via the ALB routing stub (see §2E)                      | AWS Lambda                                                            |
| **Storage**        | SeaweedFS with `assets-bucket` and `uploads-bucket`                                      | S3 buckets (versioning, encryption, public access blocks)             |
| **Mock Backend**   | Prism driven by the collections in `/postman/`                                           | Backend microservice APIs                                             |

* **Edge Layer:** Lightweight Node.js router simulating **CloudFront** and **CloudFront Functions** (URL rewrites, redirects, header injection, and edge validation), with a **KeyValueStore** shim supplying routing configuration to those functions.
* **Load Balancing Layer:** NGINX configured as an **ALB** proxy, handling path-based routing, health checks, and the atomic blue/green pool swap, with a separate test listener for canary validation.
* **Orchestration Layer:** **AWS Lambda** and **ECS-style container sets** utilizing local service mesh patterns inspired by [Amazon ECS Service Connect](https://aws.amazon.com/blogs/containers/streamline-service-to-service-communication-during-deployments-with-amazon-ecs-service-connect/) and [ECS Blue/Green Patterns](https://github.com/aws-samples/sample-amazon-ecs-blue-green-deployment-patterns/blob/main/ecs-bluegreen-service-connect/README.md).
* **Storage Layer:** Local SeaweedFS or containerized filesystem endpoints mocking **S3 buckets**.
* **Mock Backend Layer:** Prism instances driven by version-controlled **Postman Collections**.

---

## **2. Component Specifications for AI Code Generation**

When instructing an AI LLM to generate, extend, or scaffold components within this repository, adhere strictly to the following technical blueprints:

### **A. Mock Microservices (Postman Collection Integration)**

* **Source of Truth:** Postman JSON collections located in `/postman/`.
* **Implementation Requirement:** Use Podman (rootless) **Prism** containers to spin up mock endpoints matching the exact route, method, request payload schema, and response codes defined in the Postman collection.
* **Target Mapping:** Each mock microservice container must expose an environment variable pointing to its corresponding ECS/Lambda routing stub.

### **B. Mock S3 Buckets**

* **Implementation Requirement:** Deploy a lightweight **SeaweedFS** service via Docker Compose file with predefined bucket names matching production configuration (`assets-bucket`, `uploads-bucket`).
* **Permissions:** Implement basic public/private policy simulation via container environment setup to mirror AWS S3 access controls.

### **C. Mock ALB (Application Load Balancer)**

* **Implementation Requirement:** Configure an NGINX container to act as the primary ingress router.
* **Behavior:** Must support path-based routing rules (e.g., `/api/*` to backend services, `/static/*` to S3/SeaweedFS) and inject standard AWS headers (`X-Forwarded-For`, `X-Forwarded-Proto`, `X-Amzn-Trace-Id`).
* **Listeners:** Expose two listeners mirroring CodeDeploy's blue/green model—a **production listener** serving customer traffic from the active pool, and a **test listener** on a separate port wired directly to the standby pool. There are no traffic weights anywhere: every request goes wholly to one pool or the other, and promotion is an atomic swap of which pool the production listener names.
* **Test Listener Access Control:** A separate port is not a security boundary by itself. In `alb.tf` the test listener must carry a security group restricting source ranges to tester and CI egress CIDRs; locally the port is bound to loopback only. This is the reason the test listener is preferred over a canary header—a header is forgeable by anyone and offers no comparable place to enforce access.

### **D. Mock CloudFront with CloudFront Functions and KeyValueStore**

* **Implementation Requirement:** Implement the edge router as a **Node.js** service positioned in front of the mock ALB. Node.js is mandatory rather than preferred: CloudFront Functions are JavaScript, and the harness runs the *actual* function source unmodified. An OpenResty/Lua edge would require a parallel reimplementation, at which point the harness stops proving anything about the function that gets deployed.
* **Function Source:** Store each function in `/edge/functions/*.js`, written against the **`cloudfront-js-2.0`** runtime with an `async function handler(event)` signature. This exact source is what Terraform uploads—there is no local-only variant.
* **Behavior:** Functions run on viewer request/response events and must support both return shapes: a **mutated request** (URI normalization, query string sorting, header injection) forwarded upstream, and a **generated response** (e.g. a `302` carrying a `location` header) that short-circuits the origin entirely. The local router must honour the short-circuit and not contact the ALB in that case.
* **KeyValueStore:** Provide a local `cloudfront` module shim exposing `kvs(id)` with `get()`, `exists()` and `meta()`, backed by an in-memory map loaded from `/edge/kvs/<store>.yaml`. That YAML file is the single source of truth—the shim reads it locally and Terraform seeds the real store from the same file. YAML is used in preference to JSON because the table is hand-edited and needs inline comments. The file is authored as a **list of `{from, to}` pairs** and compiled into the store as key=`from`, value=`to`—a list keeps each entry extensible (a future `type` or `status` field needs no restructuring) while the compiled form stays the flat key→string map the real KVS requires.
* **Rewrite Lookup:** The function performs a single exact-match lookup on the full normalised URI (lowercased, trailing slash stripped), not the slug-extraction pattern shown in the AWS weighted-routing example. This collapses vanity URLs and legacy path migrations into one mechanism—a vanity URL is simply a short `from`—and keeps the function well inside its 10 KB budget. Unmatched URIs pass through untouched.
* **KVS ID Injection:** CloudFront Functions do not support environment variables, so the store ID must be hard-coded in the function source. Keep the literal `KEY_VALUE_STORE_ID_PLACEHOLDER` in the committed source and substitute it at load time—the local store ID in the edge container, `aws_cloudfront_key_value_store.id` in Terraform. Both paths must use the same substitution step so the two never diverge.
* **Constraints to Respect:** Functions get 10 KB of code, 2 MB of memory and roughly 1 ms of execution, with no network or filesystem access. KVS keys are capped at 512 bytes, values at 1 KB and a store at 5 MB, with exactly **one store per function**. Store routing configuration only—never payloads. The shim should enforce these limits so a violation fails locally rather than at deploy time.
* **Observability:** Functions cannot make network calls and therefore cannot be instrumented by an APM agent. `console.log` is the only telemetry channel; in AWS all output lands in a single `/aws/cloudfront/function/<name>` log group in `us-east-1` regardless of which edge location ran it. The local router should mirror this by writing function logs to one dedicated stream.
* **Eventual Consistency:** Real KVS updates propagate to edge locations over seconds, whereas an in-memory map is instant. The shim must support a configurable propagation delay so that publishing a new rewrite surfaces the lag rather than hiding it—a slug is not live everywhere the instant it is written.

Seed file format (`/edge/kvs/routing.yaml`)—a list of `{from, to}` pairs:

```yaml
# Vanity URLs
- from: "/pay"
  to:   "/v1/payments/methods"
- from: "/bill"
  to:   "/v1/billing/statement"

# Legacy path migrations
- from: "/v1/payment-old"
  to:   "/v1/payments-new"
- from: "/v1/loyalty-program-11"
  to:   "/v1/loyalty"
```

With these entries `https://host/bill` rewrites to `/v1/billing/statement`, and a bookmarked `/v1/payment-old` keeps working after the endpoint is renamed. Adding either kind of entry is a data write with no CloudFront deployment, which is the whole reason the table lives outside the function code.

### **E. Mock Lambda Functions**

* **Implementation Requirement:** Run each mock Lambda as a lightweight Podman (rootless) container exposing a single HTTP endpoint, registered in the mock ALB as an upstream exactly like an ECS service.
* **Behavior:** Responses are driven by the same `/postman/` collections as the other mocks, so a function stub and an ECS-backed service are interchangeable from the caller's perspective.
* **Blue/Green:** Deploy stubs as `-blue` / `-green` pairs reached through the same production and test listeners used for ECS, and promote them with the same atomic swap—the ALB remains the single deployment control point, with no separate mechanism for serverless routes.

### **F. Terraform Infrastructure as Code (IaC)**

* **Implementation Requirement:** The AI LLM must generate corresponding Terraform configurations (`*.tf`) in a `/terraform/` directory that provision the exact cloud equivalents of the local simulation components.
* **Module Structure:**
* **`cloudfront.tf`:** Provisions the AWS CloudFront distribution, associated CloudFront Functions (`runtime = "cloudfront-js-2.0"`, source read from `/edge/functions/` with the KVS ID substituted in, and `key_value_store_associations` wired to the store), and caching policies.
* **`kvs.tf`:** Provisions the CloudFront KeyValueStore (`aws_cloudfront_key_value_store`) and seeds it from `/edge/kvs/<store>.yaml` using `aws_cloudfrontkeyvaluestore_key` with `for_each = { for r in yamldecode(file(...)) : r.from => r.to }`, which projects the authored list into the flat key→string map the store requires. Seeding through Terraform rather than the CLI avoids the ETag read-modify-write cycle the `cloudfront-keyvaluestore` API otherwise requires on every write.
* **`alb.tf`:** Provisions the Application Load Balancer, the blue and green target groups, the production and CodeDeploy test listeners, and the security groups—including the rule restricting the test listener to tester and CI source ranges.
* **`ecs.tf`:** Provisions the ECS Cluster, Task Definitions, ECS Services utilizing **Amazon ECS Service Connect** for service-to-service communication, and CodeDeploy deployment groups configured with a test listener and validation lifecycle hooks for blue/green rollouts.
* **`lambda.tf`:** Provisions the Lambda functions, their execution roles, and the ALB Lambda target groups that front them, with a stable production alias and a separate test alias swapped atomically rather than weighted.
* **`s3.tf`:** Provisions S3 buckets with appropriate versioning, encryption, and public access blocks mirroring the local S3/SeaweedFS storage.


* **Parameterization:** All resource configurations must utilize Terraform variables (`variables.tf`) and outputs (`outputs.tf`) to support multi-environment deployment (dev, staging, production) without hardcoded strings.

---

## **3. Blue/Green Simulation Workflow**

To validate zero-downtime deployments locally using the patterns referenced in the [ECS Blue/Green Service Connect Sample](https://github.com/aws-samples/sample-amazon-ecs-blue-green-deployment-patterns/blob/main/ecs-bluegreen-service-connect/README.md):

1. **Parallel Environments:** Spin up dual container sets (`service-app-blue` and `service-app-green`) on isolated internal Docker networks. One pool is active, the other standby.
2. **Canary Validation:** Wire the test listener to the standby pool and run testers and automated integration suites against it, verifying service-to-service communication via local service discovery. Customer traffic stays entirely on the active pool—no proportion of real users is ever exposed to the candidate.
3. **Promotion:** On a clean validation run, atomically swap which pool the production listener names. There are no intermediate percentages. The previous pool remains warm as the rollback target.

### Control Points

The ALB is the **single deployment control point**. Traffic moves in one binary step, never a weighted ramp:

| Listener | Points at | Audience |
| --- | --- | --- |
| **Production** | Active pool | Customers |
| **Test** | Standby pool | Testers, CI |

Cohort membership is decided by which listener you connect to, so routing is fully deterministic. **No stickiness cookie is required**—a session cannot be reassigned mid-flow the way weighted random assignment allows.

CloudFront KeyValueStore is deliberately **not** part of this path; it serves URI rewrites only (§2D). Keeping deployment control in one place is what makes a rehearsal interpretable—exactly one thing moves.

---

## Tooling constraints

Every component must clear two independent bars:

1. **Licensing** — every component must be free to use in a commercial product: no copyleft or source-disclosure obligation, no restriction on commercial redistribution, and no paid tier gating a feature we depend on. Any permissive licence qualifies (Apache 2.0, BSD, MIT, ISC and equivalents); the specific name is not the point. What is ruled out is AGPL/SSPL-style terms. This is why we opted for SeaweedFS over Minio.
2. **Footprint** — components must be nimble: small image, low RAM, fast start. The harness runs the full topology (edge, ALB, blue/green service pairs, Lambda stubs, storage, mocks) on a single developer machine, so cost is paid per container and doubled again by blue/green pairing. Prefer Go, Rust, C/NGINX-Lua or Node implementations; avoid JVM-based tooling. This is why we dropped WireMock in favour of Prism.
 

