# stub-tf

Terraform for the AWS twin of the local harness.

**This is a stub.** It has never been `init`-ed, `validate`-d, `plan`-ned or
applied — there is no Terraform binary and no AWS credentials in the
environment it was written in. Treat every resource here as a design document
that happens to be machine-readable, and expect to fix things on the first
real `terraform validate`. See [Status](#status).

The directory is named `stub-tf` rather than `terraform/` to make that
unmistakable at a glance.

---

## What it provisions

| File | Provisions |
|---|---|
| `alb.tf` | ALB, blue/green target groups, production + test listeners, security groups, Lambda listener rules |
| `ecs.tf` | Cluster with Service Connect, task definition, service, CodeDeploy application and deployment group |
| `lambda.tf` | Loyalty function, per-pool aliases, ALB Lambda target groups |
| `dynamodb.tf` | Customer document table |
| `s3.tf` | Private origin bucket for the Vue bundle |
| `cloudfront.tf` | One distribution serving both S3 and the ALB |
| `kvs.tf` | KeyValueStore, seeded from `edge/kvs/routing.yaml`, plus both edge functions |
| `iam.tf` | Task execution / task / Lambda / CodeDeploy roles |
| `variables.tf`, `outputs.tf`, `locals.tf`, `versions.tf` | Parameterisation |

```bash
cp terraform.tfvars.example dev.tfvars   # then edit
terraform init
terraform plan -var-file=dev.tfvars
```

### Not provisioned, deliberately

- **No VPC.** `vpc_id` and the subnet lists are inputs. Networking is almost
  always pre-existing and owned by a different team and a different state file;
  creating one here would either conflict with that or quietly become the thing
  everyone depends on.
- **No ECR repositories.** `ecs_image` and `lambda_image` are inputs. Image
  repositories outlive any one environment's infrastructure.
- **No Secrets Manager secret.** `token_secret_arn` is an input — Terraform
  creating a secret means the value passes through state in plaintext.
- **No backend block.** See the comment in `versions.tf` for why, and how to
  supply one at `init` time.
- **No WAF, no Route 53 record, no alarms.** Out of scope for a demo of the
  deployment paradigm.

---

## The three decisions worth reading before changing anything

### 1. Blue and green are roles, not environments

They alternate on every release
([`docs/release-process.md` §1](../docs/release-process.md)). Nothing in this
module may assume blue is the live pool:

- Target groups are symmetric and named only by pool.
- Lambda aliases are named `blue` / `green`, not `production` / `test`. Naming
  them by role would hard-code the thing that changes.
- The `blue` in each listener's `default_action` is an **initial** value, true
  exactly once, on first apply.
- There is no `live_pool` output. Ask the listener — it is the only honest
  source.

### 2. The ownership boundary

**Terraform provides the machinery. CodeDeploy operates it.** Anything
CodeDeploy mutates at deploy time is excluded from Terraform's desired state,
or the next `apply` either reverts a promotion or reports permanent drift.

| Resource | `ignore_changes` |
|---|---|
| `aws_lb_listener.production` / `.test` | `default_action` |
| `aws_lb_listener_rule.loyalty_*` | `action` |
| `aws_ecs_service.app` | `task_definition`, `load_balancer`, `desired_count` |
| `aws_ecs_task_definition.app` | `container_definitions` |
| `aws_lambda_alias.pool` | `function_version` |
| `aws_lambda_function.loyalty` | `image_uri` |

Full table in [`docs/release-process.md` §5](../docs/release-process.md).

**Consequence to remember:** you cannot change the container's environment
variables or image by editing `ecs.tf` and applying. `container_definitions` is
ignored, so the apply is a no-op. Register a new task definition revision
through the release pipeline instead. This is the correct trade and it will
still surprise you at 3am.

### 3. Two CloudFront subtleties that are easy to get wrong

**Behaviours match the incoming URI, before the viewer-request function runs.**
So `/pay` needs its own behaviour pointing at the ALB, even though the function
is about to rewrite it to `/v1/payments/methods`. Route it to S3 and the
rewrite happens on a request already heading for the wrong origin.
`locals.vanity_api_paths` derives those behaviours from `routing.yaml`, so
adding a vanity URL to the table is enough.

**There is no `custom_error_response` block, on purpose.** Mapping 403/404 to
`/index.html` is the usual SPA recipe, but it is configured per *distribution*,
not per behaviour — it would also catch the API origin, and every documented
404 from `/v1/loyalty` or `/v1/accounts/{id}/closure` would come back as the
HTML app shell with a 200. Those 404s are load-bearing: they are real states,
they are saved examples in the Postman collection, and the contract suite
asserts them. `edge/functions/spa.js` does the fallback on the S3 behaviour
alone instead.

---

## Storage

`dynamodb.tf` carries the long-form reasoning. In short: blue and green run
simultaneously, the estate spans ECS *and* Lambda, and ECS tasks are cattle —
so the state has to live outside both pools, and the access pattern is a
single-key document fetch. See also
[`python-backend/README.md`](../python-backend/README.md).

---

## Validating a release

```bash
# The standby pool, before promotion. Reachable only from test_listener_cidrs.
AWUCA_AWS_URL=$(terraform output -raw test_url) \
  npx playwright test --project=python-aws
```

That runs the **same** spec files that ran against the Prism mock and the local
Python app — see [`playwright-tests/README.md`](../playwright-tests/README.md).
One suite, three targets, is the point of the whole exercise.

---

## Status

Authored, never executed. Nothing below has been verified:

- `terraform init` resolves the provider
- `terraform validate` passes
- `terraform plan` produces a plan
- any resource argument matches the AWS provider's current schema
- the AZ / subnet / CIDR shapes are valid for a real account

Per [`CLAUDE.md`](../CLAUDE.md), Terraform runs through HITL+: commands go in
`ai/work/ask.sh` for an operator, output comes back in `ai/work/answer.md`.
`fmt` and `validate` are the cheap first pass and need no credentials.
