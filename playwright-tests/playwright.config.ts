/**
 * One suite, two tags, three targets.
 *
 *   prism        -- @contract only. The baseline: proves the collection is
 *                   internally coherent and that a mock can serve it.
 *   python-local -- @contract and @stateful against the local FastAPI app.
 *   python-aws   -- the same, against the ECS deployment behind the ALB test
 *                   listener. Used as the pre-promotion gate.
 *
 * Adding a project here is how you point the identical specs at another
 * environment; no spec file mentions a host.
 */

import { defineConfig } from '@playwright/test';
import type { TargetOptions } from './src/fixtures.ts';

const PRISM_URL = process.env.AWUCA_PRISM_URL ?? 'http://localhost:4010';
const PYTHON_URL = process.env.AWUCA_PYTHON_URL ?? 'http://localhost:8080';
/** Set to the ALB test listener when validating a candidate before promotion. */
const AWS_URL = process.env.AWUCA_AWS_URL ?? '';

export default defineConfig<TargetOptions>({
  testDir: './tests',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: [['list'], ['html', { open: 'never' }]],

  use: {
    extraHTTPHeaders: { Accept: 'application/json' },
    trace: 'retain-on-failure',
    // No browser is configured or launched anywhere in this suite -- every
    // test uses the `request` fixture. That keeps the install to the driver
    // alone (PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1), which matters for the
    // footprint bar in README "Tooling constraints".
  },

  projects: [
    {
      name: 'prism',
      use: { target: 'prism', baseURL: PRISM_URL },
      grep: /@contract/,
    },
    {
      name: 'python-local',
      use: { target: 'python', baseURL: PYTHON_URL },
    },
    // Only offered when a URL is supplied. A project with an empty baseURL
    // fails with "Invalid URL" rather than saying what is actually wrong.
    ...(AWS_URL
      ? [
          {
            name: 'python-aws',
            use: { target: 'python' as const, baseURL: AWS_URL },
          },
        ]
      : []),
  ],
});
