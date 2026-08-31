# MEMORY — playwright-tests

Notes for Claude maintaining this directory. Read
[README.md](./README.md) first; this file records the *reasoning* that the
README states as fact, so it does not get undone by a well-meaning refactor.

## Invariants — do not break these

1. **`tests/contract.spec.ts` must stay generated.** It contains no
   per-endpoint code. If asked to "add a test for endpoint X", the answer is
   almost always to add the request and example to
   `postman/awuca.postman_collection.json` instead. Hand-written contract tests
   silently destroy the incremental loop this repo exists to demonstrate.

2. **`@stateful` never runs against Prism.** Prism is stateless. Two guards
   enforce this — `grep: /@contract/` on the `prism` project in
   `playwright.config.ts`, and `test.skip(({ target }) => target === 'prism')`
   in `stateful.spec.ts`. Both are intentional; removing either leaves a single
   point of failure.

3. **No test opens a browser.** Everything uses the `request` fixture. This
   keeps the install to the driver alone, which is what lets
   `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` work and satisfies the footprint bar in
   README "Tooling constraints". Adding a `page` test would pull in ~500 MB of
   Chromium. If UI tests are genuinely wanted, put them in a separate project
   with its own install step rather than changing this one.

4. **Comparison is structural, never by value.** See `src/shape.ts`. The same
   spec runs against a mock returning canned data and an app returning real
   data. Any `toEqual` on a response body will pass on one target and fail on
   the other.

5. **Every test gets a unique `customerId`** from the fixture. Without it the
   suite only passes in order — one test's closure request makes another's 404
   assertion fail, and the contract cases that mutate (`DELETE pm-0002`,
   `PUT pm-0001`) poison later ones. If the backend ever stops keying state by
   customer, these tests need reworking, not the fixture.

6. **Two examples on one endpoint must differ in their REQUEST.** This is the
   subtlest invariant and the easiest to reintroduce. A generated suite
   requires every documented (request, response) pair to hold simultaneously
   against one backend state. A mock will serve a 200 and a 404 for the same
   request; a real backend cannot.

   This bug was already made once here: `GET /v1/loyalty` had a 200 *enrolled*
   and a 404 *not enrolled* example with byte-identical requests — green on
   Prism, unsatisfiable on Python. Fixed by keying loyalty on `accountId` so
   the examples became `?accountId=acc-0001` and `?accountId=acc-0002`.

   When reviewing a collection change, check this first. The symptom is a
   contract case that passes on `prism` and cannot be made to pass on
   `python-local` no matter what the backend does.

## Things that look like bugs but are not

* **`preferHeaders()` treats the two targets differently.** This is the only
  such place and it is deliberate — Prism needs `Prefer: code=404` to serve a
  404 example. Documented in README under "The `Prefer` header".
* **`shape.ts` allows extra keys.** Backwards-compatible additions should not
  fail a consumer's contract test.
* **`null` in an example matches anything, including absence.** It means
  "nullable, type unspecified", not "must be null".
* **`python-aws` is conditionally constructed** in `playwright.config.ts`. An
  always-present project with an empty `baseURL` fails with `Invalid URL`,
  which tells the operator nothing.
* **`playwright.config.ts` defaults to `localhost` but `run.sh` overrides it to
  container names.** Both are right for their context. The config default
  serves the documented `npm test` fallback on the host; inside a container
  `localhost` is that container, so `run.sh` passes `AWUCA_PRISM_URL` and
  `AWUCA_PYTHON_URL` pointing at `awuca-prism` and `awuca-backend-blue` on the
  shared `awuca` network. Do not "fix" the config default to match `run.sh`.
* **`@playwright/test` is pinned exactly, not `^`.** It should track the
  `mcr.microsoft.com/playwright` image tag in `run.sh`. Bump both together.
* **`node_modules` is a named volume, not a host directory.** So a host-side
  `npm install` from the fallback path cannot shadow the container's, and
  clean-up stays `podman volume rm awuca-pw-modules`.

## Coupling to the rest of the repo

| Depends on | How it breaks |
| --- | --- |
| `postman/awuca.postman_collection.json` | Path is hard-coded in `src/collection.ts`. Moving or renaming the collection breaks every test at load time (deliberately loud). |
| `edge/kvs/routing.yaml` | Pins `/v1/payments/methods`, `/v1/billing/statement`, `/v1/loyalty/signup`, `/v1/loyalty`, and `/v1/payment-old`. Renaming any of those in the collection without editing the rewrite table breaks the edge, and no test here will catch it. |
| `python-backend` | Must implement every example **and seed every new customer identically** — `acc-0001` enrolled with a Pending closure, `acc-0002` neither, `pm-0001`/`pm-0002` present. The contract suite encodes that seed. `@stateful` additionally assumes state is keyed by customer, that signup is idempotent, and that `/v1/whoami` reports `pool`. |
| README §2A | Loyalty is the **Lambda** workload, everything else ECS. The collection's Loyalty folder documents this; keep it accurate if the split changes. |

## Environment constraints

Claude's container in this project has **no `node`, `npm`, `podman` or
`docker`**. Nothing here can be installed, type-checked or run locally. All
execution goes through the HITL+ flow in `CLAUDE.md` — stage commands in
`ai/work/ask.sh`, read results from `ai/work/answer.md`. Do not claim a test
run passed without an `answer.md` showing it.

`ai/work/ask.sh` calls `./run.sh` rather than reimplementing the invocation, so
a green HITL+ run is evidence about the script a developer actually uses. Keep
it that way: if `run.sh` gains a required argument, `ask.sh` needs the same
change, and duplicating the `podman run` line into `ask.sh` would let the two
drift apart silently.

`apps.md` requires everything run locally to be containerized, so clean-up is
removing an image. The target hosts are **Debian and Mac**, which is why
`run.sh` derives the SELinux `:Z` flag from `selinuxenabled` rather than
hardcoding it, and why container-name DNS is used instead of `--network=host`.

## Known-unverified

These were authored without ever executing them. Until an `answer.md` confirms
otherwise, treat as unproven:

* Prism's exact handling of Postman path variables (`:accountId`) and whether
  it matches the routes as written.
* Whether `Prefer: code=<n>` selects examples as expected on a Postman-sourced
  document (it is well documented for OpenAPI).
* The `@playwright/test` version pin, and whether the Node in
  `mcr.microsoft.com/playwright:v1.49.0-noble` is >= 22.6 — `./run.sh cases`
  needs `--experimental-strip-types`. If not, `cases` fails while `test`
  still works, since Playwright transpiles the spec files itself.
* That `mcr.microsoft.com` is reachable. It is a different registry from
  `docker.io`, and an egress allowlist covering one may not cover the other.
