# Prism mock

Serves [`../postman/awuca.postman_collection.json`](../postman/awuca.postman_collection.json)
as a working HTTP API, in a container, with no code and no Node install.

```bash
./start.sh          # foreground, Ctrl-C to stop
./start.sh -d       # detached, waits until it is actually serving
./start.sh --stop
```

Then:

```bash
curl localhost:4010/v1/public/landing
```

This is objective 1 of [`ai/tasks/apps.md`](../ai/tasks/apps.md): a mock of the
whole API, derived from the collection alone, before any implementation exists.

---

## Why this matters more than it looks

Prism reads Postman Collection v2.1 **natively** — no OpenAPI conversion step,
no config file. The collection is the only input. So the mock cannot drift from
the specification, because it *is* the specification, executed.

That makes it the baseline for everything else:

| | |
| --- | --- |
| `playwright-tests/` | Runs `@contract` against this first. Green here means the generated tests agree with the collection, which is what makes a later result against the app a statement about the app. |
| `vue-frontend/` | `AWUCA_API_URL=http://awuca-prism:4010 ./run.sh` drives the whole UI off the mock, before a single route exists in Python. |
| `python-backend/` | Has to satisfy the same saved examples. |

---

## Prism is stateless

It replays saved examples. It has no memory between requests, so:

* `POST` a closure and the status is `Pending` — but it was `Pending` before you
  posted, and would be if you never did.
* Set a loyalty ID and reading it back gives the canned one, not yours.
* `x-account-count: 5` returns whatever the example holds, always.

This is not a limitation to work around; it is the line between the two test
tags. `@contract` runs against both targets, `@stateful` only against Python.
See [`../playwright-tests/README.md`](../playwright-tests/README.md).

## Selecting a non-2xx example

Prism returns the lowest 2xx example by default. To reach a 400/401/404:

```bash
curl -i -H 'Prefer: code=404' -H 'Authorization: Bearer x' \
  'localhost:4010/v1/loyalty?accountId=acc-0002'
```

If that returns 200, Prism is ignoring the header and every negative contract case is meaningless against the mock
which will need to be fixed.

## It reads the collection once, at startup

Edit the collection and **restart** — there is no watch mode. This is the step
most easily forgotten in the incremental loop, where the symptom is a new
example that the mock stubbornly does not serve.

---

## Details worth knowing

| | |
| --- | --- |
| Image | `docker.io/stoplight/prism:5`, fully qualified. Podman has no implicit Docker Hub fallback, so a bare `stoplight/prism:5` fails with a short-name error unless the host happens to list a search registry. |
| Port | `4010`, published to `127.0.0.1` only. Override with `PRISM_PORT`. |
| Network | Joins the `awuca` network as `awuca-prism`, so the Playwright and Vue containers can reach it by name. Container-name DNS, not `--network=host`: the latter is Linux-only, and on a Mac "host" is the Podman VM. |
| Mount | `../postman` read-only. The `:Z` SELinux relabel is added only when `selinuxenabled` says so — asking for it on a Mac virtiofs share can fail outright. |
| `-m false` | **Required.** Prism defaults to multiprocess and crashes on startup in this image with `TypeError: Cannot read properties of undefined (reading 'isPrimary')` — `cluster` is undefined where `createMultiProcessPrism` expects it. It exits before binding a port and prints the yargs usage block above the stack trace, so it reads like an argument error rather than a runtime bug. Do not remove this flag without testing. |
| Licence | Apache-2.0. Meets the "free for commercial use and nimble" bar in the root README; that is why Prism rather than WireMock, which needs a JVM. |

Clean-up is the whole point of running it this way:

```bash
podman rmi docker.io/stoplight/prism:5
```
