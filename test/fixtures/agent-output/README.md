# Vendored agent output fixtures

Real output captured from the actual agent CLIs, used to test
`scripts/usage.mjs` against the genuine output shapes rather than mocks.

| File | Source | Captured |
| --- | --- | --- |
| `claude-result.json` | `claude -p … --output-format json`, Claude Code 2.1.199 | 2026-07-06 |
| `claude-stream.jsonl` | `claude -p … --output-format stream-json --verbose` (includes a Bash tool call), Claude Code 2.1.199 | 2026-07-06 |
| `copilot-stream.jsonl` | `copilot -p … --output-format json`, Copilot CLI 1.0.63 | 2026-07-06 |
| `copilot-session-state/<sessionId>/events.jsonl` | the Copilot CLI's own session log for the same run (`~/.copilot/session-state/`) | 2026-07-06 |

Both runs used the same trivial prompt ("In one sentence, what does 'git bisect'
do?"), so the traces are small but structurally complete: the Claude result
carries `usage`, `modelUsage`, and `total_cost_usd`; the Copilot stream carries
`assistant.message` events and the final `result` event with `premiumRequests`;
the session log carries the per-call token usage that `normalize` merges in.

Sanitization: the single `session.skills_loaded` event was removed from
`copilot-stream.jsonl` — it lists the capturing user's personally installed
skills and plays no part in usage accounting. Everything else is verbatim.

If a CLI update changes its output shape, re-capture with the commands above
and update the suite's expected values in `usage-normalize.test.sh`.
