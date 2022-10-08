/**
 * @flow
 * @format
 */

import simpleDiffAssertion from './simpleDiffAssertion';

import type {AssertionLocation, ErrorAssertion} from './assertionTypes';

function formatIfJSON(actual: string) {
  try {
    return JSON.stringify(JSON.parse(actual), null, 2);
  } catch (e) {
    return actual;
  }
}

export default function(
  expected: string,
  assertLoc: ?AssertionLocation,
): ErrorAssertion {
  return (reason: ?string, env) => {
    const actual = formatIfJSON(env.getLSPStderrSinceStartOfStep());
    expected = formatIfJSON(expected);
    const suggestion = {method: 'lspStderr', args: [formatIfJSON(actual)]};
    return simpleDiffAssertion(
      expected,
      actual,
      assertLoc,
      reason,
      'lspStderr',
      suggestion,
    );
  };
}
