# sample-project

A tiny Node app used as a fixture for the review-action test harness.

## Testing / recording

- Run tests: `npx jest`
- Record a single test under AppMap: `npx appmap-node npx jest <test_file> -t <test_name>`
- AppMaps are written under `tmp/appmap` (see `appmap.yml`).
