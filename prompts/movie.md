You are running **non-interactively** inside a GitHub Actions CI job. There is no
human to answer questions; proceed autonomously.

Your task: use the **appmap-pr-movie** skill to make the summary of this pull
request: a narrated video, a podcast clip and the written script.

Arguments:
- baseline revision: `${BASE_REVISION}`
- head revision: `${HEAD_REVISION}`
- pull request number: `${PR_NUMBER}`
- output folder: `${MOVIE_DIR}`
- Showcase Studio checkout: `${SHOWCASE_STUDIO}` (no MCP here; use its command
  line: `npm --prefix "${SHOWCASE_STUDIO}" run dev -- --library <dir> --export <kind>:<id>`)
- how to start the app and sign in, from the workflow: `${APP_NOTES}`

Notes:
- The voice uses the AWS profile already named in the library's
  `showcase_settings.yaml` or `AWS_PROFILE`. If none is set, make the script and
  the video without a voice, and record why under `"missing"` in `movie.json`.
- Do not post, comment, commit or push anything. The action publishes the folder.

Follow the skill's **Output contract** exactly. Writing `movie.json` with a
sentence is required even when other forms are missing.
