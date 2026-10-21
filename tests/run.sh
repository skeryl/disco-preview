#!/usr/bin/env bash
# Runs each step script from action.yml against stub disco/gh binaries.
# Usage: tests/run.sh   (needs node, jq, and js-yaml resolvable)
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
PASS=0; FAIL=0

extract() { # extract <step name> -> script on stdout
  node -e '
    const fs=require("fs");
    const yaml=require(process.env.JS_YAML || "js-yaml");
    const d=yaml.load(fs.readFileSync("action.yml","utf8"));
    const s=d.runs.steps.find(s=>s.name===process.argv[1]);
    if(!s){console.error("no step: "+process.argv[1]);process.exit(1);}
    process.stdout.write(s.run);
  ' "$1"
}

setup() { # fresh sandbox; echoes its path
  local d; d="$(mktemp -d)"
  mkdir -p "$d/bin" "$d/build"
  cp tests/stub-disco "$d/bin/disco"; cp tests/stub-gh "$d/bin/gh"
  : > "$d/state"; : > "$d/calls"
  echo "built" > "$d/build/index.html"
  echo "$d"
}

run_step() { # run_step <sandbox> <step name> ; env comes from caller
  local d="$1" name="$2"
  extract "$name" > "$d/step.sh"
  ( cd "$d" && PATH="$d/bin:$PATH" \
      STUB_STATE="$d/state" STUB_CALLS="$d/calls" \
      RUNNER_TEMP="$d" GITHUB_OUTPUT="$d/output" GITHUB_ENV="$d/env" \
      GITHUB_PATH="$d/path" GITHUB_SHA="abc1234" \
      bash "$d/step.sh" > "$d/stdout" 2> "$d/stderr" )
  echo $?
}

ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }

echo "deploy: fresh project"
d=$(setup)
rc=$(PROJECT=site-pr-7 DIR="$d/build" EXCLUDE="" PUBLIC_PATH="public" CLEAN_URLS=true run_step "$d" "Deploy")
check "exit 0" "$rc" "0"
grep -q "projects:add --name site-pr-7" "$d/calls" && ok "created the project" || bad "created the project"
[ -f "$d/disco-preview-upload/disco.json" ] && ok "staged a disco.json above the build" || bad "staged a disco.json above the build"
jq -e '.services.web.type=="static" and .services.web.publicPath=="public"' "$d/disco-preview-upload/disco.json" >/dev/null \
  && ok "publicPath is a subdirectory, never '.'" || bad "publicPath is a subdirectory, never '.'"
[ -f "$d/disco-preview-upload/public/index.html" ] && ok "build staged under public/" || bad "build staged under public/"
[ -f "$d/build/disco.json" ] && bad "leaves the build dir alone" || ok "leaves the build dir alone"
grep -q "url=https://site-pr-7.disco.test" "$d/output" && ok "set the url output" || bad "set the url output" "$(cat "$d/output")"

echo "deploy: clean urls"
d=$(setup)
mkdir -p "$d/build/journal"
echo "about" > "$d/build/about.html"
echo "journal" > "$d/build/journal.html"
echo "entry" > "$d/build/journal/nyc-subway.html"
rc=$(PROJECT=site-pr-7 DIR="$d/build" EXCLUDE="" PUBLIC_PATH="public" CLEAN_URLS=true run_step "$d" "Deploy")
check "exit 0" "$rc" "0"
u="$d/disco-preview-upload/public"
[ -f "$u/about/index.html" ] && ok "/about resolves" || bad "/about resolves"
[ -f "$u/journal/index.html" ] && ok "/journal indexes an existing directory" || bad "/journal indexes an existing directory"
[ -f "$u/journal/nyc-subway/index.html" ] && ok "nested entries resolve" || bad "nested entries resolve"
[ -f "$u/index.html" ] && ok "root index untouched" || bad "root index untouched"
[ -d "$d/build/about" ] && bad "caller build dir untouched" || ok "caller build dir untouched"
grep -q "entry" "$u/journal/nyc-subway/index.html" && ok "content preserved" || bad "content preserved"

echo "deploy: clean urls can be turned off"
d=$(setup); echo "about" > "$d/build/about.html"
rc=$(PROJECT=site-pr-7 DIR="$d/build" EXCLUDE="" PUBLIC_PATH="public" CLEAN_URLS=false run_step "$d" "Deploy")
[ -f "$d/disco-preview-upload/public/about/index.html" ] && bad "respects clean-urls false" || ok "respects clean-urls false"

echo "deploy: project already exists (a second push)"
d=$(setup); echo "site-pr-7" > "$d/state"
rc=$(PROJECT=site-pr-7 DIR="$d/build" EXCLUDE="" PUBLIC_PATH="public" CLEAN_URLS=true run_step "$d" "Deploy")
check "exit 0" "$rc" "0"
grep -q "projects:add" "$d/calls" && bad "skips create when it exists" || ok "skips create when it exists"

echo "deploy: exclude patterns"
d=$(setup)
rc=$(PROJECT=site-pr-7 DIR="$d/build" EXCLUDE=$'*.mp4\n*.webm' PUBLIC_PATH="public" CLEAN_URLS=true run_step "$d" "Deploy")
check "exit 0" "$rc" "0"
grep -q '^\*\.mp4$' "$d/disco-preview-upload/.dockerignore" && ok "wrote exclude patterns" || bad "wrote exclude patterns" "$(cat "$d/disco-preview-upload/.dockerignore" 2>&1)"

echo "deploy: warns about non-recursive exclude patterns"
d=$(setup)
rc=$(PROJECT=site-pr-7 DIR="$d/build" EXCLUDE=$'*.mp4' PUBLIC_PATH="public" CLEAN_URLS=true run_step "$d" "Deploy")
check "exit 0" "$rc" "0"
grep -q "::warning::exclude pattern" "$d/stdout" && ok "warns on a root-only pattern" || bad "warns on a root-only pattern"
d=$(setup)
rc=$(PROJECT=site-pr-7 DIR="$d/build" EXCLUDE=$'**/*.mp4' PUBLIC_PATH="public" CLEAN_URLS=true run_step "$d" "Deploy")
grep -q "::warning::exclude pattern" "$d/stdout" && bad "quiet on a recursive pattern" || ok "quiet on a recursive pattern"

echo "deploy: a caller-supplied disco.json"
d=$(setup)
mkdir -p "$d/build/public"; mv "$d/build/index.html" "$d/build/public/index.html"
echo "about" > "$d/build/public/about.html"
echo '{"version":"1.0","services":{"web":{"type":"static","publicPath":"public"}}}' > "$d/build/disco.json"
rc=$(PROJECT=site-pr-7 DIR="$d/build" EXCLUDE=$'**/*.mp4' PUBLIC_PATH="ignored" CLEAN_URLS=true run_step "$d" "Deploy")
check "exit 0" "$rc" "0"
jq -e '.services.web.publicPath=="public"' "$d/disco-preview-upload/disco.json" >/dev/null && ok "kept their publicPath" || bad "kept their publicPath"
[ -f "$d/build/.dockerignore" ] && bad "never writes .dockerignore into their dir" || ok "never writes .dockerignore into their dir"
[ -f "$d/disco-preview-upload/.dockerignore" ] && ok "excludes land in staging" || bad "excludes land in staging"
[ -f "$d/disco-preview-upload/public/about/index.html" ] && ok "clean urls still applied" || bad "clean urls still applied"
[ -d "$d/build/public/about" ] && bad "their build left untouched" || ok "their build left untouched"

echo "deploy: a failed server-side deployment is not reported as success"
d=$(setup)
rc=$(STUB_DEPLOY_STATUS=FAILED PROJECT=site-pr-7 DIR="$d/build" EXCLUDE="" PUBLIC_PATH="public" CLEAN_URLS=true run_step "$d" "Deploy")
check "fails despite the CLI exiting 0" "$rc" "1"
grep -q "ended as FAILED" "$d/stderr" && ok "names the status" || bad "names the status" "$(cat "$d/stderr")"

echo "deploy: a run that creates no new deployment is not success"
d=$(setup)
rc=$(STUB_NO_NEW_DEPLOYMENT=1 PROJECT=site-pr-7 DIR="$d/build" EXCLUDE="" PUBLIC_PATH="public" CLEAN_URLS=true run_step "$d" "Deploy")
check "fails on a stale deployment list" "$rc" "1"
grep -q "no deployment newer than" "$d/stderr" && ok "says nothing new was created" || bad "says nothing new was created" "$(cat "$d/stderr")"

echo "deploy: public-path of '.' is refused up front"
d=$(setup)
rc=$(PROJECT=site-pr-7 DIR="$d/build" EXCLUDE="" PUBLIC_PATH="." CLEAN_URLS=true run_step "$d" "Deploy")
check "rejected" "$rc" "1"
grep -q "daemon rejects the upload root" "$d/stderr" && ok "explains why" || bad "explains why"

echo "deploy: no domain on the server"
d=$(setup)
rc=$(STUB_NO_DOMAIN=1 PROJECT=site-pr-7 DIR="$d/build" EXCLUDE="" PUBLIC_PATH="public" CLEAN_URLS=true run_step "$d" "Deploy")
check "exits 0 anyway" "$rc" "0"
grep -q "::warning::" "$d/stdout" && ok "warns about wildcard DNS" || bad "warns about wildcard DNS"

echo "deploy: missing inputs"
d=$(setup)
rc=$(PROJECT="" DIR="$d/build" EXCLUDE="" PUBLIC_PATH="public" CLEAN_URLS=true run_step "$d" "Deploy")
check "fails without project" "$rc" "1"
d=$(setup)
rc=$(PROJECT=site-pr-7 DIR="$d/nope" EXCLUDE="" PUBLIC_PATH="public" CLEAN_URLS=true run_step "$d" "Deploy")
check "fails on a missing dir" "$rc" "1"

echo "teardown"
d=$(setup); echo "site-pr-7" > "$d/state"
rc=$(PROJECT=site-pr-7 run_step "$d" "Teardown")
check "exit 0" "$rc" "0"
grep -q -- "--no-input" "$d/calls" && ok "passes --no-input" || bad "passes --no-input"
grep -qx "site-pr-7" "$d/state" && bad "project is gone" || ok "project is gone"

echo "teardown: already gone"
d=$(setup)
rc=$(PROJECT=site-pr-7 run_step "$d" "Teardown")
check "exit 0" "$rc" "0"
grep -q "projects:remove" "$d/calls" && bad "no pointless remove" || ok "no pointless remove"

echo "teardown: server failure is caught despite exit 0"
d=$(setup); echo "site-pr-7" > "$d/state"
rc=$(STUB_REMOVE_FAILS=1 PROJECT=site-pr-7 run_step "$d" "Teardown")
check "surfaces the failure" "$rc" "1"

echo "unreachable server is not mistaken for an absent project"
d=$(setup); echo "site-pr-7" > "$d/state"
rc=$(STUB_UNREACHABLE=1 PROJECT=site-pr-7 DIR="$d/build" EXCLUDE="" PUBLIC_PATH="public" CLEAN_URLS=true run_step "$d" "Deploy")
check "deploy fails loudly" "$rc" "1"
grep -q "projects:add" "$d/calls" && bad "does not blind-create" || ok "does not blind-create"
d=$(setup); echo "site-pr-7" > "$d/state"
rc=$(STUB_UNREACHABLE=1 PROJECT=site-pr-7 run_step "$d" "Teardown")
check "teardown fails loudly" "$rc" "1"
grep -q "already gone" "$d/stdout" && bad "does not claim it was gone" || ok "does not claim it was gone"

echo "missing credentials"
d=$(setup)
rc=$(DISCO_HOST="" DISCO_API_KEY="k" DISCO_NAME=ci run_step "$d" "Write the CLI config")
check "rejects an empty host" "$rc" "1"
grep -q "disco-host is empty" "$d/stderr" && ok "names the missing input" || bad "names the missing input" "$(cat "$d/stderr")"
d=$(setup)
rc=$(DISCO_HOST="h" DISCO_API_KEY="k" DISCO_NAME=ci run_step "$d" "Write the CLI config")
check "accepts both set" "$rc" "0"
jq -e '.discos.ci.host=="h"' "$d/disco-config.json" >/dev/null && ok "writes the config" || bad "writes the config"

echo "sweep"
d=$(setup); printf 'site-pr-1\nsite-pr-2\nsite-pr-10\nsite-prod\nother\n' > "$d/state"
rc=$(STUB_OPEN_PRS="2" PREFIX=site-pr- REPO=o/r run_step "$d" "Sweep")
check "exit 0" "$rc" "0"
grep -qx "site-pr-2" "$d/state" && ok "keeps the open PR" || bad "keeps the open PR"
grep -qx "site-pr-1" "$d/state" && bad "reaps closed PR 1" || ok "reaps closed PR 1"
grep -qx "site-pr-10" "$d/state" && bad "reaps closed PR 10" || ok "reaps closed PR 10"
grep -qx "site-prod" "$d/state" && ok "leaves non-numeric names alone" || bad "leaves non-numeric names alone"
grep -qx "other"     "$d/state" && ok "leaves unprefixed names alone" || bad "leaves unprefixed names alone"

echo "sweep: closing PR 1 must not take PR 10 with it"
d=$(setup); printf 'site-pr-1\nsite-pr-10\n' > "$d/state"
rc=$(STUB_OPEN_PRS="10" PREFIX=site-pr- REPO=o/r run_step "$d" "Sweep")
grep -qx "site-pr-10" "$d/state" && ok "no prefix-collision deletion" || bad "no prefix-collision deletion"

echo "sweep: an unanswerable PR check must never delete"
d=$(setup); printf 'site-pr-1\nsite-pr-2\n' > "$d/state"
rc=$(STUB_GH_VIEW_FAILS=1 STUB_OPEN_PRS="" PREFIX=site-pr- REPO=o/r run_step "$d" "Sweep")
check "exit 0" "$rc" "0"
[ "$(wc -l < "$d/state" | tr -d ' ')" = "2" ] && ok "kept both when gh could not answer" || bad "kept both when gh could not answer" "$(cat "$d/state")"
grep -q "could not check PR" "$d/stdout" && ok "warns per project" || bad "warns per project"

echo "sweep: a merged PR is reaped"
d=$(setup); printf 'site-pr-5\n' > "$d/state"
rc=$(STUB_OPEN_PRS="" STUB_CLOSED_STATE=MERGED PREFIX=site-pr- REPO=o/r run_step "$d" "Sweep")
grep -qx "site-pr-5" "$d/state" && bad "merged counts as closed" || ok "merged counts as closed"

echo "sweep: an unknown state is left alone"
d=$(setup); printf 'site-pr-5\n' > "$d/state"
rc=$(STUB_OPEN_PRS="" STUB_CLOSED_STATE=WEIRD PREFIX=site-pr- REPO=o/r run_step "$d" "Sweep")
grep -qx "site-pr-5" "$d/state" && ok "unknown state is not a delete signal" || bad "unknown state is not a delete signal"

echo "sweep: a removal that silently fails is caught"
d=$(setup); printf 'site-pr-5\n' > "$d/state"
rc=$(STUB_REMOVE_FAILS=1 STUB_OPEN_PRS="" PREFIX=site-pr- REPO=o/r run_step "$d" "Sweep")
check "fails loudly" "$rc" "1"

echo "comment: works without a checkout"
node -e '
  const yaml=require(process.env.JS_YAML||"js-yaml"),fs=require("fs");
  const d=yaml.load(fs.readFileSync("action.yml","utf8"));
  const s=d.runs.steps.find(s=>s.name==="Comment on the PR");
  process.exit(s.env && s.env.GH_REPO ? 0 : 1);
' && ok "sets GH_REPO so gh needs no .git" || bad "sets GH_REPO so gh needs no .git"

echo "comment: falls back to create when there is nothing to edit"
d=$(setup)
rc=$(GH_TOKEN=t PR=7 URL="https://site-pr-7.disco.test" PROJECT=site-pr-7 STUB_NO_PRIOR_COMMENT=1 run_step "$d" "Comment on the PR")
check "exit 0" "$rc" "0"
[ "$(grep -c 'gh pr comment' "$d/calls")" = "2" ] && ok "tried edit, then created" || bad "tried edit, then created" "$(cat "$d/calls")"

echo
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
