/**
 * Prints the contract coverage the collection currently produces.
 *
 *   npm run cases
 *
 * Useful when working the incremental loop: edit the collection, run this, and
 * see the new cases appear before running anything against a server. Requires
 * Node >= 22.6 for --experimental-strip-types.
 */

import { loadCases, requestsWithoutExamples, COLLECTION_PATH } from './collection.ts';

const cases = loadCases();
const uncovered = requestsWithoutExamples();

console.log(`Collection: ${COLLECTION_PATH}\n`);

let folder = '';
for (const testCase of cases) {
  if (testCase.folder !== folder) {
    folder = testCase.folder;
    console.log(`  ${folder}`);
  }
  const auth = testCase.noAuth ? 'anon' : 'auth';
  console.log(
    `    ${String(testCase.expectedCode).padEnd(3)} ${testCase.method.padEnd(6)} ` +
      `${testCase.path.padEnd(40)} ${auth}  ${testCase.exampleName}`,
  );
}

console.log(`\n${cases.length} contract cases from ${new Set(cases.map((c) => `${c.folder}/${c.requestName}`)).size} requests.`);

if (uncovered.length > 0) {
  console.log(`\nWARNING - requests with no saved example, therefore untested:`);
  for (const name of uncovered) console.log(`  ${name}`);
  process.exitCode = 1;
}
