# AppMap Behavioral Review Action

Maintain a project's **AppMap gold-trace** baseline and produce an interpreted
**behavioral review** of a pull request — the kind of review that catches regressions
which still pass the test suite (a dropped authorization guard, a new query inside a
loop, a security-sensitive function that changed but gained no check).

Unlike a compiled action, the work here is performed by an **AI coding agent**
(Claude Code, headless) running two skills from
[`getappmap/skills`](https://github.com/getappmap/skills):

- **`appmap-gold-traces`** — curates, records, and blesses the committed baseline of
  AppMap recordings.
- **`appmap-review`** — diffs the head revision's gold traces against the base
  revision's and writes the interpreted, actionable review.

## What it does, in order

1. **Install skills.** Clones `getappmap/skills` into a working directory and
   **symlinks only the skills this action uses** (`appmap-gold-traces`,
   `appmap-review`, and their `appmap-label`/`appmap-record` dependencies) into
   `~/.claude/skills` — so it never clobbers other skills already installed there.
2. **Update gold traces.** The agent bootstraps the baseline if the project has none
   (figuring out how to run the project's tests **from the project itself** — there is
   no user to ask in CI), or re-records and blesses drift if it already exists.
3. **Commit & push.** All changes the agent made — blessed baselines, the spec, and
   any AppMap labels or gold tests it added — are committed and pushed to the PR head
   branch. Nothing the agent did is lost or left as a manual chore.
4. **Review.** The agent compares the (freshly committed) head traces against the base
   revision and writes the interpreted review.
5. **Publish.** The review is posted as a **sticky PR comment** and written to the
   **job summary**.

### On automatic blessing

The `appmap-gold-traces` skill normally treats blessing as human-gated. In CI that
isn't possible, and *not* committing would lose the recorded data. So this action
blesses and commits drift automatically, and relies on the **review report** to flag
anything that looks like a regression. If you don't like the committed changes, edit
the code and re-run — the action will re-record and amend the baseline.

## Prerequisites

- **A runnable test environment.** Recording executes the project's tests under the
  AppMap recorder. Your workflow **must** set up the language toolchain, dependencies,
  and any services/DB **before** this action runs. The action cannot provide this.
- **An Anthropic API key** for the Claude Code agent (`anthropic-api-key`).
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
| `anthropic-api-key` | — (**required**) | API key for the Claude Code agent. |
| `github-token` | `${{ github.token }}` | Pushes baselines and posts the PR comment. |
| `base-revision` | `${{ github.base_ref }}` | Review baseline (any git ref). |
| `head-revision` | `${{ github.sha }}` | Review head (any git ref). |
| `gold-traces-dir` | `gold_traces` | Managed gold-traces dir (engine `--dir`). |
| `working-directory` | `.` | Dir the agent/engine run from (a package root in a monorepo). |
| `skills-repo` | `https://github.com/getappmap/skills.git` | Skills repository URL. |
| `skills-ref` | `main` | Branch/tag/SHA of the skills repo to pin. |
| `claude-model` | (Claude Code default) | Model override (`--model`). |
| `appmap-cli-version` | latest | `@appland/appmap` version to install. |
| `commit-message` | `chore(gold-traces): update behavioral baseline` | Commit subject (`[skip ci]` is appended). |

## Outputs

| Output | Description |
| --- | --- |
| `report-file` | Path to the generated Markdown review report. |
| `gold-traces-updated` | `true` if changes were committed and pushed. |

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
  install-skills.sh            clone skills repo, symlink the used skills
  run-agent.sh                 run Claude Code headless with a prompt template
  commit-and-push.sh           commit all agent changes, push to the PR branch
  post-review.sh               job summary + sticky PR comment
```
