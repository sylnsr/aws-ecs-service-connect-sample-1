# AWUCA Frontend

Vue 3 + Vite frontend for the ACME Water Utility Customer App.

It renders the eight purposes the
[Postman collection](../postman/awuca.postman_collection.json) defines and
nothing else. The API contract comes from that collection, the same as the
backend and the tests — this app is a consumer of it, not another definition
of it.

---

## Quick start

**The only requirement is Podman** (or Docker). No Node install.

```bash
../python-backend/build.sh && ../python-backend/run.sh -d   # the API
./run.sh                                                    # the UI
# http://localhost:5173
```

Point the dev server at a different API with `AWUCA_API_URL`. Note the
**container name**, not `localhost` — inside a container `localhost` is that
container:

```bash
AWUCA_API_URL=http://awuca-prism:4010 ./run.sh   # against the Prism mock
```

### Fallback: on the host

Needs Node 18.20.1 or newer (the same floor Prism sets).

```bash
npm install && npm run dev
AWUCA_API_URL=http://localhost:4010 npm run dev
```

Against Prism the UI renders, because Prism replays the collection's saved
examples — but nothing you do sticks. Prism is stateless by design. See
[`playwright-tests/README.md`](../playwright-tests/README.md).

---

## There is no API base URL, on purpose

Every call in `src/api.js` uses a **relative** path: `/v1/accounts`, never
`https://…/v1/accounts`. There is no `VITE_API_URL` and no build-time
environment switch.

That is not a simplification — it is the deployed shape:

```
                        CloudFront
                       /          \
     default behaviour /            \ /v1/*, /healthz
                      v              v
                 S3 (this bundle)   ALB -> ECS  (+ Lambda for /v1/loyalty*)
```

One distribution serves both, so the browser only ever makes same-origin
requests. Nothing to configure, no CORS preflight, and — the part that matters
for this repo — **the bundle is environment-independent**. Build the artifact
once, promote the same bytes through every stage. A baked-in API URL would turn
each promotion into a rebuild, and would make a blue/green swap a frontend
deployment rather than a listener change.

The Vite dev server reproduces that shape with a proxy (`vite.config.js`), so
`npm run dev` exercises the same code path as production instead of a
cross-origin one that only exists on a laptop.

Consequently the backend's `CORS_ORIGINS` stays empty in the intended
deployment. Set it only if you deliberately host the UI somewhere else.

---

## Build and deploy

```bash
./build.sh        # -> dist/, built in a container
```

`dist/` is written to the host on purpose — it is the deployable artifact, and
the one thing here that is not disposable. It contains no environment
configuration of any kind, so the same bundle works against a local backend,
Prism, or the ALB.

Clean-up: `podman rmi docker.io/node:22-slim && podman volume rm awuca-vue-modules`.

`dist/` goes to the S3 origin bucket; CloudFront serves it. Two things the
distribution has to do, both defined in [`stub-tf/`](../stub-tf/):

1. **Behaviours before the default.** `/v1/*` and `/healthz` must route to the
   ALB origin. Everything else falls through to S3.
2. **SPA fallback.** A 403/404 from S3 must return `/index.html` with a 200, or
   a customer who reloads on `/accounts/acc-0001` gets an S3 error page instead
   of the app. `vue-router` uses history mode precisely so the URLs are real.

The vanity links on the landing page (`/pay`, `/bill`, `/join`) are plain
anchors, not router links. They are rewritten at the edge by the CloudFront
KeyValueStore function using [`edge/kvs/routing.yaml`](../edge/kvs/routing.yaml),
so the router must never intercept them.

---

## What is in here

| Path | Purpose |
|---|---|
| `src/api.js` | The only module that touches the network. One function per collection request. |
| `src/stores/session.js` | Pinia. Token state, account list, which pool served us. |
| `src/router.js` | Four routes, one guard. |
| `src/views/LandingView.vue` | Purposes 1 and 2 — public content, then sign in. |
| `src/views/AccountsView.vue` | Purpose 3 — accounts with open/closed status. |
| `src/views/AccountView.vue` | Purposes 4, 6, 7, 8 — address, loyalty, history, closure. |
| `src/views/PaymentMethodsView.vue` | Purpose 5 — methods and billing addresses. |

### The account-count box

The sign-in form has a "number of accounts" field. It is not decoration: it
becomes the `x-account-count` request header, and purpose 2 is "authenticate
and authorize for the number of accounts in that header". Change it, sign in as
a *new* customer ID, and the account list changes length.

Signing in again as an **existing** customer with a different count is refused
by the backend. Silently reshaping someone's account list under a live token
would be a worse behaviour than an error.

### The pool badge

The header shows `pool / role / store` from `/v1/whoami`. Both pools serve
byte-identical customer responses — that is what makes the deployment
zero-downtime — so this badge is the only way to see from a browser that an
atomic listener swap actually moved traffic.

---

## Deliberate omissions

This app is thin on purpose. The repo demonstrates a development *paradigm*:
one collection driving a mock, a test suite, a backend and a frontend. Things
that would add weight without adding to that argument are left out:

- **No component library.** It would outweigh the app.
- **No token refresh.** The token lives in `sessionStorage` and expires after
  an hour; sign in again.
- **No optimistic updates.** Every mutation re-reads from the server, so what
  you see is what the API actually holds. That is the honest choice for a demo
  whose entire point is agreement between layers.
- **No frontend test suite.** The Playwright suite in
  [`playwright-tests/`](../playwright-tests/) tests the *API* against the
  collection, for both the Prism mock and the real backend. Adding component
  tests here would test this app against itself.

`MEMORY.md` records the invariants — read it before changing `src/api.js` or
the routing assumptions.
