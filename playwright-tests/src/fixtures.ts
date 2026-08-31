/**
 * Playwright fixtures shared by both suites.
 *
 * `target` is a project-scoped option rather than an environment variable so
 * that `playwright test` can run the prism and python projects in the same
 * invocation without them clobbering each other's configuration.
 */

import { test as base, type APIRequestContext } from '@playwright/test';
import { randomUUID } from 'node:crypto';

export type Target = 'prism' | 'python';

export interface TargetOptions {
  /** Which implementation this project points at. */
  target: Target;
}

export interface AwucaFixtures {
  /** Mints a bearer token, optionally for a given account count. */
  authenticate: (options?: { accountCount?: number; customerId?: string }) => Promise<string>;
  /** A bearer token for the collection's default account count. */
  accessToken: string;
  /**
   * A customer id unique to this test. Stateful tests must not share a
   * customer, or a closure raised by one test makes another's 404 case fail.
   */
  customerId: string;
}

export const test = base.extend<TargetOptions & AwucaFixtures>({
  target: ['python', { option: true }],

  customerId: async ({}, use) => {
    await use(`cust-${randomUUID()}`);
  },

  authenticate: async ({ request, customerId }, use) => {
    const mint = async (options: { accountCount?: number; customerId?: string } = {}) => {
      const response = await request.post('/v1/auth/token', {
        headers: {
          'Content-Type': 'application/json',
          'x-account-count': String(options.accountCount ?? 3),
        },
        data: { customerId: options.customerId ?? customerId, password: 'lorem-ipsum' },
      });
      if (!response.ok()) {
        throw new Error(`Could not mint a token: ${response.status()} ${await response.text()}`);
      }
      const body = (await response.json()) as { accessToken: string };
      return body.accessToken;
    };
    await use(mint);
  },

  accessToken: async ({ authenticate }, use) => {
    await use(await authenticate());
  },
});

export const expect = test.expect;

/** Bearer header helper, kept in one place so the scheme is not retyped. */
export function bearer(token: string): Record<string, string> {
  return { Authorization: `Bearer ${token}` };
}

/**
 * Prism replays the FIRST example whose status matches what it decides to
 * return, which by default is the lowest 2xx. To exercise the 400/401/404
 * examples against the mock we must ask for them explicitly with Prism's
 * Prefer header. The real backend ignores Prefer and produces the status
 * naturally from the request the example carries.
 *
 * This is the one place the two targets are treated differently, and it is
 * why the negative cases are a genuine contract check on Prism (the example
 * exists and has the documented shape) and a genuine behavioural check on
 * Python (the input really does produce that status).
 */
export function preferHeaders(target: Target, expectedCode: number): Record<string, string> {
  if (target !== 'prism') return {};
  return { Prefer: `code=${expectedCode}` };
}

export type { APIRequestContext };
