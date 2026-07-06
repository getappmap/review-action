# review-action self-test harness

An offline, dependency-free harness that tests the action's scripts by replacing
its three externals with mocks:

- **the agent CLI** (`claude` / `copilot`) → `test/mocks/{claude,copilot}` — a fake
  that records how it was invoked and simulates the skill side effects (seeds gold
  traces for `update`, writes a report for `review`). No LLM, no API key.
- **`gh`** → `test/mocks/gh` — logs the GitHub API calls it receives.
- **the git remote** → a local bare repo (`git init --bare` + `file://`). No network.

Run everything:

```sh
test/run.sh
```

Run one suite:

```sh
test/run.sh run-agent          # or: test/run.sh run-agent.test.sh
```

## Layout

```
run.sh                 entrypoint: discovers and runs the suites
lib/assert.sh          tiny assertion helpers (no deps)
mocks/
  claude  copilot      fake agent CLIs (both exec _agent.sh)
  _agent.sh            shared mock-agent logic
  gh                   fake GitHub CLI (PR comments + appmap-js release listing)
  npm                  fake npm (view -> canned version; install -> stub agent binary)
  curl                 fake curl (writes a runnable stub instead of downloading)
fixtures/
  skills-src/          minimal skills repo cloned by install-skills tests
                       (includes an unused skill to prove it is NOT linked)
  sample-project/      tiny AppMap-instrumented Node app used as a working dir
suites/
  guard.test.sh            loop guard: skip only our own gold-traces commits
  install-tools.test.sh    node detection, version resolution for cache keys,
                           cache-hit skips for the appmap binary and agent CLI
  install-skills.test.sh   symlink only used skills; never clobber; copilot skips
  run-agent.test.sh        prompt render, agent branching, token checks, report out,
                           usage records (claude cost, copilot premium requests)
  commit-and-push.test.sh  no-op when clean; [skip ci] bot commit; push to remote
  post-review.test.sh      summary always; PR create-vs-update; non-PR skips gh;
                           per-matrix comment-tag markers; usage footer append
  usage-report.test.sh     usage.mjs aggregation: cost/premium-request footers,
                           step outputs, empty no-op
  usage-normalize.test.sh  usage.mjs parsing of VENDORED REAL agent output
                           (fixtures/agent-output/) — genuine CLI shapes, not mocks
```

## Scope

This harness covers the **orchestration** layer — the action's shell logic — which
is where the action's own bugs live. It deliberately does **not** exercise:

- the real agent/LLM (whether the skills produce good traces/reviews — that belongs
  to the `getappmap/skills` repo's tests and an optional live smoke test), or
- the real AppMap recording/compare engine against `sample-project` (an engine
  integration layer could add that later; the fixture is already a runnable Node app).

## Requirements

- `bash` and `git`.
- `jq` for the `post-review` suite only; it self-skips if `jq` is absent.
- `node` for the `run-agent`, `usage-report`, and `usage-normalize` suites (usage
  accounting runs through `scripts/usage.mjs`); the usage suites self-skip if
  `node` is absent.
