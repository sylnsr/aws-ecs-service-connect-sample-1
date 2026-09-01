# Atomic Blue/Green Cutover Process

How a change reaches production in the AWS target environment, with application
code and infrastructure Terraform both held in **Azure DevOps Server (ADO)**.

This document describes the *cloud* process. The local harness described in
[README.md](../README.md) exists to rehearse the parts of it that involve
traffic movement, without touching AWS. See
[What the harness rehearses](#what-the-harness-rehearses) at the end.

---

## 1. Blue and green are roles, not environments

The single most important framing decision: **blue and green are labels for
*active* and *standby*, and they alternate on every release.** They are not two
long-lived environments where one is permanently the live one.

The alternative — "green is where we test, then we push green over to blue, and
blue is always live" — is a trap. If "push over to blue" means redeploying the
artifact into the blue pool, then you validated one instance and shipped a
*different, freshly deployed* one. That is two deployments, and the thing that
went live is not the thing that was tested. Every class of deploy-time failure
you built this process to catch slips through the gap.

CodeDeploy for ECS enforces the correct model anyway: it creates a **replacement
task set**, shifts the listener to it, and **destroys the original task set**.
There is no persistent "blue box" to push into. Accepting alternating roles is
therefore both the idiomatic and the lower-friction choice.

The practical consequence of alternating roles: **the pool that just came out of
live service becomes the standby — and therefore the canary target — for the
next release.**

---

## 2. Release state transitions

```
Release N — steady state
  prod listener ──▶ [ TG-blue  : app v1 ]   ◀── customers
  test listener ──▶ [ TG-green : (empty)  ] ◀── testers, CI


Release N+1 — deploy candidate into the standby pool
  prod listener ──▶ [ TG-blue  : app v1 ]   ◀── customers  (untouched)
  test listener ──▶ [ TG-green : app v2 ]   ◀── testers, CI   ◀═ VALIDATE HERE


Release N+1 — promote (atomic listener shift, one step, no ramp)
  prod listener ──▶ [ TG-green : app v2 ]   ◀── customers
  test listener ──▶ [ TG-blue  : app v1 ]   ◀── rollback target, still warm
                     └─ termination wait ─▶ original task set terminated


Release N+2 — steady state, roles have swapped
  prod listener ──▶ [ TG-green : app v2 ]   ◀── customers
  test listener ──▶ [ TG-blue  : (empty)  ] ◀── testers, CI
```

Note what does **not** appear: traffic weights. Consistent with
[README §2C](../README.md#c-mock-alb-application-load-balancer) and
[README §3](../README.md#3-bluegreen-simulation-workflow), canary here means
testers and automated suites only, reached by connecting to a different
listener. No proportion of customers is ever routed to the candidate, so there
is no percentage to ramp and no stickiness cookie to manage.

---

## 3. Pipelines

Three pipelines, not two. They exist separately because they change at
different rates and should have different blast radii.

| Pipeline | Owns | Trigger | Typical cadence |
| --- | --- | --- | --- |
| **Infra** | VPC, ECS cluster, ALB, listeners, target groups, CodeDeploy application + deployment group, IAM, S3, CloudFront distribution + Functions | change under `stub-tf/`, plus a scheduled drift plan | monthly-ish |
| **KVS content** | the URI rewrite table | change to `edge/kvs/routing.yaml` | whenever a vanity URL or path migration is added |
| **Release** | application image, task definition revision, traffic shift | change under the app repo | per release |

Only the **Release** pipeline runs on a normal deployment.

### Why Terraform is not "run once"

Provisioning is not a one-time event — new services, listener rules, scaling
and security group changes, certificate rotation, provider upgrades, and each
of dev / staging / production all require applies. What *is* true is that
Terraform should not run on every application deploy. The correct separation is
**by cadence, not by "initial versus ongoing"**.

Substitute a **scheduled `terraform plan`** for the reassurance that running
`apply` on every deploy would otherwise give you. A non-empty plan on a quiet
day is drift, and you want to be told about it on a schedule rather than
discover it mid-release.

### Why KVS content is its own pipeline

[`kvs.tf`](../README.md#f-terraform-infrastructure-as-code-iac) seeds the store
from `edge/kvs/routing.yaml`, so adding a vanity URL is technically a Terraform
change — but it is *content*, and it changes at content cadence.

If it shares a root module with the ALB, adding one entry means running an apply
that also carries whatever unrelated infrastructure drift happens to be pending.
That is a poor blast radius for a one-line data edit. In production, give the
rewrite table its own root module and state so the pipeline that publishes a
slug cannot touch a listener.

**For the POC, a single root module is fine** — this is recorded so the split is
a deliberate later step rather than a surprise.

---

## 4. ADO pipeline flow

```
┌─ repo: app ─────────────────┐   ┌─ repo: infra ──────────────────┐
│ src/, Dockerfile,           │   │ stub-tf/*.tf                   │
│ appspec.yaml, taskdef.json  │   │ edge/functions/*.js            │
└──────────────┬──────────────┘   │ edge/kvs/routing.yaml          │
               │ push             └───────────────┬────────────────┘
               ▼                                  │ push
   ┌───────────────────────┐                      ▼
   │ CI: build + unit test │        ┌──────────────────────────────┐
   └───────────┬───────────┘        │ CI: fmt · validate · plan    │
               │                    └───────────────┬──────────────┘
               ▼                                    │
        image:v2 ──▶ ECR                     plan artifact
               │                                    │
               │                            manual approval
               │                                    │
               │                                    ▼
               │                    ①  terraform apply
               │                       provisions machinery only
               │                       (conditional — not per release)
               ▼
   ②  CodeDeploy: create deployment
      replacement task set registered into the STANDBY target group
               │
               ▼
   ③  validate against the TEST LISTENER
      automated integration suite + tester sign-off
               │
       ┌───────┴────────┐
    fail                pass
       │                 │
       ▼                 ▼
  destroy the      approval gate
  replacement           │
  task set;             ▼
  zero customer  ④  PROMOTE — CodeDeploy shifts the production
  impact             listener to the replacement task set (atomic)
                          │
                          ▼
                 ⑤  termination wait  ──▶  terminate original task set
                    (this window IS the rollback window)
```

Stages ②–⑤ are the normal path. Stage ① runs only when infrastructure changed.

---

## 5. Ownership boundary

**Terraform owns the machinery. CodeDeploy owns what is running in it.**

Everything CodeDeploy mutates at deploy time must be excluded from Terraform's
desired state, or the next `apply` either reverts a promotion or reports
permanent drift.

| Resource | Terraform provides | CodeDeploy mutates | Terraform must |
| --- | --- | --- | --- |
| Production listener | listener, initial `default_action` | the target group it forwards to, on every promotion | `lifecycle { ignore_changes = [default_action] }` |
| ECS service | service, network config, Service Connect | `task_definition`, `load_balancer` association | `lifecycle { ignore_changes = [task_definition, load_balancer, desired_count] }` |
| ECS task definition | family, execution/task roles, base container shape | new revisions carrying the image tag | either ignore the image/container definitions, or let the release pipeline register revisions and keep Terraform to the family and roles |

Both listener and task definition are the same failure in two places: Terraform
and CodeDeploy fighting over one attribute. Draw the line once and apply it
consistently.

---

## 6. Rollback

The **termination wait** on the CodeDeploy deployment group is the rollback
window — default one hour, configurable up to two days. Until it elapses, the
original task set is still running and still healthy, so rollback is another
atomic listener shift rather than a redeploy.

Set it deliberately. Too short and you have no recovery path for a fault that
only surfaces under real customer load; too long and you are paying for two full
pools and cannot start the next release.

---

## 7. ADO Server specifics

* **Self-hosted agents.** ADO Server (on-premises) has no Microsoft-hosted agent
  pool. The agents need outbound reachability to ECR, ECS, CodeDeploy and the
  Terraform state backend.
* **Credentials.** Use OIDC federation to assume an AWS role rather than
  long-lived access keys in a service connection. If the AWS Toolkit extension
  is not available from the marketplace on an air-gapped Server instance, it can
  be side-loaded.
* **Terraform state.** S3 backend with DynamoDB locking. State does not belong
  in ADO artifacts — it is not versioned the way state needs to be, and it puts
  secrets somewhere they were never meant to be.
* **Approval gates.** Two of them: before `terraform apply` (against a plan
  artifact produced by CI, never a fresh plan at apply time) and before
  promotion at stage ④.

---

## What the harness rehearses

The local harness covers stages **③ through ⑤** — the test listener, the atomic
promotion, and the rollback window — because those are the stages where traffic
actually moves and where the interesting failures live.

Stages **①** and **②** require real AWS. Per the HITL+ convention in
[CLAUDE.md](../CLAUDE.md), commands for those are staged in `ai/work/ask.sh` for
a human operator to run, with output captured to `ai/work/answer.md`.
