# FreeLLMAPI security and dependency patch log

This file records why the local changes exist and what remains open. It is not a claim that the dependency tree is vulnerability-free.

## Applied changes

1. **Refresh the dependency lock and security-sensitive packages.** Updated Zod to 4.6.7 and Drizzle ORM to 0.45.4, refreshed the lockfile, and moved the test runners from Vitest 3 to Vitest 4. Vitest 4 retains the repository's declared Node 20.18+ support; Vitest 5 would have required a newer Node baseline. The resolved `typescript-eslint` packages were refreshed to 8.72.2. `react-is` 19.2.4 is declared for the client and at the workspace root because Recharts imports it and the hoisted workspace build must resolve the peer.

2. **Migrate validation code to Zod 4.** Replaced `ZodError.errors` with the supported `issues` collection across request routes and services; Zod 4 no longer exposes the old property in the same way. Updated `z.record` declarations to include explicit key schemas, and refined the compression-engine update schema so `enabled` is validated while engine-specific settings remain extensible. The pipeline's validated config is adapted to the existing engine interface.

3. **Keep build and test boundaries explicit.** The client TypeScript application build now excludes test/spec files, which are run by Vitest and may import Node-only APIs. Added a CLI Vitest config targeting the CLI's actual `src/**/*.test.ts` tests; without it the runner reported no test files. These changes make validation exercise the intended app and test sources rather than silently skipping or misclassifying them.

4. **Add a regression test for settings validation.** Invalid Anthropic and Gemini model-map updates must return HTTP 400 with the existing structured validation message. This caught the Zod 4 `.errors` incompatibility, which otherwise surfaced as a server error.

## Verification

- `npm ci --dry-run --no-audit`: passed.
- Server, client, and CLI TypeScript builds: passed.
- Client tests: 69 passed; i18n check passed for 60 locales and 750 keys.
- CLI tests: 44 passed.
- Anthropic route tests, including the model-map regression: 17 passed.
- Full server suite: 1,844 passed and 1 failed (1,845 total). The remaining failure is the protected-token-heavy compression timing assertion: 316.4 ms measured against a 250 ms limit; an isolated rerun measured 331.2 ms and failed the same assertion. This is not reported as a pass.
- `npm audit` on the updated lockfile: 16 findings (2 low, 14 moderate, 0 high, 0 critical). Earlier work recorded 45 findings, but audit databases and lock graphs change; this is not a controlled advisory-by-advisory comparison.

## Open findings and compatibility risk

The remaining audit findings are concentrated in the Drizzle Kit/esbuild chain, `shadcn`/`ts-morph`/`minimatch`, and `typescript-eslint`/`minimatch`. The audit's suggested fixes include moving Drizzle Kit to 0.18.1 and shadcn to 1.0.0, both major compatibility changes from the currently used versions. They were not applied automatically: migration tooling and UI-generation workflows need a compatibility review and tests before a downgrade or major switch. The current tree therefore has no high/critical npm audit findings, but still has moderate and low findings that require follow-up.

Do not treat this fork as a completed security clearance until the remaining audit findings and the server timing failure have been reviewed and resolved or explicitly accepted.
