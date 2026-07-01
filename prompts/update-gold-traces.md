You are running **non-interactively** inside a GitHub Actions CI job. There is no
human to answer questions — make reasonable decisions from the project itself and
proceed. Do not stop to ask.

Your task: use the **appmap-gold-traces** skill to create or update this project's
gold-trace behavioral baseline.

Context:
- Current working directory is the project directory the baseline belongs to.
- Gold-traces directory (the engine's `--dir`): `${GOLD_TRACES_DIR}`

Do this:

1. **Determine the mode.**
   - If `${GOLD_TRACES_DIR}` does not exist, **BOOTSTRAP** it: seed from the skill's
     template, then figure out **from the project itself** how to record its tests
     (test runner, invocation, AppMap recorder integration, any env flag) — inspect
     `CLAUDE.md`, `package.json`/`Makefile`/`pytest.ini`/`Gemfile`/CI workflows, etc.
     Curate an initial set of gold-trace entries covering the release-critical
     subsystems, then seed the baseline with `update --record`.
   - Otherwise **MAINTAIN**: review traceable change since the baseline was last
     blessed, enhance the manifest for new/changed subsystems, re-record, and bless
     the drift with `update --record`.

2. **Bless all real drift.** This is CI with no human confirming each trace, so bless
   every genuine behavioral change (fix trace-hygiene noise — a trace that drifts with
   no code change is nondeterministic; seed it, don't bless the noise). The subsequent
   **appmap-review** step will surface any drift that looks like a regression for a
   human to act on.

3. **Keep the baseline trustworthy** per the skill: traces lean and deterministic,
   `.appmap/` gitignored, baselines marked `binary` in `.gitattributes`.

4. You **may** also improve interpretability while you are here: apply AppMap
   **labels** (via appmap-label) to security-relevant functions the traces exercise,
   and add a gold test where a release-critical path has no coverage. The CI action
   will commit **everything you change** — baselines, spec, labels, and new tests — so
   nothing you do is lost.

**Do not run `git commit` or `git push`.** The CI action commits and pushes all your
changes after you finish. Just leave the working tree with your changes in place.
