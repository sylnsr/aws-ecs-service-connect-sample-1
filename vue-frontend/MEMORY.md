# MEMORY — vue-frontend

Notes for Claude. `README.md` is for humans running the app; this is the set of
things that will look arbitrary later and are not.

---

## 1. The collection is upstream

`postman/awuca.postman_collection.json` defines the API. This app consumes it.

When a shape changes: edit the collection, make `python-backend` satisfy it,
*then* update `src/api.js` and the view that renders it. Changing this app
first means it now expects something no other layer agrees to.

---

## 2. Invariants

**Relative API paths only.** No base URL, no `VITE_API_URL`, no absolute
origins anywhere in `src/`. CloudFront serves the bundle and forwards `/v1/*`
to the ALB, so everything is same-origin. Introducing a configurable base URL
would make the bundle environment-specific and turn "promote the artifact" into
"rebuild per stage" — and a blue/green swap into a frontend deploy.

**`src/api.js` is the only module that calls `fetch`.** A stray `fetch` in a
component is how the previous invariant gets broken by accident.

**Paths must match `edge/kvs/routing.yaml`.** The API paths are pinned there
because the edge function rewrites onto them. Change a path in one place and
the vanity URLs point at nothing.

**`/pay`, `/bill`, `/join` are plain `<a>`, never `<RouterLink>`.** They are
edge rewrites. If the router intercepts them, CloudFront never sees the request
and the whole KeyValueStore mechanism goes untested.

**History mode requires SPA fallback.** CloudFront must map S3's 403/404 to
`/index.html` with a **200**. Without it, reloading on `/accounts/acc-0001`
serves an S3 error page. This is a `stub-tf/cloudfront.tf` concern that a
frontend change can silently depend on.

---

## 3. Things that look like bugs but are not

| Looks wrong | Why |
|---|---|
| A 404 from `/v1/loyalty` or `/v1/accounts/{id}/closure` is swallowed | Those 404s are states, not failures: "not enrolled" and "no request in flight". `orNull()` in `AccountView.vue` handles exactly 404 and rethrows everything else. |
| `signIn` bypasses the shared `request()` helper | It is the one call that sets a custom header (`x-account-count`) and has no token yet. Threading both cases through the helper made it harder to read than the duplication. |
| Every mutation triggers a full re-read | No optimistic updates. The point of the demo is that the layers agree; showing the user a state the server has not confirmed works against that. |
| Token in `sessionStorage`, not memory or a cookie | It authenticates nobody — the backend's issuer is a mock. `sessionStorage` survives a reload, which makes the demo usable, and dies with the tab. Do not treat this as a pattern. |
| `PaymentMethodsView` copies `billingAddress` into the form | Binding straight to the table row would edit the rendered list live and leave it visibly wrong if the request then failed. |
| No frontend tests | The Playwright suite tests the API against the collection for both targets. Component tests here would test this app against itself. |
| `run.sh` passes `--host 0.0.0.0` instead of setting it in `vite.config.js` | The config describes the app; binding to every interface is a fact about running in a container. Keeping it in the script means the host fallback (`npm run dev`) still binds to localhost only. |
| `AWUCA_API_URL` defaults to `http://awuca-backend-blue:8080` in `run.sh` but `http://localhost:8080` in `vite.config.js` | Both are right for their context. The config default serves the host fallback; inside a container `localhost` is that container. Do not "fix" one to match the other. |
| `dist/` is written to the host while `node_modules` is a named volume | `dist/` is the deployable artifact and the one non-disposable output. `node_modules` is disposable, and keeping it in a volume stops a host-side install shadowing the container's. |

---

## 4. Coupling — change one, check the others

| If you change… | Also check |
|---|---|
| a path in `src/api.js` | the collection, `edge/kvs/routing.yaml`, the CloudFront behaviours in `stub-tf/` |
| a request body | `python-backend/awuca/models.py` — those models are `extra="forbid"`, so an unexpected field is a 422, not a shrug |
| the router table | the SPA fallback in `stub-tf/cloudfront.tf` |
| error handling | `python-backend/awuca/errors.py` — the API has exactly one error shape, `{error, message}` |

---

## 5. Environment constraints

The container Claude runs in has **no node, no npm, no podman and no docker**,
and the sandbox write allowlist excludes `/usr`, so they cannot be installed.

`apps.md` requires everything run locally to be containerized, so clean-up is
removing an image. Hence `build.sh` and `run.sh`; the host `npm` path stays
documented as a fallback but is not the primary route. Target hosts are Debian
and Mac, which is why the SELinux `:Z` flag is derived from `selinuxenabled`
rather than hardcoded.

Nothing here has been executed. Not `npm install`, not `npm run build`, not the
dev server. Per `CLAUDE.md`, execution goes through HITL+: put the commands in
`ai/work/ask.sh` and read `ai/work/answer.md`.

Unverified until an `answer.md` says otherwise:

- the dependency set resolves and `npm run build` succeeds
- every `.vue` file compiles (nothing here has been through the SFC compiler)
- the dev-server proxy actually reaches the backend
- any page renders at all
