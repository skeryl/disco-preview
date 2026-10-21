# disco-preview

A GitHub Action that deploys a built directory to a [Disco](https://disco.cloud) server as a
per-PR preview, then removes it when the PR closes.

Disco has no preview-environment primitive: a project tracks one branch, and nothing in the
daemon knows about pull requests. It does have the pieces to build one, and they are fast.
A static deploy never touches Docker or Swarm; it copies files into a per-deployment directory
and PATCHes Caddy's admin API to point a `file_server` root at it. That is an atomic swap in a
running Caddy, which is why static deploys land in well under a second.

This action is the glue: create a project per PR, send the build, read back the URL, comment it,
and reap it afterwards.

## Usage

```yaml
name: CI
on:
  pull_request:
    types: [opened, synchronize, reopened, closed]
  schedule:
    - cron: '0 4 * * *'

jobs:
  preview:
    if: github.event_name == 'pull_request' && github.event.action != 'closed'
    runs-on: ubuntu-latest
    permissions:
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
      # ... your own build, producing a directory ...
      - uses: skeryl/disco-preview@v1
        with:
          project: site-pr-${{ github.event.number }}
          dir: build
          disco-host: ${{ secrets.DISCO_HOST }}
          disco-api-key: ${{ secrets.DISCO_API_KEY }}

  teardown:
    if: github.event_name == 'pull_request' && github.event.action == 'closed'
    runs-on: ubuntu-latest
    steps:
      - uses: skeryl/disco-preview@v1
        with:
          mode: teardown
          project: site-pr-${{ github.event.number }}
          disco-host: ${{ secrets.DISCO_HOST }}
          disco-api-key: ${{ secrets.DISCO_API_KEY }}

  sweep:
    if: github.event_name == 'schedule'
    runs-on: ubuntu-latest
    steps:
      - uses: skeryl/disco-preview@v1
        with:
          mode: sweep
          prefix: site-pr-
          disco-host: ${{ secrets.DISCO_HOST }}
          disco-api-key: ${{ secrets.DISCO_API_KEY }}
```

## Inputs

| name | required | default | notes |
| --- | --- | --- | --- |
| `mode` | yes | `deploy` | `deploy`, `teardown` or `sweep` |
| `project` | deploy, teardown | | Project name, e.g. `site-pr-42` |
| `prefix` | sweep | | Prefix marking preview projects, e.g. `site-pr-` |
| `dir` | deploy | | Directory of built files |
| `exclude` | no | | Newline-separated `.dockerignore` patterns to keep out of the upload |
| `public-path` | no | `.` | `publicPath` for a generated `disco.json` |
| `disco-host` | yes | | Disco server host |
| `disco-api-key` | yes | | Disco API key, from secrets |
| `disco-name` | no | `ci` | Name for the server in the generated CLI config |
| `comment` | no | `true` | Post/update a PR comment with the URL |
| `github-token` | no | `github.token` | Used to comment and to list open PRs |

Outputs: `url` and `project`.

## Prerequisites

**A wildcard DNS record on the server host.** A project created without `--domain` gets
`NAME.<server host>`, but only when the host has a wildcard record (or the server uses a
Disco-provided `ondis.co` host). Without it the deploy still succeeds, the action warns, and
there is no URL to comment. One `*.disco.example.com` A record covers every future preview;
Caddy issues certificates per hostname as they are first reached.

**An API key**, from `disco apikeys:add` or the dashboard. Store it and the host as repository
secrets.

## Keeping previews small

Nothing in Disco prunes superseded static deployments. `remove_project_static_deployments_if_any`
is called only when a project is deleted, so every push to a PR leaves another full copy of the
build on disk until the PR closes. Container projects do not have this problem: the hourly
`remove_unused_images` reaps every image that is not the project's current deployment.

Until that asymmetry is fixed upstream, keep large immutable assets out of previews:

```yaml
  exclude: |
    **/*.mp4
    **/*.webm
    **/*.mov
```

**Patterns need `**/` to reach nested files.** `.dockerignore` matches from the root of the
directory, so a bare `*.mp4` matches only `./foo.mp4` and silently skips
`_app/immutable/assets/foo.mp4`. Nothing errors; the upload is just as large as before. The
action warns when a pattern starts with `*.` for this reason.

Content-hashed media is identical on every push and identical to production, so excluding it can
turn a 98MB upload into about 2MB without changing anything a reviewer looks at. A PR that
actually changes a video is the exception; re-include those paths with a `!` line.

## Previews on pull requests from forks

Secrets are not available to `pull_request` runs from forks, so `disco-api-key` arrives empty and
the deploy fails. This is a GitHub constraint, not a Disco one, and it applies equally to the
Netlify and Vercel preview actions.

If you need fork previews, use the `workflow_run` pattern: one workflow builds the PR and uploads
an artifact, a second runs on `workflow_run` with access to secrets and deploys it. Do not reach
for `pull_request_target` to solve this. It runs the base branch's workflow with secrets
available, and checking out the PR's code under it hands a fork write access to your server.

## License

MIT
