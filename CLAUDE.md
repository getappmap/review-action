# review-action

Composite GitHub Action that maintains a project's AppMap gold-trace baseline and
posts a behavioral review as a sticky PR comment. The work is done by an AI agent
(Claude Code or Copilot CLI) running the `getappmap/skills` skills; the shell
scripts in `scripts/` are the orchestration layer, tested offline by `test/run.sh`.

## Versioning and releases

Consumers pin `getappmap/review-action@v1`. The release convention (the standard
GitHub Actions scheme, per actions/toolkit):

- **`v1` is a floating major tag.** CI owns it: the `move-major-tag` job in
  `.github/workflows/test.yml` force-moves `v1` to every green push to `main`
  (PR merges included). **Never move `v1` by hand** and never assume it is
  stable history — it is rewritten on every release.
- **Immutable `vX.Y.Z` tags** are cut manually for milestones (annotated tag +
  optionally a GitHub Release for Marketplace). Never force-move or delete these;
  SHA-pinning consumers rely on them. Adding an optional input with a compatible
  default is a minor bump; fixes are patch bumps.
- **Breaking changes get a new major.** Breaking means: removing/renaming an
  input or output, changing an input default in a behavior-altering way, or
  raising runner requirements. Procedure: tag the last compatible commit's line
  closed (leave `v1` pointing there forever), bump `MAJOR_TAG` to `v2` in
  `.github/workflows/test.yml`, and tag `v2.0.0`.

Because CI moves the major tag on merge, a push to `main` **is** a release —
don't merge/push anything to `main` that isn't ready for consumers.
