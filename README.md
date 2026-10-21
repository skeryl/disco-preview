# disco-preview

A GitHub Action that deploys a built directory to a [Disco](https://disco.cloud) server as a
per-PR preview, then removes it when the PR closes.

Disco has no preview-environment primitive: a project tracks one branch, and nothing in the
daemon knows about pull requests. It does have the pieces to build one, and they are fast.
A static deploy never touches Docker or Swarm; it copies files into a per-deployment directory
and PATCHes Caddy's admin API to point a `file_server` root at it. That is an atomic swap in a
running Caddy, which is why the server-side part of a static deploy lands in under a second.

This action is the glue: create a project per PR, send the build, read back the URL, comment it,
and reap it afterwards.

## Usage

```yaml
name: CI
on:
  pull_request:
    types: [opened, synchronize, reopened, closed]

jobs:
  preview:
    if: github.event.action != 'closed'
    runs-on: ubuntu-latest
    # Disco numbers deployments on arrival and runs them in that order, so
    # whichever run deploys last wins whatever commit it carries. Only let the
    # newest run finish. See "Two pushes in quick succession" below.
    concurrency:
      group: disco-preview-${{ github.event.number }}
      cancel-in-progress: true
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
    if: github.event.action == 'closed'
    runs-on: ubuntu-latest
    # Same group, so closing a PR cancels a deploy still in flight rather than
    # racing it and leaving the project behind.
    concurrency:
      group: disco-preview-${{ github.event.number }}
      cancel-in-progress: true
    steps:
      - uses: skeryl/disco-preview@v1
        with:
          mode: teardown
          project: site-pr-${{ github.event.number }}
          disco-host: ${{ secrets.DISCO_HOST }}
          disco-api-key: ${{ secrets.DISCO_API_KEY }}
```

The sweep wants its own workflow, so a scheduled run does not have to be excluded from every job
in the one above:

```yaml
name: Preview Sweep
on:
  schedule:
    - cron: '0 4 * * *'
  workflow_dispatch:

jobs:
  sweep:
    runs-on: ubuntu-latest
    # It reads PR state to decide what to delete, and declines to delete
    # anything it cannot read. Without this it can delete nothing at all.
    permissions:
      pull-requests: read
    steps:
      - uses: skeryl/disco-preview@v1
        with:
          mode: sweep
          prefix: site-pr-
          disco-host: ${{ secrets.DISCO_HOST }}
          disco-api-key: ${{ secrets.DISCO_API_KEY }}
```

`workflow_dispatch` only appears once the workflow is on your default branch.

## Inputs

GitHub does not enforce `required` on a composite action's inputs — an unset secret arrives as an
empty string, not an error — and most of these depend on `mode` anyway. So only `disco-host` and
`disco-api-key` are declared required, and the action checks the rest itself at runtime. The
column below is what each one is actually needed for.

| name | needed for | default | notes |
| --- | --- | --- | --- |
| `mode` | all | `deploy` | `deploy`, `teardown` or `sweep` |
| `disco-host` | all | | Disco server host |
| `disco-api-key` | all | | Disco API key, from secrets |
| `project` | deploy, teardown | | Project name, e.g. `site-pr-42` |
| `dir` | deploy | | Directory of built files |
| `prefix` | sweep | | Prefix marking preview projects, e.g. `site-pr-` |
| `skip-if-superseded` | optional | `true` | Skip when the PR head has moved past the commit this run built |
| `clean-urls` | optional | `true` | Give each page a directory index so `/about` resolves |
| `exclude` | optional | | Newline-separated `.dockerignore` patterns to keep out of the upload |
| `public-path` | optional | `public` | Subdirectory the build is staged at inside the upload. Cannot be `.` |
| `disco-name` | optional | `ci` | Name for the server in the generated CLI config |
| `comment` | optional | `true` | Post or update a PR comment with the URL |
| `github-token` | optional | `github.token` | Comments on the PR, and reads PR state for `sweep` and `skip-if-superseded` |

Outputs are `url` and `project`. `url` is empty when the deploy was skipped as superseded, or when
the project has no domain.

## Prerequisites

**A wildcard DNS record on the server host.** A project created without `--domain` gets
`NAME.<server host>`, but only when the host has a wildcard record, or the server uses a
Disco-provided `ondis.co` host, where it comes free. Without it the deploy still succeeds, the
action warns, and there is no URL to comment. One `*.disco.example.com` A record covers every
future preview.

**An API key**, from `disco apikeys:add` or the dashboard. Store it and the host as repository
secrets.

### A note on certificates at volume

Caddy issues a certificate per hostname as each is first reached, so every new PR number means a
new certificate. Let's Encrypt allows 50 per registered domain per week, and `ondis.co` is not on
the [Public Suffix List](https://publicsuffix.org/list/), so for rate-limiting purposes the
registered domain is `ondis.co` itself and every Disco server's hostnames share one allowance. A
handful of PRs a week is nothing; a busy repository could exhaust it for other people too.

A custom domain with a wildcard certificate avoids this entirely: one `*.preview.example.com`
certificate covers every preview you will ever open, issued once via a DNS-01 challenge. Nothing
in the daemon removes certificates when a project is deleted, so a reopened PR reuses the cached
one rather than asking for another.

## Lifecycle

Opening, pushing, closing and reopening are all handled. Closing removes the project; reopening
builds it back from nothing, with deployment numbering starting over, and updates the existing PR
comment in place rather than adding a second one.

Teardown on close is best effort: a cancelled run, an Actions outage, or a PR closed while CI was
red all leave a project behind. The sweep is the backstop, and is what makes orphans impossible to
accumulate rather than merely unlikely.

## How the sweep decides

It asks about each PR individually rather than diffing names against one list of open PRs. A list
that comes back empty because the API hiccuped is indistinguishable from every PR being closed,
and this job deletes things unattended, so it deletes only on a definite `CLOSED` or `MERGED`.

A project it cannot resolve to a PR at all, which a prefix shared across repositories would
produce, is left alone and warned about on every run. Telling "this PR does not exist" apart from
"GitHub did not answer" means matching on error text, and being wrong there deletes something,
where being wrong the other way leaves a project for a human to remove.

Note the asymmetry with deploying. There, a check that cannot be answered means go ahead, because
the worst case is a stale preview the next push corrects. Here it means do nothing, because a
wrong deletion is not correctable at all.

## Two pushes in quick succession

Disco numbers deployments when they arrive and the queue runs them in that order, so **whichever
run calls `disco deploy` last wins, regardless of which commit it carries.** Two pushes close
together can finish out of order, and the preview is then left showing the older commit while the
PR has moved on.

The concurrency group in the usage example above is the actual fix, and it has to live in your
workflow because an action cannot set concurrency for the job that uses it.

`skip-if-superseded` is belt and braces for that: before deploying, the action compares the PR's
current head against the commit this run built and steps aside when they differ. It helps when
concurrency is not configured, and it stops a manual re-run of an old job from republishing a
stale preview.

## Keeping previews small

Nothing in Disco prunes superseded static deployments. `remove_project_static_deployments_if_any`
is called only when a project is deleted, so every push leaves another full copy of the build on
the server until the PR closes. Container projects do not have this problem: the hourly
`remove_unused_images` reaps every image that is not the project's current deployment. The
`DELETE /api/projects/{name}/deployments/{n}` endpoint only cancels deployments that are still
in flight, so a client cannot reclaim the space either.

`exclude` exists for that, but be careful with it: **an excluded file 404s in the preview.**
Nothing falls back to production. Excluding `**/*.mp4` means a PR that adds or changes a video
cannot show it, and every existing page that embeds one renders broken. That is usually the wrong
trade for a site whose previews exist to review visual changes.

Good candidates are files nothing ever requests. Precompressed `.br`/`.gz` sidecars qualify:
Disco's `serve_static_site` sets a bare `file_server` with no `precompressed` key, and the route
chain compresses with gzip/zstd on the fly, so the sidecars are never read.

```yaml
  exclude: |
    **/*.br
    **/*.gz
```

Patterns need `**/` to reach nested files. `.dockerignore` matches from the root of the
directory, so a bare `*.gz` matches only `./foo.gz` and silently skips
`_app/immutable/assets/foo.js.gz`. Nothing errors; the upload is just as large as before. The
action warns when a pattern starts with `*.` for this reason.

## Why the build is staged one level down

`deploy --dir` needs a `disco.json` at the root of what it uploads, and the build cannot sit
beside it. The daemon resolves `publicPath` and then checks it:

```python
path = os.path.abspath(f"{project_path(project_name)}/{public_path}")
if not path.startswith(f"{project_path(project_name)}/"):
    raise Exception("publicPath must be inside project folder")
```

`abspath` normalises the trailing `/.` away, so `publicPath: "."` resolves to exactly the project
path and fails a check that insists on a trailing slash. No value can name the upload root. The
action therefore hardlinks the build into `public/` inside a staging directory and writes
`disco.json` above it, which costs no extra disk.

If you supply your own `disco.json` in `dir`, the action takes `publicPath` from your file instead
of generating one. Either way the upload is assembled in a staging directory under `RUNNER_TEMP`
and **your build directory is never written to**, since a self-hosted runner reuses its workspace
and an appended `.dockerignore` would compound on every run.

## Clean URLs

Caddy's `file_server` serves what is on disk and nothing more. GitHub Pages, Netlify and Vercel
all quietly try a `.html` extension, so `/about` finds `about.html`; Caddy returns 404. A static
export that emits `about.html`, `journal.html` and `journal/nyc-subway.html` therefore 404s on
every route but `/`.

With `clean-urls` left on, the action hardlinks each page to `<name>/index.html` inside the
staging copy, which `file_server` does serve for a directory. A page whose directory already
exists, like `journal.html` beside `journal/`, gets its index placed inside. Caddy then redirects
`/about` to `/about/` with a 308, which browsers follow transparently. Turn it off with
`clean-urls: false` if your output is already laid out this way.

## Deployment failures

`disco deploy` streams the server's output and exits 0 regardless of what it says, so a
deployment that failed and rolled back still looks like a success to CI. The action reads the
status back from `deploy:list` and fails unless it is `COMPLETE`, comparing against the highest
deployment number from before the deploy so an older run's result cannot be mistaken for this
one's.

`projects:remove` behaves the same way, downgrading API failures to a warning and exiting 0, so
teardown and sweep confirm by listing rather than trusting the exit code.

## Previews on pull requests from forks

Secrets are not available to `pull_request` runs from forks, so `disco-api-key` arrives empty and
the action fails with a message saying so. This is a GitHub constraint, not a Disco one, and it
applies equally to the Netlify and Vercel preview actions.

If you need fork previews, use the `workflow_run` pattern: one workflow builds the PR and uploads
an artifact, a second runs on `workflow_run` with access to secrets and deploys it. Do not reach
for `pull_request_target` to solve this. It runs the base branch's workflow with secrets
available, and checking out the PR's code under it hands a fork write access to your server.

This path is documented but not implemented or tested here.

## Tests

`npm install && npm test` runs every step script against stub `disco` and `gh` binaries, so no
server is needed. The suite is the record of what went wrong on the way here: each case is a thing
that once looked like success and was not.

The runners use bash 5 and macOS ships bash 3.2, which disagree on `set -u` for things like
`${unset:0:7}`. The harness says when it is running under the older one; trust CI over a local
green.

## License

MIT
