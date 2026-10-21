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
rc=$(PROJECT=site-pr-7 DIR="$d/build" EXCLUDE="" PUBLIC_PATH="." run_step "$d" "Deploy")
check "exit 0" "$rc" "0"
grep -q "projects:add --name site-pr-7" "$d/calls" && ok "created the project" || bad "created the project"
[ -f "$d/build/disco.json" ] && ok "wrote disco.json" || bad "wrote disco.json"
jq -e '.services.web.type=="static" and .services.web.publicPath=="."' "$d/build/disco.json" >/dev/null \
  && ok "disco.json is a static service" || bad "disco.json is a static service"
grep -q "url=https://site-pr-7.disco.test" "$d/output" && ok "set the url output" || bad "set the url output" "$(cat "$d/output")"

echo "deploy: project already exists (a second push)"
d=$(setup); echo "site-pr-7" > "$d/state"
rc=$(PROJECT=site-pr-7 DIR="$d/build" EXCLUDE="" PUBLIC_PATH="." run_step "$d" "Deploy")
check "exit 0" "$rc" "0"
grep -q "projects:add" "$d/calls" && bad "skips create when it exists" || ok "skips create when it exists"

echo "deploy: exclude patterns"
d=$(setup)
rc=$(PROJECT=site-pr-7 DIR="$d/build" EXCLUDE=$'*.mp4\n*.webm' PUBLIC_PATH="." run_step "$d" "Deploy")
check "exit 0" "$rc" "0"
grep -q '^\*\.mp4$' "$d/build/.dockerignore" && ok "wrote exclude patterns" || bad "wrote exclude patterns" "$(cat "$d/build/.dockerignore" 2>&1)"

echo "deploy: warns about non-recursive exclude patterns"
d=$(setup)
rc=$(PROJECT=site-pr-7 DIR="$d/build" EXCLUDE=$'*.mp4' PUBLIC_PATH="." run_step "$d" "Deploy")
check "exit 0" "$rc" "0"
grep -q "::warning::exclude pattern" "$d/stdout" && ok "warns on a root-only pattern" || bad "warns on a root-only pattern"
d=$(setup)
rc=$(PROJECT=site-pr-7 DIR="$d/build" EXCLUDE=$'**/*.mp4' PUBLIC_PATH="." run_step "$d" "Deploy")
grep -q "::warning::exclude pattern" "$d/stdout" && bad "quiet on a recursive pattern" || ok "quiet on a recursive pattern"

echo "deploy: respects an existing disco.json"
d=$(setup); echo '{"version":"1.0","services":{"web":{"type":"static","publicPath":"public"}}}' > "$d/build/disco.json"
rc=$(PROJECT=site-pr-7 DIR="$d/build" EXCLUDE="" PUBLIC_PATH="." run_step "$d" "Deploy")
jq -e '.services.web.publicPath=="public"' "$d/build/disco.json" >/dev/null && ok "did not clobber it" || bad "did not clobber it"

echo "deploy: no domain on the server"
d=$(setup)
rc=$(STUB_NO_DOMAIN=1 PROJECT=site-pr-7 DIR="$d/build" EXCLUDE="" PUBLIC_PATH="." run_step "$d" "Deploy")
check "exits 0 anyway" "$rc" "0"
grep -q "::warning::" "$d/stdout" && ok "warns about wildcard DNS" || bad "warns about wildcard DNS"

echo "deploy: missing inputs"
d=$(setup)
rc=$(PROJECT="" DIR="$d/build" EXCLUDE="" PUBLIC_PATH="." run_step "$d" "Deploy")
check "fails without project" "$rc" "1"
d=$(setup)
rc=$(PROJECT=site-pr-7 DIR="$d/nope" EXCLUDE="" PUBLIC_PATH="." run_step "$d" "Deploy")
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
rc=$(STUB_UNREACHABLE=1 PROJECT=site-pr-7 DIR="$d/build" EXCLUDE="" PUBLIC_PATH="." run_step "$d" "Deploy")
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

echo "comment: falls back to create when there is nothing to edit"
d=$(setup)
rc=$(GH_TOKEN=t PR=7 URL="https://site-pr-7.disco.test" PROJECT=site-pr-7 STUB_NO_PRIOR_COMMENT=1 run_step "$d" "Comment on the PR")
check "exit 0" "$rc" "0"
[ "$(grep -c 'gh pr comment' "$d/calls")" = "2" ] && ok "tried edit, then created" || bad "tried edit, then created" "$(cat "$d/calls")"

echo
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
