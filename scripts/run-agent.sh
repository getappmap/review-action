#!/usr/bin/env bash
# Run the selected agent (Claude Code or GitHub Copilot CLI) headless with one of
# the action's prompt templates.
#
# Usage: run-agent.sh <update|review>
set -euo pipefail

: "${ACTION_PATH:?ACTION_PATH is required}"

AGENT="${AGENT:-claude}"
mode="${1:?usage: run-agent.sh <update|review>}"

# Directory the skills were cloned into (must match scripts/install-skills.sh).
SKILLS_DIR="${RUNNER_TEMP:-/tmp}/getappmap-skills"
export SKILLS_DIR

render_prompt() {
  # Substitute a known set of ${VAR} placeholders in a template from the
  # environment. Pure bash (no envsubst dependency); only these names are
  # expanded, and command substitution / backticks in the template are left
  # untouched.
  local content var val
  content="$(cat "$1")"
  for var in GOLD_TRACES_DIR BASE_REVISION HEAD_REVISION REPORT_FILE SKILLS_DIR; do
    val="${!var:-}"
    content="${content//\$\{$var\}/$val}"
  done
  printf '%s' "$content"
}

# ---- build the base prompt ---------------------------------------------------
case "$mode" in
  update)
    : "${GOLD_TRACES_DIR:?GOLD_TRACES_DIR is required}"
    export GOLD_TRACES_DIR
    prompt="$(render_prompt "$ACTION_PATH/prompts/update-gold-traces.md")"
    ;;
  review)
    : "${BASE_REVISION:?BASE_REVISION is required}"
    : "${HEAD_REVISION:?HEAD_REVISION is required}"
    REPORT_FILE="$(pwd)/.appmap/review/report.md"
    mkdir -p "$(dirname "$REPORT_FILE")"
    export BASE_REVISION HEAD_REVISION REPORT_FILE
    prompt="$(render_prompt "$ACTION_PATH/prompts/review.md")"
    ;;
  *)
    echo "unknown mode: $mode" >&2
    exit 2
    ;;
esac

# ---- run the selected agent --------------------------------------------------
case "$AGENT" in
  claude)
    : "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY is required for agent 'claude'}"
    export ANTHROPIC_API_KEY
    model_args=()
    [[ -n "${CLAUDE_MODEL:-}" ]] && model_args=(--model "$CLAUDE_MODEL")
    # Claude auto-loads the skills from ~/.claude/skills (symlinked at install).
    # The CI job is the sandbox, so tool permissions are bypassed.
    claude -p "$prompt" \
      --dangerously-skip-permissions \
      "${model_args[@]}"
    ;;

  copilot)
    # Copilot uses a GitHub token with Copilot access; the default GITHUB_TOKEN
    # cannot, so prefer COPILOT_TOKEN and fall back to GITHUB_TOKEN.
    token="${COPILOT_TOKEN:-${GITHUB_TOKEN:-}}"
    if [[ -z "$token" ]]; then
      echo "error: agent 'copilot' needs a Copilot-enabled token (copilot-token input)" >&2
      exit 1
    fi
    export GH_TOKEN="$token" GITHUB_TOKEN="$token"
    model_args=()
    [[ -n "${COPILOT_MODEL:-}" ]] && model_args=(--model "$COPILOT_MODEL")

    # Copilot does not load ~/.claude/skills, so tell it where the skills live on
    # disk and to follow them. The skills reference each other and ship an engine
    # under each skill's assets/ — all reachable under $SKILLS_DIR.
    preamble="You have AppMap skills available on disk under ${SKILLS_DIR}. Wherever the
task below says to \"use the <name> skill\", read ${SKILLS_DIR}/<name>/SKILL.md and
follow it, including any skills it references (e.g. appmap-label, appmap-record) and
its engine at ${SKILLS_DIR}/<name>/assets/ (substitute that path for any \"<skill>\"
placeholder). Do not ask questions; you are non-interactive.

"
    # --allow-all-tools runs fully non-interactively (the CI job is the sandbox).
    copilot -p "${preamble}${prompt}" \
      --allow-all-tools \
      "${model_args[@]}"
    ;;

  *)
    echo "unknown agent: $AGENT (expected 'claude' or 'copilot')" >&2
    exit 2
    ;;
esac

# ---- verify review output ----------------------------------------------------
if [[ "$mode" == "review" ]]; then
  if [[ ! -s "$REPORT_FILE" ]]; then
    echo "error: the review agent did not write a report to $REPORT_FILE" >&2
    exit 1
  fi
  echo "report-file=$REPORT_FILE" >> "$GITHUB_OUTPUT"
fi
