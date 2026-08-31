// The only place in the app that talks to the network.
//
// Paths are RELATIVE and hard-coded to /v1/... on purpose. There is no
// configurable base URL and no VITE_API_URL, because the deployed shape puts
// the bundle and the API behind one CloudFront distribution -- same origin, no
// preflight, nothing to configure at build time. Introducing a base URL would
// mean the bundle had to be rebuilt per environment, which defeats "build once,
// promote the artifact" and would make the blue/green swap a rebuild.
//
// The dev server reaches a local backend via the proxy in vite.config.js.
//
// Paths must match the ones pinned in edge/kvs/routing.yaml.

const TOKEN_KEY = 'awuca.accessToken'

export function storedToken() {
  return sessionStorage.getItem(TOKEN_KEY)
}

function setToken(token) {
  if (token) sessionStorage.setItem(TOKEN_KEY, token)
  else sessionStorage.removeItem(TOKEN_KEY)
}

export class ApiError extends Error {
  constructor(status, body) {
    // The API has exactly one error shape: { error, message }. Falling back to
    // the status text keeps this honest if something upstream (CloudFront, the
    // ALB) returns a non-JSON error that never reached the app.
    super(body?.message ?? `Request failed with status ${status}`)
    this.status = status
    this.slug = body?.error ?? 'unknown'
  }
}

async function request(method, path, { body, auth = true, query } = {}) {
  const url = query ? `${path}?${new URLSearchParams(query)}` : path
  const headers = {}

  if (body !== undefined) headers['Content-Type'] = 'application/json'
  if (auth) {
    const token = storedToken()
    if (!token) throw new ApiError(401, { error: 'unauthorized', message: 'Not signed in' })
    headers.Authorization = `Bearer ${token}`
  }

  const response = await fetch(url, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  })

  // 204 has no body, and calling .json() on it throws.
  if (response.status === 204) return null

  const text = await response.text()
  const parsed = text ? JSON.parse(text) : null

  if (!response.ok) throw new ApiError(response.status, parsed)
  return parsed
}

export const api = {
  // Purpose 1 -- unauthenticated.
  landing: () => request('GET', '/v1/public/landing', { auth: false }),

  // Purpose 2. x-account-count is the whole point of this call: it decides how
  // many accounts the customer is issued.
  async signIn(customerId, accountCount) {
    const response = await fetch('/v1/auth/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-account-count': String(accountCount) },
      body: JSON.stringify({ customerId, password: 'lorem-ipsum' }),
    })
    const text = await response.text()
    const parsed = text ? JSON.parse(text) : null
    if (!response.ok) throw new ApiError(response.status, parsed)

    setToken(parsed.accessToken)
    return parsed
  },

  signOut: () => setToken(null),

  // Purpose 3.
  accounts: () => request('GET', '/v1/accounts'),

  // Purpose 4 -- read-only, no write verb exists.
  address: (accountId) => request('GET', `/v1/accounts/${accountId}/address`),

  // Purpose 7.
  paymentHistory: (accountId) => request('GET', `/v1/accounts/${accountId}/payments`),

  // Purpose 5.
  paymentMethods: () => request('GET', '/v1/payments/methods'),
  addPaymentMethod: (method) => request('POST', '/v1/payments/methods', { body: method }),
  updatePaymentMethod: (id, method) => request('PUT', `/v1/payments/methods/${id}`, { body: method }),
  deletePaymentMethod: (id) => request('DELETE', `/v1/payments/methods/${id}`),

  // Purpose 6.
  loyalty: (accountId) => request('GET', '/v1/loyalty', { query: { accountId } }),
  joinLoyalty: (accountId) => request('POST', '/v1/loyalty/signup', { body: { accountId, optIn: true } }),

  // Purpose 8.
  closureStatus: (accountId) => request('GET', `/v1/accounts/${accountId}/closure`),
  requestClosure: (accountId, reason, effectiveDate) =>
    request('POST', `/v1/accounts/${accountId}/closure`, { body: { reason, effectiveDate } }),

  // Not a customer purpose. Renders which pool served you, which is the only
  // way to see a blue/green swap from the browser.
  whoami: () => request('GET', '/v1/whoami', { auth: false }),
}
