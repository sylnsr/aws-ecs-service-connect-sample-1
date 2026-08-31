// CloudFront Function — viewer request, S3 behaviour only.
//
// vue-router uses history mode, so /accounts/acc-0001 is a real URL a customer
// can bookmark or reload. No such object exists in the bucket, so S3 answers
// 403 (a private bucket masks 404 as 403) and the customer gets an XML error
// page instead of the app.
//
// WHY NOT `custom_error_response`. The obvious fix — map 403/404 to
// /index.html with a 200 — is configured on the DISTRIBUTION, not on a
// behaviour, so it applies to the API origin too. Every legitimate 404 from
// /v1/loyalty or /v1/accounts/{id}/closure would come back as the HTML app
// shell with a 200 status. Those 404s are load-bearing: they are the
// "not enrolled" and "no closure request" states, they are documented as saved
// examples in the Postman collection, and the contract suite asserts them.
// A whole class of API errors would be silently swallowed.
//
// So the fallback is done here instead, where it can be attached to the S3
// behaviour alone. The API behaviours carry rewrite.js and never see this.
//
// Budget: 10 KB source, 2 MB memory, ~1 ms CPU. No network, no filesystem.

// A request for a real asset always has a file extension: /assets/index-a1b2.js,
// /favicon.ico. A route never does. That is a heuristic, not a proof, but the
// failure mode is benign in both directions — a missing asset with an
// extension still 403s honestly, and an extensionless asset would need to be
// deliberately named that way.
const HAS_EXTENSION = /\.[a-z0-9]+$/i;

async function handler(event) {
  const request = event.request;

  if (request.uri !== '/' && !HAS_EXTENSION.test(request.uri)) {
    request.uri = '/index.html';
  }

  return request;
}
