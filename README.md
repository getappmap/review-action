# AppMap Behavioral Review Action

Maintain a project's **AppMap gold-trace** baseline and produce an interpreted
**behavioral review** of a pull request — the kind of review that catches regressions
which still pass the test suite (a dropped authorization guard, a new query inside a
loop, a security-sensitive function that changed but gained no check).

Unlike a compiled action, the work here is performed by an **AI coding agent** —
either **Claude Code** or the **GitHub Copilot CLI** (headless) — running two skills
from [`getappmap/skills`](https://github.com/getappmap/skills):

- **`appmap-gold-traces`** — curates, records, and blesses the committed baseline of
  AppMap recordings.
- **`appmap-review`** — diffs the head revision's gold traces against the base
  revision's and writes the interpreted, actionable review.

## What it does, in order

1. **Install skills.** Clones `getappmap/skills` into a working directory. For the
   `claude` agent it **symlinks only the skills this action uses**
   (`appmap-gold-traces`, `appmap-review`, and their `appmap-label`/`appmap-record`
   dependencies) into `~/.claude/skills` — so it never clobbers other skills already
   installed there. For the `copilot` agent the skills are read directly from the
   working directory (Copilot doesn't load `~/.claude/skills`).
2. **Update gold traces.** The agent bootstraps the baseline if the project has none
   (figuring out how to run the project's tests **from the project itself** — there is
   no user to ask in CI), or re-records and blesses drift if it already exists.
3. **Commit & push.** All changes the agent made — blessed baselines, the spec, and
   any AppMap labels or gold tests it added — are committed and pushed to the PR head
   branch. Nothing the agent did is lost or left as a manual chore.
4. **Review.** The agent compares the (freshly committed) head traces against the base
   revision and writes the interpreted review.
5. **Publish.** The review is posted as a **sticky PR comment** and written to the
   **job summary**, with an **agent usage** footer (models, tokens, and cost for
   Claude / premium requests for Copilot — all as reported by the agent itself).
   Re-runs update the comment in place. When the action runs more than once per PR
   (e.g. a matrix), set `comment-tag` to a stable per-entry key — each tag owns its
   own comment; it defaults to `working-directory`, so a monorepo matrix over
   package roots separates automatically.

### On automatic blessing

The `appmap-gold-traces` skill normally treats blessing as human-gated. In CI that
isn't possible, and *not* committing would lose the recorded data. So this action
blesses and commits drift automatically, and relies on the **review report** to flag
anything that looks like a regression. If you don't like the committed changes, edit
the code and re-run — the action will re-record and amend the baseline.

## Choosing the agent runtime

Set the `agent` input to pick which LLM agent runs the skills:

- **`claude`** (default) — Claude Code. Needs an `anthropic-api-key`.
- **`copilot`** — GitHub Copilot CLI. Needs a Copilot-enabled GitHub token via
  `copilot-token`. The default workflow `GITHUB_TOKEN` **cannot** use Copilot, so
  supply a PAT (or other Copilot-enabled token) as a secret.

```yaml
      - uses: getappmap/review-action@v1
        with:
          agent: copilot
          copilot-token: ${{ secrets.COPILOT_TOKEN }}
```

## Prerequisites

- **A runnable test environment.** Recording executes the project's tests under the
  AppMap recorder. Your workflow **must** set up the language toolchain, dependencies,
  and any services/DB **before** this action runs. The action cannot provide this.
- **Agent credentials:** an `anthropic-api-key` (for `agent: claude`) **or** a
  Copilot-enabled `copilot-token` (for `agent: copilot`).
- **Write permissions:** `contents: write` (push baselines) and
  `pull-requests: write` (post the comment).

## Usage

```yaml
name: AppMap Behavioral Review
on:
  pull_request:

permissions:
  contents: write
  pull-requests: write

jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0            # review reads gold traces from both revisions' history
          ref: ${{ github.head_ref }}

      # --- set up YOUR project's test environment here ---
      # e.g. actions/setup-python + pip install, or setup-node + npm ci, plus any DB.

      - uses: getappmap/review-action@v1
        with:
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `agent` | `claude` | Agent runtime: `claude` (Claude Code) or `copilot` (GitHub Copilot CLI). |
| `anthropic-api-key` | — | API key for Claude Code. Required when `agent: claude`. |
| `copilot-token` | `github-token` | Copilot-enabled GitHub token. Required when `agent: copilot`. |
| `copilot-model` | (Copilot default) | Model override for the Copilot CLI (`--model`). |
| `github-token` | `${{ github.token }}` | Pushes baselines and posts the PR comment. |
| `base-revision` | `${{ github.base_ref }}` | Review baseline (any git ref). |
| `head-revision` | `${{ github.sha }}` | Review head (any git ref). |
| `gold-traces-dir` | `gold_traces` | Managed gold-traces dir (engine `--dir`). |
| `working-directory` | `.` | Dir the agent/engine run from (a package root in a monorepo). |
| `comment-tag` | `working-directory` | Per-entry key (e.g. `matrix.name`) giving each matrix run its own sticky PR comment. `.` means untagged. |
| `skills-repo` | `https://github.com/getappmap/skills.git` | Skills repository URL. |
| `skills-ref` | `main` | Branch/tag/SHA of the skills repo to pin. |
| `claude-model` | (Claude Code default) | Model override (`--model`). |
| `appmap-cli-version` | latest release | AppMap CLI release version (from getappmap/appmap-js GitHub releases). Beats a PATH `appmap`. |
| `node-version` | `22` | Node the action needs. A workflow-provided `node` at this major or newer is used as-is. |
| `commit-message` | `chore(gold-traces): update behavioral baseline` | Commit subject (`[skip ci]` is appended). |

## Outputs

| Output | Description |
| --- | --- |
| `report-file` | Path to the generated Markdown review report. |
| `gold-traces-updated` | `true` if changes were committed and pushed. |
| `models` | Comma-separated model ids the agent reported using. |
| `cost-usd` | Total cost in USD, as reported by Claude Code. Empty for `agent: copilot`. |
| `premium-requests` | Total premium requests, as reported by the Copilot CLI. Empty for `agent: claude`. |
| `input-tokens` | Total input tokens (including cache reads/writes), when the agent reported them. |
| `output-tokens` | Total output tokens, when the agent reported them. |
| `duration-ms` | Total agent wall time in milliseconds (update + review runs). |

All usage figures come directly from the agent's own output — nothing is estimated
from pricing tables. Copilot bills in premium requests, not dollars, so no dollar
figure is shown or approximated for it. The same numbers are appended to the PR
comment and job summary as an "Agent usage" footer.

## Toolchain install and caching

Setup is designed to cost seconds on a re-run:

- **Node** — installed only if the workflow doesn't already provide `node` at
  `node-version`'s major or newer, so your own `setup-node` step wins.
- **AppMap CLI** — a single prebuilt binary downloaded from getappmap/appmap-js
  GitHub releases (the same channel the legacy install-action uses), cached keyed
  on the release version. A repo that builds appmap-js itself can put `appmap` on
  PATH and no install happens.
- **Agent CLI** (Claude Code / Copilot CLI) — installed from npm into a dedicated
  prefix, cached keyed on the resolved package version (plus platform and Node
  major). The Copilot CLI's self-downloaded platform engine is included in the
  cache; the install step pre-warms it.

Cache keys embed the resolved versions, so caches invalidate themselves exactly
when a new tool version ships — re-runs between releases restore from cache with
no registry or API traffic beyond two version lookups.

## Re-trigger loop protection

The action pushes a commit to the PR branch, which would normally re-fire the
workflow. Two guards prevent an infinite loop:

1. `[skip ci]` is appended to the commit subject.
2. The action bails early if `HEAD` is already one of its own
   `chore(gold-traces): …` commits authored by `github-actions[bot]`.

## Layout

```
action.yml                     composite action definition
prompts/
  update-gold-traces.md        agent prompt for the appmap-gold-traces skill
  review.md                    agent prompt for the appmap-review skill
scripts/
  guard.sh                     re-trigger loop guard (skip our own commits)
  install-skills.sh            clone skills repo, symlink the used skills
  run-agent.sh                 run the selected agent headless with a prompt template
  commit-and-push.sh           commit all agent changes, push to the PR branch
  post-review.sh               job summary + sticky PR comment
test/                          self-test harness (see test/README.md)
```

## Testing

`test/` holds an offline, dependency-free harness that exercises the action's
scripts by replacing the externals (the agent CLI, `gh`, and the git remote) with
mocks — so it runs with no API keys and no network:

```sh
test/run.sh
```

See [`test/README.md`](test/README.md) for what each suite covers.
