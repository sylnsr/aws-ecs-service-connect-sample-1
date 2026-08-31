# AWUCA Playwright Tests

API tests for the ACME Water Utility Customer App, driven from
[`../postman/awuca.postman_collection.json`](../postman/awuca.postman_collection.json).

One suite. Two tags. Three targets.

| Target | Project | Runs | Purpose |
| --- | --- | --- | --- |
| Prism mock | `prism` | `@contract` | Baseline. Proves the collection is coherent and mockable. |
| Local FastAPI | `python-local` | `@contract` + `@stateful` | Proves the app implements the collection. |
| ECS behind the ALB | `python-aws` | `@contract` + `@stateful` | Pre-promotion gate on the test listener. |

---

## Why two tags

**Prism is stateless.** It replays saved examples from the collection; it has no
memory between requests. So these three, from `ai/tasks/apps.md`, cannot be
tested the same way on both targets:

| Behaviour | Against Prism |
| --- | --- |
| `POST` closure, then `GET` status is `Pending` | Returns `Pending` even if you never POST |
| Set loyalty ID, then get loyalty ID | Returns the canned ID, never the one you set |
| `x-account-count: 5` yields 5 accounts | Returns whatever the example holds, always |

A single undifferentiated suite would therefore either fail against Prism or be
too weak to prove the Python app works. So:

* **`@contract`** — runs against everything. For each documented
  *(request, response)* pair: does the target return that status code and a body
  of that shape?
* **`@stateful`** — Python only. Round-trips, `x-account-count`, auth
  enforcement, read-only enforcement.

## Why the contract tests are generated

`tests/contract.spec.ts` contains **no per-endpoint code and should never gain
any**. At run time it reads the collection, walks every request × every saved
example, and emits one test per example.

That is what makes the incremental loop in `ai/tasks/apps.md` real: add a
request to the collection and its coverage appears on the next run, against both
targets, with no test authoring. Hand-written tests would make the loop look
cheap in the documentation while being manual in practice.

The unit is the **example**, not the request, because a saved example is already
a *(request, expected response)* pair. The 401 example on *List Accounts*
carries `auth: noauth`; the 404 example on *Get Account Address* carries a
nonexistent `accountId`. Driving each example's own `originalRequest` is what
makes negative cases work without anyone writing them.

## Satisfiability: two examples must differ in their *request*

A generated suite only works if every documented *(request, response)* pair can
hold **simultaneously, against one backend state**. A mock will happily serve a
200 and a 404 for the same request; a real implementation cannot.

The first draft of this collection had exactly that bug — `GET /v1/loyalty` with
a 200 *enrolled* example and a 404 *not enrolled* example, byte-identical
requests. Green on Prism, unsatisfiable on Python. The fix was in the
collection, not the tests: loyalty enrolment is keyed by `accountId`, so the two
examples became `?accountId=acc-0001` and `?accountId=acc-0002`.

**When adding an example, make its request distinguishable.** Different path
variable, query parameter, header, or auth. If you cannot, the two examples
describe different worlds and one of them does not belong.

### Seeded demo data

Every customer is seeded identically on first token issue, and the examples
describe that seed:

| | |
| --- | --- |
| Accounts | `acc-0001` … `acc-000N` for `x-account-count: N`; last is `closed` when N ≥ 3 |
| Payment methods | `pm-0001` (card, default), `pm-0002` (direct debit) |
| Loyalty | `acc-0001` enrolled, `acc-0002` **not** |
| Closure | `acc-0001` Pending, `acc-0002` none |

`@stateful` transition tests therefore use **`acc-0002`** — `acc-0001` is already
in the end state and cannot demonstrate a transition.

Each test gets a unique `customerId`, so contract cases that mutate
(`DELETE pm-0002`, `PUT pm-0001`) do not leak into other tests.

## Shape, not values

Prism returns the canned example; Python returns real data — a freshly minted
`loyaltyId`, today's timestamp, an account list sized by `x-account-count`.
Comparing values would fail against Python for reasons unrelated to the
contract. So `src/shape.ts` compares key presence and value types, recursively,
with three deliberate rules:

1. **Extra keys are allowed.** Adding a field is backwards compatible and should
   not fail a consumer.
2. **`null` in the example is a wildcard**, and the key may be absent entirely.
   `billingAddress.line2` is `null` precisely because it is optional.
3. **An empty array matches a non-empty example array.** A customer may have
   zero payment methods; the example only documents element shape.

## The `Prefer` header

Prism returns the lowest 2xx example by default, so the 400/401/404 examples
need `Prefer: code=<n>` to be reachable. `src/fixtures.ts` adds it for the
`prism` target only; the real backend ignores it and produces the status
naturally from the request the example carries.

This means a negative case is a **contract** check on Prism (the example exists
and has the documented shape) and a **behavioural** check on Python (that input
really does produce that status). Both are worth having.

---

## Running

**The only requirement is Podman** (or Docker). There is no Node install:
`./run.sh` runs the suite in `mcr.microsoft.com/playwright`, and `node_modules`
lives in a named volume rather than on your disk.

```bash
./run.sh --project=prism           # the baseline
./run.sh --project=python-local    # the app
./run.sh                           # every configured project
./run.sh --grep @contract          # anything else goes straight to playwright
```

No browser is ever downloaded or launched — every test uses the `request`
fixture and no `page` is opened. That is why the image is used purely as a Node
runtime and `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` is set.

### The whole loop, from nothing

```bash
../prism/start.sh -d          # mock, on :4010
../python-backend/build.sh    # images
../python-backend/run.sh -d   # app, on :8080

./run.sh --project=prism          # baseline: green
./run.sh --project=python-local   # the app under test

../prism/start.sh --stop
../python-backend/run.sh --stop
```

`run.sh` reaches those two by **container name** on a shared `awuca` network
(`http://awuca-prism:4010`, `http://awuca-backend-blue:8080`), not `localhost`
— inside a container `localhost` is that container. This is also the only
approach that behaves the same on Debian and Mac; `--network=host` is Linux-only
and on a Mac "host" is the Podman VM rather than the laptop.

### See what the collection covers, without a server

```bash
./run.sh cases
```

Exits non-zero if any request lacks a saved example.

### Against ECS

```bash
AWUCA_AWS_URL=https://test-listener.example.internal ./run.sh --project=python-aws
```

The `python-aws` project only appears when `AWUCA_AWS_URL` is set — an empty
`baseURL` otherwise fails with an unhelpful `Invalid URL`.

### Overrides

| Variable | Default |
| --- | --- |
| `AWUCA_PRISM_URL` | `http://awuca-prism:4010` |
| `AWUCA_PYTHON_URL` | `http://awuca-backend-blue:8080` |
| `AWUCA_AWS_URL` | unset — project omitted |
| `AWUCA_NETWORK` | `awuca` |
| `PLAYWRIGHT_IMAGE` | `mcr.microsoft.com/playwright:v1.49.0-noble` |

`playwright.config.ts` still defaults to `localhost` for both, because that is
correct for the fallback below; `run.sh` overrides them.

### Fallback: on the host

Supported and unchanged — the specs and `playwright.config.ts` are identical
either way, only the invocation differs. Needs Node >= 22.6 (`npm run cases`
uses `--experimental-strip-types`).

```bash
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install
npm run test:prism
npm run test:python
```

### Clean-up

```bash
podman rmi mcr.microsoft.com/playwright:v1.49.0-noble
podman volume rm awuca-pw-modules
```

Reports (`playwright-report/`, `test-results/`) are written to this directory on
the host deliberately — they are what you read after a failure. Both are
gitignored.

---

## The incremental loop

This is the cycle `ai/tasks/apps.md` exists to demonstrate:

1. Edit `postman/awuca.postman_collection.json` — add a request, add an example.
2. `./run.sh cases` — the new cases appear. No test code written.
3. `./run.sh --project=prism` — green. The collection is coherent and mockable.
   Restart Prism first; it reads the collection once, at startup.
4. `./run.sh --project=python-local` — **red**, on exactly the new cases. That
   red is the specification.
5. Implement in `../python-backend` until step 4 is green.

Step 4 failing is the point. If a collection change does not turn the Python
project red, the change added no contract.

---

## Layout

```
run.sh              Runs the suite in a container. No host Node.
src/collection.ts   Flattens the collection into cases. The generator.
src/shape.ts        Structural comparison and its three rules.
src/fixtures.ts     `target` option, auth helper, Prefer header.
src/list-cases.ts   `./run.sh cases`.
tests/contract.spec.ts   Generated. Keep it that way.
tests/stateful.spec.ts   Hand-written. Python only.
```
