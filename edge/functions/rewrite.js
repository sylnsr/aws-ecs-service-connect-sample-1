// CloudFront Function — viewer request. URI rewrites only.
//
// Scope is vanity URLs and legacy path migrations, nothing else. Blue/green is
// decided entirely at the ALB; this function must never influence which pool a
// request reaches. See README section 2E.
//
// THIS EXACT SOURCE runs in both places. The local edge shim loads it and so
// does Terraform (stub-tf/kvs.tf) — there is no local-only variant, because a
// variant is a thing that can be right locally and wrong in production.
//
// CloudFront Functions have no environment variables, so the store ID has to
// be a literal. The placeholder below is substituted at load time: the local
// container's store ID in the shim, `aws_cloudfront_key_value_store.id` in
// Terraform. Do not replace it in the committed source.
//
// Budget: 10 KB source, 2 MB memory, ~1 ms CPU. No network, no filesystem, and
// no way to instrument it — `console.log` is the only telemetry available.

import cf from 'cloudfront';

const kvs = cf.kvs('KEY_VALUE_STORE_ID_PLACEHOLDER');

// Lookup is an exact match on the normalised URI. routing.yaml documents keys
// as lowercase with no trailing slash, so normalise the incoming URI the same
// way or `/Pay` and `/pay/` would miss a table that clearly covers them.
function normalise(uri) {
  const lower = uri.toLowerCase();
  return lower.length > 1 && lower.endsWith('/') ? lower.slice(0, -1) : lower;
}

async function handler(event) {
  const request = event.request;
  const key = normalise(request.uri);

  try {
    // `exists` first, because `get` on a missing key throws, and a throw here
    // is a 503 to the viewer. A miss is the overwhelmingly common case — every
    // request for a path that was never a vanity URL — so it must be cheap and
    // it must not be an error.
    if (await kvs.exists(key)) {
      request.uri = await kvs.get(key);
    }
  } catch (err) {
    // Fail open. A rewrite is a convenience; a broken store must not take the
    // site down. The unrewritten URI still reaches an origin.
    console.log(`kvs lookup failed for ${key}: ${err}`);
  }

  return request;
}
