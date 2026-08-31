/**
 * Reads the Postman collection and flattens it into a list of test cases.
 *
 * This module is the reason the @contract suite needs no new test code when the
 * API grows: every request x saved example in the collection becomes one case,
 * discovered at run time. Add an endpoint to the collection and its contract
 * coverage appears on the next run.
 *
 * The unit of testing is the EXAMPLE, not the request. A saved example is
 * already a (request, expected response) pair -- the 401 example on List
 * Accounts carries `auth: noauth` in its originalRequest, the 404 example on
 * Get Account Address carries a nonexistent accountId. Driving the example's
 * own originalRequest is therefore what makes negative cases work without
 * hand-writing them.
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));

export const COLLECTION_PATH = path.resolve(
  HERE,
  '..',
  '..',
  'postman',
  'awuca.postman_collection.json',
);

export interface TestCase {
  /** Stable identifier used as the Playwright test title. */
  id: string;
  folder: string;
  requestName: string;
  exampleName: string;
  method: string;
  /** Path only, with :pathVariables already substituted. No host. */
  path: string;
  query: Record<string, string>;
  headers: Record<string, string>;
  body?: string;
  /** True when the request opts out of the collection-level bearer auth. */
  noAuth: boolean;
  expectedCode: number;
  /** Parsed example body, or undefined for an empty body such as a 204. */
  expectedBody?: unknown;
}

interface PostmanUrl {
  raw?: string;
  path?: string[];
  query?: Array<{ key: string; value: string; disabled?: boolean }>;
  variable?: Array<{ key: string; value: string }>;
}

interface PostmanHeader {
  key: string;
  value: string;
  disabled?: boolean;
}

interface PostmanRequest {
  method: string;
  header?: PostmanHeader[];
  body?: { mode?: string; raw?: string };
  url?: PostmanUrl | string;
  auth?: { type?: string };
}

interface PostmanExample {
  name: string;
  code: number;
  status?: string;
  body?: string;
  header?: PostmanHeader[];
  originalRequest?: PostmanRequest;
}

interface PostmanItem {
  name: string;
  item?: PostmanItem[];
  request?: PostmanRequest;
  response?: PostmanExample[];
}

interface PostmanCollection {
  info: { name: string };
  variable?: Array<{ key: string; value: string }>;
  item: PostmanItem[];
}

/** Substitutes {{collectionVariables}} using the collection's own defaults. */
function interpolate(input: string, vars: Record<string, string>): string {
  return input.replace(/\{\{(\w+)\}\}/g, (whole, name: string) =>
    Object.prototype.hasOwnProperty.call(vars, name) ? vars[name] : whole,
  );
}

function buildPath(url: PostmanUrl | string | undefined, vars: Record<string, string>): string {
  if (!url) return '/';
  if (typeof url === 'string') return interpolate(url, vars);

  const pathVars: Record<string, string> = {};
  for (const v of url.variable ?? []) {
    pathVars[v.key] = interpolate(v.value ?? '', vars);
  }

  const segments = (url.path ?? []).map((segment) => {
    if (!segment.startsWith(':')) return interpolate(segment, vars);
    const name = segment.slice(1);
    // An unresolved :pathVariable is a defect in the collection, not something
    // to paper over with a placeholder that would 404 confusingly.
    if (!(name in pathVars)) {
      throw new Error(`Collection defines :${name} in the path but supplies no url.variable for it`);
    }
    return encodeURIComponent(pathVars[name]);
  });

  return '/' + segments.join('/');
}

function buildQuery(url: PostmanUrl | string | undefined, vars: Record<string, string>): Record<string, string> {
  if (!url || typeof url === 'string') return {};
  const out: Record<string, string> = {};
  for (const q of url.query ?? []) {
    if (q.disabled) continue;
    out[q.key] = interpolate(q.value ?? '', vars);
  }
  return out;
}

function buildHeaders(request: PostmanRequest, vars: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const h of request.header ?? []) {
    if (h.disabled) continue;
    out[h.key] = interpolate(h.value ?? '', vars);
  }
  return out;
}

function parseBody(raw: string | undefined): unknown {
  if (raw === undefined || raw.trim() === '') return undefined;
  try {
    return JSON.parse(raw);
  } catch {
    return raw;
  }
}

export function loadCollection(collectionPath: string = COLLECTION_PATH): PostmanCollection {
  return JSON.parse(fs.readFileSync(collectionPath, 'utf8')) as PostmanCollection;
}

export function loadCases(collectionPath: string = COLLECTION_PATH): TestCase[] {
  const collection = loadCollection(collectionPath);

  const vars: Record<string, string> = {};
  for (const v of collection.variable ?? []) vars[v.key] = v.value ?? '';

  const cases: TestCase[] = [];

  const walk = (items: PostmanItem[], folder: string): void => {
    for (const item of items) {
      if (item.item) {
        walk(item.item, item.name);
        continue;
      }
      if (!item.request) continue;

      for (const example of item.response ?? []) {
        // Prefer the example's own originalRequest: that is what carries the
        // differing input for negative cases.
        const request = example.originalRequest ?? item.request;
        const url = request.url ?? item.request.url;

        cases.push({
          id: `${folder} > ${item.name} > ${example.name}`,
          folder,
          requestName: item.name,
          exampleName: example.name,
          method: (request.method ?? item.request.method ?? 'GET').toUpperCase(),
          path: buildPath(url, vars),
          query: buildQuery(url, vars),
          headers: buildHeaders(request, vars),
          body: request.body?.raw ? interpolate(request.body.raw, vars) : undefined,
          noAuth: (request.auth?.type ?? item.request.auth?.type) === 'noauth',
          expectedCode: example.code,
          expectedBody: parseBody(example.body),
        });
      }
    }
  };

  walk(collection.item, '');

  if (cases.length === 0) {
    throw new Error(`No examples found in ${collectionPath} -- the contract suite would silently pass`);
  }

  return cases;
}

/**
 * Names of requests that carry no saved example. Such a request is invisible
 * to Prism and to loadCases(), so it would escape contract coverage entirely.
 */
export function requestsWithoutExamples(collectionPath: string = COLLECTION_PATH): string[] {
  const collection = loadCollection(collectionPath);
  const uncovered: string[] = [];

  const walk = (items: PostmanItem[], folder: string): void => {
    for (const item of items) {
      if (item.item) {
        walk(item.item, item.name);
        continue;
      }
      if (item.request && (item.response ?? []).length === 0) {
        uncovered.push(`${folder} > ${item.name}`);
      }
    }
  };

  walk(collection.item, '');
  return uncovered;
}
