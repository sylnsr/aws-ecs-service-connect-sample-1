# MEMORY — python-backend

Notes for Claude. Invariants, and the reasoning behind choices that look wrong
until you know why. `README.md` is for humans running the app; this is for
whoever changes it next.

---

## 1. The collection is upstream of this app

`postman/awuca.postman_collection.json` is the source of truth. This app does
not define the API — it satisfies it.

When a route's request or response shape needs to change, **edit the collection
first**, then make this app match. Doing it the other way round means the Prism
mock, the Playwright contract suite and this app now disagree, and the whole
point of the harness is that they cannot.

The incremental loop the task exists to demonstrate:

1. Change the collection.
2. Restart Prism. It serves the new shape immediately, no code.
3. `pytest` / Playwright `@contract` go **red** against this app. That is the
   signal, not a failure of the harness.
4. Change this app until green.

---

## 2. Invariants

**`awuca/seed.py` is part of the contract.** Not fixture data. The generated
contract tests drive the collection's saved examples against a freshly seeded
customer, so the seed *is* the precondition every example assumes:

- `acc-0001` … `acc-000N` for `x-account-count: N`; last is `closed` when N ≥ 3.
- `pm-0001` (card, default) and `pm-0002` (direct debit).
- Loyalty: `acc-0001` enrolled, `acc-0002` not.
- Closure: `acc-0001` Pending, `acc-0002` none.

**Two examples on one endpoint must differ in their REQUEST.** If a 200 and a
404 example carry byte-identical requests, no single backend state satisfies
both. Prism hides this (it replays whichever example the `Prefer` header asks
for); a real implementation cannot. This bug was already found and fixed once:
`GET /v1/loyalty` originally had identical 200 and 404 examples, and the fix
was to key enrolment by `accountId` so they became `?accountId=acc-0001` and
`?accountId=acc-0002`. Fix these in the collection, never by weakening a test.

**`POST /v1/loyalty/signup` is idempotent.** 201 with the existing enrolment,
not 409. This is what keeps the 201 example satisfiable against a seed where
`acc-0001` is already enrolled. Same for `POST /v1/accounts/{id}/closure`.

**One error shape.** Every failure is `{"error": "<slug>", "message": "<text>"}`.
`errors.py` normalises `ApiError`, `StarletteHTTPException` *and*
`RequestValidationError` into it. A raw FastAPI 422 `{detail: [...]}` leaking
out is a bug — that is why `auth.py` parses `x-account-count` by hand instead of
declaring it as a typed `Header(...)`.

**`TOKEN_SECRET` must be identical across blue and green.** A token minted by
the active pool is presented to the standby pool the instant the listener
swaps. Per-pool keys would log everyone out on every promotion.

**`/healthz` must not touch the store.** A health check that fails when
DynamoDB blips will drain every task in the pool and turn a partial dependency
outage into a total one.

---

## 3. Things that look like bugs but are not

| Looks wrong | Why it is deliberate |
|---|---|
| Routers return bare `dict`, not Pydantic response models | Response models would be a second declaration of shapes the collection already declares. Two sources of truth, drifting silently. Only *requests* are modelled — those need validation, and validation is not duplication. |
| `models.py` is tiny | Same reason. It contains request bodies and nothing else. |
| DynamoDB stores the document as one JSON **string** | A native map round-trips numbers through `Decimal`, so `42.5` comes back as something the shape check no longer reads as a JSON number. A storage detail must not be able to break the API contract. |
| `create_app("all")` mounts loyalty into the ECS app | Local convenience only. Production splits them per README §2A. The tests use `all` because from a client's side CloudFront makes it one surface anyway. |
| `requirements-lambda.txt` duplicates pins instead of `-r requirements.txt` | uvicorn + `[standard]` extras (uvloop, httptools, websockets) are cold-start cost in a Lambda that never starts a server. A shared file plus a post-install `pip uninstall` is worse — it downloads and compiles them first. Keep the shared pins in step by hand. |
| No `HEALTHCHECK` in the Dockerfile | The ALB target group check decides who gets traffic. A second, disagreeing check only adds a way for the two to conflict. |
| YAML store lock is process-local | Documented, not overlooked. Run `--workers 1` locally. It is also an honest miniature of why the deployed side is a shared table. |
| `get_settings()` caches | Read once so a mid-flight env change cannot make two requests in the same process disagree about which pool they are. `reset_settings_cache()` is a test hook only. |
| The bearer token is hand-rolled, not PyJWT | It authenticates nobody. One less dependency for a mock issuer. Do not reuse it anywhere real. |

---

## 4. Coupling — change one, check the others

| If you change… | Also update |
|---|---|
| `seed.py` | the collection's saved examples; `playwright-tests/README.md` seed table; the seed table in `README.md` |
| a response shape in `routers/` | the matching example in the collection (**collection first**) |
| a path | `edge/kvs/routing.yaml` — API paths are pinned there and CloudFront rewrites onto them |
| `Store` protocol | `yaml_store.py`, `dynamodb_store.py`, and the table definition in `stub-tf/` |
| env vars in `config.py` | `README.md` table, both Dockerfiles, `stub-tf/` task definition |
| `errors.py` | every error example in the collection |

---

## 5. Environment constraints

The container Claude runs in has **no python3, no pip, no node, no docker and
no podman**, and the sandbox write allowlist excludes `/usr`, so installing
them is not an option either.

Everything here was authored but **never executed**. Per `CLAUDE.md`, all
execution goes through HITL+: write the commands into `ai/work/ask.sh`, ask the
operator to run it, read the results from `ai/work/answer.md`.

Do not claim any of the following has been verified until an `answer.md` says so:

- `pytest` passes (both suites, every parametrized case)
- both images build
- the Lambda image starts under the Runtime Interface Emulator
- Playwright `@contract` is green against Prism *and* against this app
- the DynamoDB adapter has ever talked to DynamoDB

The pytest suites are the cheapest of these to run and the highest value —
they need only Python, no Prism, no Node, no AWS. Put them first in `ask.sh`.
