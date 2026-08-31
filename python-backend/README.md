# AWUCA Backend

Python implementation of the ACME Water Utility Customer App API.

The API surface is not designed here. It is defined by
[`postman/awuca.postman_collection.json`](../postman/awuca.postman_collection.json),
and this app exists to satisfy it. The same collection drives the Prism mock
and generates the Playwright contract tests, so all three agree by construction
rather than by review.

```
postman/awuca.postman_collection.json   <- source of truth
        |
        +-- prism mock            (no code, instant, stateless)
        +-- playwright @contract  (generated, runs against either target)
        +-- python-backend        (this app -- must satisfy the same examples)
```

---

## Quick start

**The only requirement is Podman** (or Docker). There is no Python install:
each script runs in a container, which is also what makes clean-up a matter of
removing an image.

```bash
./test.sh        # pytest -- no server, no network, cheapest signal here
./build.sh       # both images: ECS and Lambda
./run.sh -d      # the ECS image, on http://localhost:8080/docs
./run.sh --stop
```

`run.sh` sets `STORE=yaml` and bind-mounts `./data/`, so the store is
`./data/awuca-store.yaml` on your disk. Delete that file to reset every
customer. It also sets `APP_MODE=all`, overriding the image's `APP_MODE=ecs`,
so one container serves the loyalty routes too — the Playwright suite and the
Vue dev server both expect a single base URL carrying the whole API.

### Running both pools

```bash
./run.sh -d                         # blue,  :8080
POOL=green PORT=8081 ./run.sh -d    # green, :8081
```

They share the bind-mounted YAML file on purpose: that is the local stand-in for
the shared DynamoDB table, and it is what makes an atomic swap between the two
observable rather than a data reset. `curl localhost:8080/v1/whoami` reports
which pool answered.

### Fallback: on the host

Still supported. Needs Python 3.12 or newer (PEP 604 unions and `datetime.UTC`
without a compatibility shim).

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt -r requirements-dev.txt
pytest
uvicorn main_ecs:app --port 8080 --reload
```

### Clean-up

```bash
podman rmi awuca-backend:dev awuca-loyalty:dev docker.io/python:3.12-slim
podman volume rm awuca-py-venv
rm -rf data/
```

The images default to `STORE=dynamodb`, because that is what they use in ECS.
`run.sh` overrides it; a bare `podman run` of the image will try to reach
DynamoDB.

---

## The two workloads

README section 2A splits the mock estate in two: loyalty is a Lambda, every
other route is an ECS task. `create_app(mode)` honours that split.

| Mode | Entrypoint | Routes | Image |
|---|---|---|---|
| `ecs` | `main_ecs.py` (uvicorn) | everything except `/v1/loyalty*` | `Dockerfile` |
| `lambda` | `main_lambda.py` (Mangum) | `/v1/loyalty*` only | `Dockerfile.lambda` |
| `all` | `main_ecs.py` with `APP_MODE=all` | everything | — |

`all` is the local default and the mode the tests use. From a client's point of
view the split is invisible anyway — CloudFront routes both onto one origin
path space — so serving them from one process locally costs nothing and saves
running two.

Both modes serve `/healthz` and `/v1/whoami`.

---

## Storage: why DynamoDB in ECS, not a file

The task description asks where it would be idiomatic to store this data once
deployed. The answer is **DynamoDB**, and the reason is specific to this
architecture rather than a general preference:

1. **Blue and green run at the same time.** That is the entire premise of
   [`docs/release-process.md`](../docs/release-process.md) — the standby pool is
   live and being tested while the active pool serves customers. A file inside
   a task gives each pool its own divergent copy of the world, so a tester's
   write on green is invisible on blue and vanishes at the next deployment.
   Whatever holds the state has to sit *outside* both pools.
2. **The estate is already split across ECS and Lambda.** Loyalty enrolment is
   written by the function and read by the tasks. Two compute models cannot
   share a container filesystem.
3. **ECS tasks are cattle.** Scale-out, task replacement and deployment all
   destroy local disk. EFS would survive that, but it buys a POSIX filesystem
   nobody needs here and adds mount targets, security groups and a second
   failure mode.
4. **The access pattern is a single-key lookup.** Every request is "fetch this
   customer's document". That is precisely what a key-value store is for, and
   the table stays on-demand billing so an idle demo costs nothing.

RDS would be the wrong shape: no relational query is ever issued, and it puts a
cluster, a subnet group and a password rotation in the way of a demo.

The adapter boundary is `awuca/store/__init__.py` — a three-method `Store`
protocol (`get`, `put`, `describe`). Nothing above it knows which backend is in
use.

| `STORE` | Used by | Notes |
|---|---|---|
| `yaml` | local dev, `pytest` | Whole-file read-modify-write under a process lock. Single process only — see below. |
| `dynamodb` | ECS, Lambda | One item per customer: `customerId` (partition key) plus the document as a JSON string. |

The YAML store's lock is a `threading.RLock`, so it protects one process and
not two. Run uvicorn with `--workers 1` locally (the documented default) or the
workers will lose each other's writes. That limitation is a fair miniature of
why the deployed side is a shared table.

The DynamoDB item stores the document as **one JSON string**, not as a native
map. A native map round-trips numbers through `Decimal`, which changes
`42.5` into something that no longer looks like a JSON number to the contract
shape check — an implementation detail of the storage layer would otherwise be
able to break the API contract.

---

## Configuration

Everything is an environment variable, so one image runs everywhere.

| Variable | Default | Purpose |
|---|---|---|
| `APP_MODE` | `all` | `ecs`, `lambda` or `all`. ECS entrypoint only. |
| `STORE` | `yaml` | `yaml` or `dynamodb`. |
| `YAML_STORE_PATH` | `./data/awuca-store.yaml` | `STORE=yaml` only. |
| `DYNAMODB_TABLE` | `awuca-demo` | `STORE=dynamodb` only. Terraform owns the table. |
| `AWS_REGION` | `eu-west-2` | |
| `TOKEN_SECRET` | `lorem-ipsum-demo-secret` | **Must be identical in both pools** — see below. |
| `TOKEN_TTL_SECONDS` | `3600` | |
| `POOL` | `blue` | Reported by `/v1/whoami`. |
| `POOL_ROLE` | `active` | `active` or `standby`. |
| `WORKLOAD` | `ecs` | `ecs` or `lambda`. |
| `APP_VERSION` | `0.1.0` | |
| `CORS_ORIGINS` | *(empty)* | Comma-separated. Empty means no CORS middleware at all. |
| `MAX_ACCOUNT_COUNT` | `10` | Upper bound on `x-account-count`. |

`TOKEN_SECRET` must match across blue and green. A token minted by the active
pool is presented to the standby pool the moment the listener swaps; if the
signing key differed per pool, every promotion would silently log every
customer out. This is the kind of thing a blue/green rehearsal is supposed to
*surface*, so it is called out here rather than left to be discovered.

`CORS_ORIGINS` is empty by design. The intended deployment puts the Vue app and
the API behind one CloudFront distribution, so requests are same-origin and no
preflight ever happens. Set it only when running the frontend dev server
against a separately hosted API.

---

## Auth, and what it is not

`POST /v1/auth/token` accepts any `customerId` and any password and returns an
HMAC-SHA256-signed, JWT-shaped bearer token. **This authenticates nobody.** It
is a mock issuer so the collection can demonstrate purpose 2, and none of it
should be reused.

What it does do faithfully:

- The `x-account-count` request header decides how many accounts the customer
  has. That is purpose 2's actual requirement, and it is why the count lives on
  the token rather than in a config file.
- The signature is verified with `hmac.compare_digest`, and a tampered token is
  rejected with a flat 401 that does not say why.
- Out-of-range or non-numeric `x-account-count` returns a **400** with
  `{error, message}`, not FastAPI's default 422 `{detail: [...]}`. The
  collection documents one error shape and the API has exactly one.
- Re-issuing a token for an existing customer with a *different* account count
  is refused. Silently reshaping someone's account list under an existing token
  would make the contract tests flaky in a way that looked like a real bug.

---

## Seeded data is part of the contract

`awuca/seed.py` is not sample data — it is the other half of the collection's
saved examples, and changing it breaks the contract suite on purpose.

On first token issue a customer is seeded with:

| | State |
|---|---|
| Accounts | `acc-0001` … `acc-000N` for `x-account-count: N`. The last is `closed` when N ≥ 3, the rest `open`. |
| Payment methods | `pm-0001` (card, default) and `pm-0002` (direct debit). |
| Loyalty | `acc-0001` **enrolled**, `acc-0002` **not**. |
| Closure | `acc-0001` has a **Pending** request, `acc-0002` has none. |

The acc-0001 / acc-0002 asymmetry is load-bearing. Any endpoint that documents
both a 200 and a 404 needs two accounts in different states, or one of its two
examples could never be satisfied by any single backend state. The Prism mock
hides this — it replays whichever example you ask for — so it only shows up
when the same tests run against a real implementation. See "Satisfiability" in
[`playwright-tests/README.md`](../playwright-tests/README.md).

For the same reason, `POST /v1/loyalty/signup` is **idempotent**: it returns
201 with the existing enrolment rather than a 409, which keeps the collection's
201 example satisfiable against an already-enrolled `acc-0001` and makes the
request safe to retry.

---

## Tests

```bash
./test.sh                # both suites, in a container
./test.sh -k contract    # collection examples only
./test.sh -x --tb=long   # arguments pass straight through to pytest
```

`test.sh` mounts the repo **read-only** into `python:3.12-slim`. The suite
writes nothing: the YAML store goes to pytest's `tmp_path`, and bytecode and
cache writes are suppressed. It mounts the whole repo rather than just this
directory because the contract tests read `postman/` to build their cases.

| File | What it proves |
|---|---|
| `tests/test_contract_shapes.py` | Every saved example in the collection is satisfied — one test per example, generated at runtime from the same JSON the Playwright suite reads. |
| `tests/test_stateful.py` | The transitions a saved example cannot express: signup then read, closure then status, payment method create/update/delete, tampered tokens, persistence across a reopened store. |

Both run with `TestClient` against a temp-directory YAML store, so they need no
server, no Prism, no Node and no AWS. That is what lets them gate the image
build rather than the deployment.

They deliberately overlap with the Playwright suite. It is the cheap kind of
overlap: both read the same collection file, so neither can drift from it
independently, and a failure here is diagnosable in seconds without a container.

---

## Layout

```
main_ecs.py            uvicorn entrypoint (APP_MODE)
main_lambda.py         Mangum handler (loyalty only)
awuca/
  app.py               create_app(mode) -- decides which routers are mounted
  config.py            environment -> frozen Settings, read once
  security.py          HMAC bearer tokens
  seed.py              the contract's other half
  models.py            Pydantic request models (requests only -- see MEMORY.md)
  errors.py            everything normalised to {error, message}
  deps.py              Authorization header -> Customer, with .save()
  routers/             one module per collection folder
  store/
    __init__.py        Store protocol + factory
    yaml_store.py      local
    dynamodb_store.py  ECS and Lambda
tests/
build.sh               builds both images
run.sh                 runs the ECS image locally, STORE=yaml
test.sh                runs pytest in a container
Dockerfile             ECS image
Dockerfile.lambda      Lambda image
```

`MEMORY.md` holds the invariants and the reasoning behind the non-obvious
choices — read it before changing anything in `seed.py`, `errors.py` or the
router response shapes.
