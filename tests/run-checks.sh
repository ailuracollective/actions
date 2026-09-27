#!/usr/bin/env bash
# Local harness for the pull-request-validation checks.
#
# Every check runs against the `gh` and `jq` stubs in tests/stubs/, so the whole gate is exercised
# without a network, a token, or a GitHub runner. The jq stub is deliberately not validated against
# real jq: if it ever disagrees with the runner, that shows up as a failing test, not a silent pass.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
STUBS="$ROOT/tests/stubs"
chmod +x "$STUBS/gh" "$STUBS/jq" "$STUBS/curl" 2>/dev/null
export PATH="$STUBS:$PATH"

passed=0
failed=0

group() { printf '\n%s\n' "$1"; }

ok() {
  passed=$((passed + 1))
  printf '  ok    %s\n' "$1"
}

bad() {
  failed=$((failed + 1))
  printf '  FAIL  %s\n' "$1"
  printf '          expected: %s\n' "$2"
  printf '          actual:   %s\n' "$3"
}

assert_eq() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi
}

assert_contains() { # <label> <needle> <haystack>
  case $3 in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "output containing: $2" "$(printf '%s' "$3" | head -c 400)" ;;
  esac
}

assert_not_contains() { # <label> <needle> <haystack>
  case $3 in
    *"$2"*) bad "$1" "output NOT containing: $2" "$(printf '%s' "$3" | head -c 400)" ;;
    *) ok "$1" ;;
  esac
}

setup() {
  RESULTS_DIR=$(mktemp -d)/results
  RUNNER_TEMP=$(mktemp -d)
  export RESULTS_DIR RUNNER_TEMP
  export GITHUB_STEP_SUMMARY="$RUNNER_TEMP/summary.md"
  : > "$GITHUB_STEP_SUMMARY"
  export GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_ACTION=opened
  export GH_REPO=owner/repo GH_TOKEN=stub-token
  export INPUT_TITLE_MIN=15 INPUT_TITLE_MAX=72
  export INPUT_TYPE_LABELS='feat,fix,docs,refactor,chore,style,perf,test,build,ci,revert,breaking-change'
  export INPUT_BRANCH_TYPES='feat,fix,chore,docs,style,refactor,perf,test,build,ci,revert'
  export INPUT_TEMPLATE_DIR='.github/PULL_REQUEST_TEMPLATE'
  export INPUT_DEFAULT_TEMPLATE='.github/PULL_REQUEST_TEMPLATE.md'
  export INPUT_APPROVED_LABEL='status:approved'
  export INPUT_LINKED_ISSUE_SOURCES='github'
  export INPUT_LINEAR_APPROVED_LABEL='approved'
  export INPUT_AUTO_LABEL_NAME='status:needs-review'
  export INPUT_ENABLE_AUTO_LABEL=true
  export PR_TITLE='' PR_BODY='' PR_LABELS='[]' HEAD_REF='' AUTHOR_LOGIN='' BASE_SHA=base1234
  export PR_BASE_SHA=base1234 EVENT_SHA=eventsha
  export ISSUE_NUMBER=''
  unset GH_STUB_ISSUE_EDIT GH_STUB_ISSUE_API GH_STUB_ISSUE_LABELS GH_STUB_REPO_ROOT
  unset LINEAR_API_KEY LINEAR_STUB_RESPONSE LINEAR_STUB_HTTP LINEAR_STUB_CAPTURE
}

# A canned Linear GraphQL response for the given label names.
stub_linear() { # <label...>
  local file="$RUNNER_TEMP/linear.json"
  local labels='[]'
  local first=yes
  for label in "$@"; do
    if [ "$first" = yes ]; then labels="{\"name\":\"$label\"}"; first=no
    else labels="$labels,{\"name\":\"$label\"}"; fi
  done
  [ "$first" = yes ] || labels="[$labels]"
  printf '{"data":{"issue":{"identifier":"ENG-123","state":{"name":"In Progress"},"labels":{"nodes":%s}}}}' "$labels" > "$file"
  export LINEAR_STUB_RESPONSE="$file"
}

status_of() { # <check>
  if [ -f "$RESULTS_DIR/$1.status" ]; then cat "$RESULTS_DIR/$1.status"; else printf 'none'; fi
}

run_check() { # <check> — echoes combined output, returns the script's exit code
  # Check scripts live in the directory of the action that owns them, so a check name alone is not a
  # path. Resolved by search rather than a hardcoded map, so a new action registers a check just by
  # dropping a file in its own directory.
  local name=$1 path
  path=$(find "$ROOT" -name "$name.sh" -not -path '*/.git/*' -not -path '*/.atl/*' -not -path "$ROOT/odd/*" -print -quit)
  if [ -z "$path" ]; then
    printf 'no script named %s.sh exists anywhere in the repository\n' "$name"
    return 127
  fi
  "$path" 2>&1
}

# The report is shared by every action and takes its check list from the environment, so the harness
# does the same: each action's own list, exactly as its manifest declares it.
report_for() { # <PRV_CHECKS> <PRV_LABELS> [PRV_TITLE] [PRV_NOTE]
  env RESULTS_DIR="$RESULTS_DIR" GITHUB_STEP_SUMMARY="$GITHUB_STEP_SUMMARY" \
    GITHUB_EVENT_NAME="$GITHUB_EVENT_NAME" \
    PRV_CHECKS="$1" PRV_LABELS="$2" PRV_TITLE="${3:-Validation}" PRV_NOTE="${4:-}" \
    bash "$ROOT/lib/report.sh" 2>&1
}

PRV_CHECK_LIST='linked-issue|type-label|pr-title-length|pr-title-conventional|pr-body-structure'
PRV_LABEL_LIST='Linked issue|Type label|Title length|Title is conventional|Body structure'
BRV_CHECK_LIST='branch-name'
BRV_LABEL_LIST='Branch name'

# The advisory the branch manifest passes, so the assertion covers what a consumer actually reads.
# shellcheck disable=SC2016  # backticks are literal text in the message, not a subshell
BRANCH_NOTE='This check runs on `opened` only. GitHub cannot rename a branch an open pull request points at, so `head.ref` is fixed for the life of the pull request.'

# A stubbed repository whose template directory holds a per-type template.
stub_repo() { # <type> <filename>  <body>
  local root
  root=$(mktemp -d)
  mkdir -p "$root/$INPUT_TEMPLATE_DIR"
  printf '%s\n' "$3" > "$root/$INPUT_TEMPLATE_DIR/$1.md"
  export GH_STUB_REPO_ROOT="$root"
}

DEFAULT_TEMPLATE_BODY='## Summary

Explain the change.

## Testing

Explain how it was tested.'

# ===============================================================================================
group 'branch-name'
# ===============================================================================================
setup; export HEAD_REF='janedoe/feat/parser-fallback' AUTHOR_LOGIN='JaneDoe'
out=$(run_check branch-name)
assert_eq 'accepts <author>/<type>/<description>' pass "$(status_of branch-name)"
assert_eq 'exits 0 so report.sh alone fails the job' 0 "$?"

setup; export HEAD_REF='feat/parser-fallback' AUTHOR_LOGIN='janedoe'
out=$(run_check branch-name)
assert_eq 'rejects a branch with no author segment' fail "$(status_of branch-name)"
assert_contains 'names the expected shape' 'janedoe/feat/parser-fallback' "$out"

setup; export HEAD_REF='bob/feat/parser-fallback' AUTHOR_LOGIN='janedoe'
out=$(run_check branch-name)
assert_eq 'rejects a branch owned by someone else' fail "$(status_of branch-name)"
assert_contains 'names the PR author' 'pull request author' "$out"

setup; export HEAD_REF='janedoe/breaking-change/x' AUTHOR_LOGIN='janedoe'
run_check branch-name >/dev/null
assert_eq 'breaking-change is NOT an accepted branch type' fail "$(status_of branch-name)"

setup; export HEAD_REF='janedoe/feat/x' AUTHOR_LOGIN='janedoe' GITHUB_EVENT_ACTION=synchronize
run_check branch-name >/dev/null
assert_eq 'skips on anything but opened' skip "$(status_of branch-name)"

# ===============================================================================================
group 'linked-issue'
# ===============================================================================================
setup; export PR_BODY='Closes #12'
export GH_STUB_ISSUE_LABELS='status:approved'
run_check linked-issue >/dev/null
assert_eq 'accepts a Closes #N pointing at an approved issue' pass "$(status_of linked-issue)"

setup; export PR_BODY='Fixes #12'; export GH_STUB_ISSUE_LABELS='status:approved'
run_check linked-issue >/dev/null
assert_eq 'accepts Fixes as a closing keyword' pass "$(status_of linked-issue)"

setup; export PR_BODY='Some description with no reference.'
run_check linked-issue >/dev/null
assert_eq 'rejects a body with no closing keyword' fail "$(status_of linked-issue)"

setup; export PR_BODY='Refs #12'
out=$(run_check linked-issue)
assert_eq 'rejects a bare Refs #N' fail "$(status_of linked-issue)"
assert_contains "says 'Refs' never closes" 'never closes' "$out"

setup; export PR_BODY='Closes #12'; export GH_STUB_ISSUE_LABELS='bug,status:needs-review'
run_check linked-issue >/dev/null
assert_eq 'rejects an unapproved linked issue' fail "$(status_of linked-issue)"

setup; export PR_BODY='Closes #12'; export GH_STUB_ISSUE_API=missing
run_check linked-issue >/dev/null
assert_eq 'rejects a linked issue that cannot be read' fail "$(status_of linked-issue)"

setup; export PR_BODY='Closes #12'; export GITHUB_EVENT_NAME=issues
run_check linked-issue >/dev/null
assert_eq 'skips on the issues stream' skip "$(status_of linked-issue)"

# -----------------------------------------------------------------------------------------------
group 'linked-issue: Linear'
# -----------------------------------------------------------------------------------------------
# `linear` is absent from the default `linked-issue-sources`, so a Linear reference must be refused
# with an explanation rather than silently accepted or misread as a GitHub issue.
setup; export PR_BODY='Closes ENG-123'
out=$(run_check linked-issue)
assert_eq 'refuses a Linear reference when linear is not enabled' fail "$(status_of linked-issue)"
assert_contains 'names the input to change' 'linked-issue-sources' "$out"

setup; export PR_BODY='Closes #12'; export INPUT_LINKED_ISSUE_SOURCES='linear'
out=$(run_check linked-issue)
assert_eq 'refuses a GitHub reference when github is not enabled' fail "$(status_of linked-issue)"
assert_contains 'names the input to change' 'linked-issue-sources' "$out"

setup; export PR_BODY='Closes ENG-123' INPUT_LINKED_ISSUE_SOURCES='github,linear'
out=$(run_check linked-issue)
assert_eq 'an absent key is a configuration defect, not a skip' fail "$(status_of linked-issue)"
assert_contains 'names the missing secret' 'LINEAR_API_KEY' "$out"
assert_contains 'explains the fork case' 'fork' "$out"
assert_contains 'tells the caller how to pass it' 'env:' "$out"

setup; export PR_BODY='Closes ENG-123' INPUT_LINKED_ISSUE_SOURCES='github,linear'
export LINEAR_API_KEY=lin_api_stub LINEAR_STUB_CAPTURE="$RUNNER_TEMP/payload.json"
stub_linear approved
out=$(run_check linked-issue)
assert_eq 'accepts a Linear issue carrying the approved label' pass "$(status_of linked-issue)"

# The identifier comes from a pull request body, so it must travel as a GraphQL variable and never be
# spliced into the query text. Inlined, a body could inject query syntax.
payload=$(cat "$RUNNER_TEMP/payload.json" 2>/dev/null || true)
assert_contains 'the identifier travels as a GraphQL variable' '"id":"ENG-123"' "$payload"
assert_not_contains 'the query text carries no interpolated identifier' 'issue(id: \"ENG-123\")' "$payload"
assert_contains 'the query declares the variable' 'String!' "$payload"

setup; export PR_BODY='Closes ENG-123' INPUT_LINKED_ISSUE_SOURCES='github,linear'
export LINEAR_API_KEY=lin_api_stub
stub_linear bug needs-triage
out=$(run_check linked-issue)
assert_eq 'rejects a Linear issue without the approved label' fail "$(status_of linked-issue)"
assert_contains 'lists the labels it does carry' 'bug,needs-triage' "$out"

setup; export PR_BODY='Closes ENG-123' INPUT_LINKED_ISSUE_SOURCES='github,linear'
export LINEAR_API_KEY=lin_api_stub
stub_linear Approved
run_check linked-issue >/dev/null
assert_eq 'matches the Linear label case-insensitively' pass "$(status_of linked-issue)"

setup; export PR_BODY='Closes ENG-123' INPUT_LINKED_ISSUE_SOURCES='github,linear'
export LINEAR_API_KEY=lin_api_stub
out=$(run_check linked-issue)
assert_eq 'rejects a Linear issue that does not exist' fail "$(status_of linked-issue)"
assert_contains 'blames the identifier or the key access' 'may not exist' "$out"

setup; export PR_BODY='Closes ENG-123' INPUT_LINKED_ISSUE_SOURCES='github,linear'
export LINEAR_API_KEY=lin_api_stub LINEAR_STUB_HTTP=401
out=$(run_check linked-issue)
assert_eq 'an HTTP 401 is a configuration defect' fail "$(status_of linked-issue)"
assert_contains 'blames the key' 'LINEAR_API_KEY is invalid' "$out"

setup; export PR_BODY='Closes ENG-123' INPUT_LINKED_ISSUE_SOURCES='github,linear'
export LINEAR_API_KEY=lin_api_stub LINEAR_STUB_HTTP=000
out=$(run_check linked-issue)
assert_eq 'an unreachable Linear is a failure' fail "$(status_of linked-issue)"
assert_contains 'names the host' 'api.linear.app' "$out"

setup; export PR_BODY='Closes ENG-123' INPUT_LINKED_ISSUE_SOURCES='github,linear'
export LINEAR_API_KEY=lin_api_stub INPUT_LINEAR_APPROVED_LABEL='ready-for-dev'
stub_linear 'ready-for-dev'
run_check linked-issue >/dev/null
assert_eq 'honours a custom linear-approved-label' pass "$(status_of linked-issue)"

# `Refs` must not satisfy the gate for Linear either, or the keyword is meaningless in that world.
setup; export PR_BODY='Refs ENG-123' INPUT_LINKED_ISSUE_SOURCES='github,linear'
export LINEAR_API_KEY=lin_api_stub
out=$(run_check linked-issue)
assert_eq 'rejects a bare Refs for Linear too' fail "$(status_of linked-issue)"
assert_contains 'explains that Refs never closes' 'never closes' "$out"

setup; export PR_BODY=$'Closes #12\n\nAlso see ENG-9' INPUT_LINKED_ISSUE_SOURCES='github,linear'
export GH_STUB_ISSUE_LABELS='status:approved'
run_check linked-issue >/dev/null
assert_eq 'resolves the first closing reference' pass "$(status_of linked-issue)"

setup; export PR_BODY=$'Closes ENG-9\n\nAlso see #12' INPUT_LINKED_ISSUE_SOURCES='github,linear'
export LINEAR_API_KEY=lin_api_stub
out=$(run_check linked-issue)
assert_eq 'honours reference order across both sources' fail "$(status_of linked-issue)"
assert_contains 'and it was the Linear one' 'ENG-9' "$out"

setup; export PR_BODY='Closes #12' INPUT_LINKED_ISSUE_SOURCES='github,linear'
export GH_STUB_ISSUE_LABELS='status:approved'
run_check linked-issue >/dev/null
assert_eq 'enabling Linear does not change GitHub issue handling' pass "$(status_of linked-issue)"

# ===============================================================================================
group 'type-label'
# ===============================================================================================
setup; export PR_LABELS='[{"name":"feat"}]'
run_check type-label >/dev/null
assert_eq 'accepts exactly one type label' pass "$(status_of type-label)"

setup; export PR_LABELS='[{"name":"FEAT"}]'
run_check type-label >/dev/null
assert_eq 'matches case-insensitively, as GitHub label names require' pass "$(status_of type-label)"

setup; export PR_LABELS='[{"name":"status:approved"},{"name":"feat"}]'
run_check type-label >/dev/null
assert_eq 'ignores labels outside the type set' pass "$(status_of type-label)"

setup; export PR_LABELS='[{"name":"status:approved"}]'
run_check type-label >/dev/null
assert_eq 'rejects zero type labels' fail "$(status_of type-label)"

setup; export PR_LABELS='[{"name":"feat"},{"name":"fix"}]'
run_check type-label >/dev/null
assert_eq 'rejects more than one type label' fail "$(status_of type-label)"
assert_contains 'names both offending labels' 'feat, fix' "$(cat "$RESULTS_DIR/type-label.msg")"

# ===============================================================================================
group 'pr-title-length'
# ===============================================================================================
setup; export PR_TITLE='feat: add x-counter directive'
run_check pr-title-length >/dev/null
assert_eq 'accepts a title inside the window' pass "$(status_of pr-title-length)"

setup; export PR_TITLE='fix: x'
run_check pr-title-length >/dev/null
assert_eq 'rejects a title below the minimum' fail "$(status_of pr-title-length)"

setup; PR_TITLE=$(printf 'feat: %s' "$(printf 'x%.0s' $(seq 1 90))"); export PR_TITLE
run_check pr-title-length >/dev/null
assert_eq 'rejects a title above the maximum' fail "$(status_of pr-title-length)"

setup; export PR_TITLE='   '
run_check pr-title-length >/dev/null
assert_eq 'rejects a whitespace-only title' fail "$(status_of pr-title-length)"

# The whole point of `LC_ALL=C.UTF-8`: without it `wc -m` counts bytes and a 30-character
# Spanish title measures 38 and is wrongly rejected.
setup; export PR_TITLE='fix: corrección de acentos'
export INPUT_TITLE_MAX=30
out=$(run_check pr-title-length)
assert_eq 'counts characters, not bytes, for a non-ASCII title' pass "$(status_of pr-title-length)"

# ===============================================================================================
group 'pr-title-conventional'
# ===============================================================================================
setup; export PR_TITLE='feat: add x-counter directive'
run_check pr-title-conventional >/dev/null
assert_eq 'accepts a bare Conventional Commit' pass "$(status_of pr-title-conventional)"

setup; export PR_TITLE='refactor(core)!: split the parser module'
run_check pr-title-conventional >/dev/null
assert_eq 'accepts a scope and a breaking marker' pass "$(status_of pr-title-conventional)"

setup; export PR_TITLE='FEAT: shout at the parser'
run_check pr-title-conventional >/dev/null
assert_eq 'accepts an upper-case type' pass "$(status_of pr-title-conventional)"

# Without the newline guard this passes on its first line, because `.` does not match a newline in
# `grep -E` and `$` anchors per line.
setup; export PR_TITLE='feat: valid first line
feat: smuggled second line'
out=$(run_check pr-title-conventional)
assert_eq 'rejects a multi-line title' fail "$(status_of pr-title-conventional)"
assert_contains 'names the single-line rule' 'single line' "$out"

setup; export PR_TITLE='feat add the counter'
run_check pr-title-conventional >/dev/null
assert_eq 'rejects a missing colon' fail "$(status_of pr-title-conventional)"

setup; export PR_TITLE='feat( ): add the counter'
run_check pr-title-conventional >/dev/null
assert_eq 'rejects an empty scope' fail "$(status_of pr-title-conventional)"

setup; export PR_TITLE='nope: add the counter'
out=$(run_check pr-title-conventional)
assert_eq 'rejects an unknown type' fail "$(status_of pr-title-conventional)"
assert_contains 'hints at the real breaking type' "not 'breaking'" "$out"

setup; export PR_TITLE='feat:'
run_check pr-title-conventional >/dev/null
assert_eq 'rejects a type with no description' fail "$(status_of pr-title-conventional)"

# ===============================================================================================
group 'pr-body-structure'
# ===============================================================================================
setup; export PR_LABELS='[{"name":"feat"}]'
stub_repo feat 'feat.md' "$DEFAULT_TEMPLATE_BODY"
export PR_BODY=$'## Summary\n\nSomething.\n\n## Testing\n\nRan the suite.'
run_check pr-body-structure >/dev/null
assert_eq 'accepts a body carrying every declared section' pass "$(status_of pr-body-structure)"

setup; export PR_LABELS='[{"name":"feat"}]'
stub_repo feat 'feat.md' "$DEFAULT_TEMPLATE_BODY"
export PR_BODY=$'## Summary\n\nSomething.'
out=$(run_check pr-body-structure)
assert_eq 'rejects a body missing a declared section' fail "$(status_of pr-body-structure)"
assert_contains 'names the missing section' 'testing' "$out"

setup; export PR_LABELS='[{"name":"feat"}]'
stub_repo feat 'feat.md' "$DEFAULT_TEMPLATE_BODY"
export PR_BODY='Just a flat description with no headings.'
run_check pr-body-structure >/dev/null
assert_eq 'rejects a body with no headings at all' fail "$(status_of pr-body-structure)"

setup; export PR_LABELS='[{"name":"feat"}]'
stub_repo feat 'feat.md' "$DEFAULT_TEMPLATE_BODY"
export PR_BODY=$'## Summary\n\n## Testing'
run_check pr-body-structure >/dev/null
assert_eq 'compares headings case-insensitively and ignoring blanks' pass "$(status_of pr-body-structure)"

setup; export PR_LABELS='[{"name":"feat"}]'
stub_repo feat 'feat.md' "$DEFAULT_TEMPLATE_BODY"
export PR_BODY=$'## Summary\n\n## Testing\n\n## Changelog'
run_check pr-body-structure >/dev/null
assert_eq 'ignores sections the template does not declare' pass "$(status_of pr-body-structure)"

# Dedicated template wins; this is the rule that lets a new type need no registration anywhere.
setup; export PR_LABELS='[{"name":"fix"}]'
stub_repo fix 'fix.md' '## Root cause

## Fix'
printf '%s\n' "$DEFAULT_TEMPLATE_BODY" > "$GH_STUB_REPO_ROOT/$INPUT_DEFAULT_TEMPLATE"
export PR_BODY=$'## Root cause\n\n## Fix'
run_check pr-body-structure >/dev/null
assert_eq 'prefers the dedicated template over the default' pass "$(status_of pr-body-structure)"

setup; export PR_LABELS='[{"name":"chore"}]'
stub_repo feat 'feat.md' "$DEFAULT_TEMPLATE_BODY"
printf '%s\n' "$DEFAULT_TEMPLATE_BODY" > "$GH_STUB_REPO_ROOT/$INPUT_DEFAULT_TEMPLATE"
export PR_BODY=$'## Summary\n\n## Testing'
run_check pr-body-structure >/dev/null
assert_eq 'falls back to the default template for an unlisted type' pass "$(status_of pr-body-structure)"

# Counts what is MISSING. It used to count what the template DECLARES.
setup; export PR_LABELS='[{"name":"feat"}]'
stub_repo feat 'feat.md' "$(printf '## Alpha\n\n## Beta\n\n## Gamma')"
export PR_BODY=$'## Alpha\n\n## Gamma'
run_check pr-body-structure >/dev/null
assert_contains 'counts the sections missing, not the sections declared' \
  'The body is missing 1 required section of 3' "$(cat "$RESULTS_DIR"/*)"

setup; export PR_LABELS='[{"name":"feat"}]'
stub_repo feat 'feat.md' 'no headings at all here'
out=$(run_check pr-body-structure)
assert_eq 'reports a template declaring no sections as a config defect' fail "$(status_of pr-body-structure)"
assert_contains 'blames the configuration, not the pull request' 'Nothing about this pull request is at fault' "$out"

setup; export PR_LABELS='[{"name":"feat"}]'
stub_repo feat 'feat.md' "$DEFAULT_TEMPLATE_BODY"
GH_STUB_REPO_ROOT=$(mktemp -d); export GH_STUB_REPO_ROOT   # the template is simply absent now
out=$(run_check pr-body-structure)
assert_eq 'reports a missing template as a config defect' fail "$(status_of pr-body-structure)"
assert_contains 'names the missing template' 'type template not found' "$out"

# The pull request carries no type label, so there is no template to resolve. `type-label` owns that
# failure; reporting a pass here would claim a validation that never happened.
setup; export PR_LABELS='[]'
run_check pr-body-structure >/dev/null
assert_eq 'skips, rather than passes, when no type label resolves a template' skip "$(status_of pr-body-structure)"
assert_contains 'says which check owns the failure' 'type-label' "$(cat "$RESULTS_DIR/pr-body-structure.msg")"

setup; export PR_LABELS='[{"name":"feat"},{"name":"fix"}]'
run_check pr-body-structure >/dev/null
assert_eq 'skips when several type labels make the template undetermined' skip "$(status_of pr-body-structure)"

# A configured type label becomes a URL path segment. Without the guard, `../` in `type-labels`
# would let a misconfigured input read any path in the consuming repository.
setup; export INPUT_TYPE_LABELS='feat,../../etc/passwd'
export PR_LABELS='[{"name":"../../etc/passwd"}]'
out=$(run_check pr-body-structure)
assert_eq 'rejects a type label that could escape the template directory' fail "$(status_of pr-body-structure)"
assert_contains 'blames the configuration, not the pull request' 'Nothing about this pull request is at fault' "$out"

setup; export GITHUB_EVENT_NAME=issues
run_check pr-body-structure >/dev/null
assert_eq 'skips on the issues stream' skip "$(status_of pr-body-structure)"

# ===============================================================================================
group 'auto-label'
# ===============================================================================================
setup; export GITHUB_EVENT_NAME=issues GITHUB_EVENT_ACTION=opened ISSUE_NUMBER=7
run_check auto-label >/dev/null
assert_eq 'labels a newly opened issue' pass "$(status_of auto-label)"

# `action == opened` also matches a pull request being opened, where `github.event.issue.number`
# does not exist. The gate is what stops the check from reading an empty context.
setup; export GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_ACTION=opened
run_check auto-label >/dev/null
assert_eq 'skips a pull_request opened event' skip "$(status_of auto-label)"

setup; export GITHUB_EVENT_NAME=issues GITHUB_EVENT_ACTION=labeled ISSUE_NUMBER=7
run_check auto-label >/dev/null
assert_eq 'skips an issues event that is not opened' skip "$(status_of auto-label)"

setup; export GITHUB_EVENT_NAME=issues GITHUB_EVENT_ACTION=opened ISSUE_NUMBER=7
export GH_STUB_ISSUE_EDIT=403
out=$(run_check auto-label)
assert_eq 'reports a refused token as a failure' fail "$(status_of auto-label)"
assert_contains 'names the missing grant' "issues: write" "$out"
assert_contains 'offers the opt-out' 'enable-auto-label' "$out"

setup; export GITHUB_EVENT_NAME=issues GITHUB_EVENT_ACTION=opened ISSUE_NUMBER=7
export GH_STUB_ISSUE_EDIT=fail
out=$(run_check auto-label)
assert_eq 'a label that does not exist is a skip, not a failure' skip "$(status_of auto-label)"
assert_contains 'warns rather than failing' 'warning::' "$out"

# ===============================================================================================
group 'report: aggregation'
# ===============================================================================================
# One bad pull request that breaks several checks at once. The behaviour the composite conversion
# exists for: a single check status must not cost the author one push per defect.
setup
export HEAD_REF='wrong-shape' AUTHOR_LOGIN='janedoe'
export PR_TITLE='nope' PR_BODY='Refs #12' PR_LABELS='[{"name":"feat"}]'
stub_repo feat 'feat.md' "$DEFAULT_TEMPLATE_BODY"
for check in auto-label branch-name linked-issue type-label pr-title-length pr-title-conventional pr-body-structure; do
  run_check "$check" >/dev/null
done
for check in auto-label branch-name linked-issue type-label pr-title-length pr-title-conventional pr-body-structure; do
  if [ "$(status_of "$check")" = none ]; then
    bad "every check records a verdict ($check)" "a status" "none"
  else
    ok "every check records a verdict ($check)"
  fi
done
assert_eq 'branch-name failed' fail "$(status_of branch-name)"
assert_eq 'linked-issue failed' fail "$(status_of linked-issue)"
assert_eq 'type-label passed' pass "$(status_of type-label)"
assert_eq 'pr-title-length failed' fail "$(status_of pr-title-length)"
assert_eq 'pr-title-conventional failed' fail "$(status_of pr-title-conventional)"
assert_eq 'auto-label skipped on a pull_request event' skip "$(status_of auto-label)"

# The report is per action, so the PR policy sees only its own five checks and the branch validation
# action only its one. That separation is the point of the split, so it is asserted rather than assumed.
report_for "$PRV_CHECK_LIST" "$PRV_LABEL_LIST" 'Pull request policy' >/dev/null
code=$?
assert_eq 'the PR policy report fails the job' 1 "$code"
summary=$(cat "$GITHUB_STEP_SUMMARY")
assert_contains 'the summary is titled for the action' 'Pull request policy' "$summary"
assert_contains 'the summary names a failing check' 'Linked issue' "$summary"
assert_contains 'the summary renders a table' '| --- | --- | --- |' "$summary"
assert_contains 'the summary tells the author to fix everything at once' 'one push at a time' "$summary"
assert_not_contains 'the PR report omits the branch check' 'Branch name' "$summary"

setup
export HEAD_REF='wrong-shape' AUTHOR_LOGIN='janedoe'
run_check branch-name >/dev/null
report_for "$BRV_CHECK_LIST" "$BRV_LABEL_LIST" 'Branch validation' "$BRANCH_NOTE" >/dev/null
code=$?
assert_eq 'the branch validation report fails on its own single check' 1 "$code"
summary=$(cat "$GITHUB_STEP_SUMMARY")
assert_contains 'the branch summary is titled for the action' 'Branch validation' "$summary"
assert_contains 'the branch note explains the opened-only gate' 'opened' "$summary"
assert_not_contains 'the branch report does not list the PR checks' 'Linked issue' "$summary"

# A pull request that satisfies everything, to prove the gate can actually open.
setup
export HEAD_REF='janedoe/feat/parser-fallback' AUTHOR_LOGIN='janedoe'
export PR_TITLE='feat: add the parser fallback'
export PR_BODY=$'## Summary\n\nAdded the parser fallback.\n\n## Testing\n\nRan the suite.\n\nCloses #12'
export PR_LABELS='[{"name":"feat"}]'
stub_repo feat 'feat.md' "$DEFAULT_TEMPLATE_BODY"
export GH_STUB_ISSUE_LABELS='status:approved'
# All seven, including auto-label: on a pull_request event it records `skip`, exactly as the action runs it.
for check in auto-label branch-name linked-issue type-label pr-title-length pr-title-conventional pr-body-structure; do
  run_check "$check" >/dev/null
done
report_for "$PRV_CHECK_LIST" "$PRV_LABEL_LIST" 'Pull request policy' >/dev/null
code=$?
assert_eq 'the PR policy report passes a compliant pull request' 0 "$code"
assert_contains 'the summary reports success' 'checks passed' "$(cat "$GITHUB_STEP_SUMMARY")"

# ===============================================================================================
group 'report: a check that records nothing'
# ===============================================================================================
setup
rm -f "$RESULTS_DIR"/*.status 2>/dev/null
out=$(report_for "$BRV_CHECK_LIST" "$BRV_LABEL_LIST" 'Branch validation')
code=$?
assert_eq 'the report fails when a check recorded no verdict' 1 "$code"
assert_contains 'and names it as a crash, not a pass' 'did not complete' "$out"
assert_contains 'the missing check is still listed' 'Branch name' "$(cat "$GITHUB_STEP_SUMMARY")"

# A report with no check list at all is a defect in the action, not a verdict about the pull request,
# and it must say so rather than reporting an empty, passing table.
setup; run_check branch-name >/dev/null
out=$(env RESULTS_DIR="$RESULTS_DIR" GITHUB_STEP_SUMMARY="$GITHUB_STEP_SUMMARY" bash "$ROOT/lib/report.sh" 2>&1)
code=$?
assert_eq 'a report with no check list exits non-zero' 1 "$code"
assert_contains 'and blames the action, not the pull request' 'Nothing about the pull request is at fault' "$out"

# Parallel lists that do not line up would silently mislabel every row.
setup; run_check branch-name >/dev/null
out=$(report_for 'branch-name|type-label' 'Branch name')
code=$?
assert_eq 'mismatched check and label lists exit non-zero' 1 "$code"
assert_contains 'and say so explicitly' 'parallel' "$out"

# ===============================================================================================
group 'pull-request-template (the standalone action)'
# ===============================================================================================
# pull-request-template used to be 138 lines of inline bash that the harness never executed: its only
# mention was a YAML parse check. It now delegates to pull-request-template/resolve.sh, which is exercised here
# directly, so the rule it shares with pr-body-structure is actually verified.
run_template() { # <type> [VAR=value...]
  local type=$1
  shift
  # `env` so the VAR=value arguments are applied as environment rather than run as a command.
  env GITHUB_OUTPUT="$RUNNER_TEMP/out.txt" INPUT_TYPE="$type" "$@" bash "$ROOT/pull-request-template/resolve.sh" 2>&1
}
output_of() { grep -m1 "^$1=" "$RUNNER_TEMP/out.txt" 2>/dev/null | cut -d= -f2-; }

setup; stub_repo feat 'feat.md' "$DEFAULT_TEMPLATE_BODY"
out=$(run_template feat)
assert_eq 'resolves a dedicated template' 'dedicated' "$(output_of source)"
assert_eq 'reports it as found' 'true' "$(output_of found)"
assert_eq 'resolves the dedicated path' '.github/PULL_REQUEST_TEMPLATE/feat.md' "$(output_of path)"
assert_eq 'reports the ref it read' 'base1234' "$(output_of ref)"

# `chore` has no dedicated file in the stub repo, so this exercises the fallback rather than the
# rule that was already asserted above.
setup; stub_repo fix 'fix.md' '## Root cause'
printf '%s\n' "$DEFAULT_TEMPLATE_BODY" > "$GH_STUB_REPO_ROOT/$INPUT_DEFAULT_TEMPLATE"
out=$(run_template chore)
assert_eq 'falls back to the default template' 'default' "$(output_of source)"
assert_eq 'and still reports found' 'true' "$(output_of found)"
assert_eq 'and names the default path' "$INPUT_DEFAULT_TEMPLATE" "$(output_of path)"

# The ref chain is the safety property, so each rung is asserted rather than described.
setup; stub_repo feat 'feat.md' "$DEFAULT_TEMPLATE_BODY"
out=$(run_template feat EVENT_SHA=eventsha PR_BASE_SHA='')
assert_eq 'falls back to the event sha outside a pull request' 'eventsha' "$(output_of ref)"

setup; stub_repo feat 'feat.md' "$DEFAULT_TEMPLATE_BODY"
out=$(run_template feat EVENT_SHA=eventsha PR_BASE_SHA=basesha)
assert_eq 'prefers the PR base sha over the event sha' 'basesha' "$(output_of ref)"
setup; stub_repo feat 'feat.md' "$DEFAULT_TEMPLATE_BODY"
out=$(run_template feat EVENT_SHA=eventsha PR_BASE_SHA=basesha INPUT_REF=explicitref)
assert_eq 'an explicit ref wins over both' 'explicitref' "$(output_of ref)"

setup; GH_STUB_REPO_ROOT=$(mktemp -d); export GH_STUB_REPO_ROOT
out=$(run_template feat)
assert_eq 'a missing template is not found' 'false' "$(output_of found)"
assert_eq 'and its file output is empty' '' "$(output_of file)"
assert_eq 'and the source is honestly none' 'none' "$(output_of source)"
assert_contains 'warns without failing' 'warning::' "$out"

setup; GH_STUB_REPO_ROOT=$(mktemp -d); export GH_STUB_REPO_ROOT
out=$(run_template feat INPUT_FAIL_ON_MISSING=true)
assert_eq 'fail-on-missing exits non-zero' 1 "$?"
assert_contains 'and says so as an error' 'error::' "$out"

# A type is a URL path segment, so `../` must be refused before it reaches a URL. This is the check
# the PR policy relies on, and prv_template_resolve is what both surfaces now share.
setup; stub_repo feat 'feat.md' "$DEFAULT_TEMPLATE_BODY"
out=$(run_template '../../../etc/passwd')
assert_eq 'a traversing type exits non-zero' 1 "$?"
assert_contains 'and is refused by name' 'cannot be used as a template name' "$out"
assert_eq 'and writes no path' '' "$(output_of path)"

setup; stub_repo feat 'feat.md' "$DEFAULT_TEMPLATE_BODY"
out=$(run_template FEAT)
assert_eq 'the type is case-folded' '.github/PULL_REQUEST_TEMPLATE/feat.md' "$(output_of path)"

# ===============================================================================================
group 'manifest'
# ===============================================================================================
# Actions are DISCOVERED, never listed. The convention is one directory per action at the repository
# root, so a consumer writes `ailuracollective/actions/<name>@v1` rather than a doubled
# `actions/actions/<name>@v1`, and adding an action needs no edit here.
#
# The manifest is also the one file `bash -n` cannot check, and a stray `: ` inside an unquoted
# description is a YAML parse error that only surfaces on a runner. PyYAML caught exactly that here.
mapfile -t manifests < <(
  find "$ROOT" -mindepth 2 -maxdepth 2 -name 'action.yml' | sed "s|^$ROOT/||" | sort
)
# An `if`, not `[ … ] && ok … || bad …`: a non-zero `ok` would also run the `||` branch.
# A root manifest would make one action the repository's Marketplace entry point, which no action here is.
if [ -f "$ROOT/action.yml" ]; then
  bad 'no action.yml is left at the repository root' 'absent' 'action.yml exists at the root'
else
  ok 'no action.yml is left at the repository root'
fi
# Derived, not pinned. A hardcoded count here would fail the moment another action lands, which is
# the brittleness this layout is meant to remove.
dir_actions=$(printf '%s\n' "${manifests[@]}" | grep -c . || true)
if [ "$dir_actions" -ge 1 ]; then
  ok "directory actions discovered: $dir_actions"
else
  bad 'at least one directory action is discovered' '>= 1' "$dir_actions"
fi
# Passed through the environment rather than interpolated: ${arr[*]@Q} produces shell-quoted
# fragments that become single-character Python strings, not a list.
PRV_MANIFESTS=$(printf '%s\n' "${manifests[@]}"); export PRV_MANIFESTS

if python3 -c 'import yaml' 2>/dev/null; then
  for manifest in "${manifests[@]}"; do
    if detail=$(PRV_ROOT="$ROOT" PRV_MANIFEST="$manifest" python3 -c "
import os, yaml
d = yaml.safe_load(open(os.path.join(os.environ['PRV_ROOT'], os.environ['PRV_MANIFEST'])))
steps = d['runs'].get('steps', [])
assert d.get('name'), 'no name'
assert d.get('description'), 'no description'
assert d.get('author'), 'no author'
assert d['runs']['using'] == 'composite', d['runs'].get('using')
for s in steps:
    assert s.get('run'), 'a step has no run'
    assert s.get('shell') == 'bash', 'a step does not declare shell: bash'
print(len(d.get('inputs', {})), len(steps))
" 2>&1); then
      ok "parses: $manifest ($detail inputs, steps)"
    else
      bad "parses: $manifest" "valid composite action" "$(printf '%s' "$detail" | tail -2)"
    fi
  done

  # Every step that runs a check must be able to survive its own failure, or aggregation is dead:
  # a non-zero step aborts every step after it, including the report. It is asserted on every
  # discovered manifest.
  # Only an action that reports has something to protect: a single-step action like pull-request-template has
  # no later step to skip, so continue-on-error there would only hide its own failure.
  coe=$(PRV_ROOT="$ROOT" python3 -c "
import os, yaml
root = os.environ['PRV_ROOT']
bad = []
for rel in os.environ['PRV_MANIFESTS'].splitlines():
    if not rel:
        continue
    d = yaml.safe_load(open(os.path.join(root, rel)))
    base = os.path.dirname(rel)
    steps = d['runs'].get('steps', [])
    if not any(s.get('if') == 'always()' for s in steps):
        continue
    for s in steps:
        if 'action_path' in (s.get('run') or '') and s.get('if') != 'always()' and not s.get('continue-on-error'):
            bad.append(base + '/' + str(s.get('name')))
print('|'.join(bad))
")
  assert_eq 'every check step in every action declares continue-on-error' '' "$coe"

  # Every script a step invokes must exist, or the step fails on a missing file at run time. This
  # covers an action reaching into ../lib, the one filesystem assumption nothing else exercises.
  #
  # The pattern must match the two closing braces of `${{ ... }}`. An earlier version looked for a
  # single `}`, matched nothing, and passed vacuously while verifying zero paths.
  # Collected first, counted in THIS shell: a `while read` fed by process substitution runs in a
  # subshell, so a counter incremented inside it would always read back as zero.
  paths=$(PRV_ROOT="$ROOT" python3 -c "
import os, re, yaml
root = os.environ['PRV_ROOT']
for rel in os.environ['PRV_MANIFESTS'].splitlines():
    if not rel:
        continue
    manifest = os.path.join(root, rel)
    d = yaml.safe_load(open(manifest))
    base = os.path.dirname(manifest)
    for s in d['runs'].get('steps', []):
        m = re.search(r'action_path\s*\}\}\s*/(\S+)', s.get('run') or '')
        if m:
            print(os.path.normpath(os.path.join(base, m.group(1))))
")
  step_total=$(PRV_ROOT="$ROOT" python3 -c "
import os, yaml
root = os.environ['PRV_ROOT']
total = 0
for rel in os.environ['PRV_MANIFESTS'].splitlines():
    if rel:
        total += len(yaml.safe_load(open(os.path.join(root, rel)))['runs'].get('steps', []))
print(total)
")
  resolved_count=$(printf '%s' "$paths" | grep -c . || true)
  assert_eq 'the path pattern matched one script per invoking step' "$step_total" "$resolved_count"

  missing=''
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ -f "$path" ] || missing="$missing ${path#"$ROOT"/}"
  done <<< "$paths"
  assert_eq 'every script a step invokes exists' '' "$missing"

  # The ownership rule, enforced rather than audited by hand:
  #   - a module in lib/ must be consumed by at least two actions, or it is not shared and belongs
  #     inside the one action that uses it;
  #   - a script only one action runs must live in that action's own directory.
  # Measured from real references only: a `source` line in a script, or a `run:` line in a manifest.
  # A bare grep over the tree would count a module's own name in its own comments.
  ownership=$(PRV_ROOT="$ROOT" python3 -c "
import os, re, yaml
root = os.environ['PRV_ROOT']
rels = [r for r in os.environ['PRV_MANIFESTS'].splitlines() if r]
problems = []
lib_dir = os.path.join(root, 'lib')

def runs(manifest):
    # the scripts a manifest actually invokes, as repo-relative paths
    base = os.path.dirname(manifest)
    out = []
    for s in yaml.safe_load(open(manifest))['runs'].get('steps', []):
        m = re.search(r'action_path\s*\}\}\s*/(\S+)', s.get('run') or '')
        if m:
            out.append(os.path.normpath(os.path.join(base, m.group(1))))
    return out

def sourced(scripts):
    # the lib modules a script pulls in
    out = set()
    for path in scripts:
        for line in open(path):
            m = re.match(r'^source .*?([A-Za-z0-9._-]+\.sh)', line)
            if m:
                out.add(m.group(1))
    return out

script_owners = {}
lib_consumers = {}
for rel in rels:
    manifest = os.path.join(root, rel)
    own = runs(manifest)
    for path in own:
        script_owners.setdefault(path, set()).add(rel)
        # A lib module can be consumed two ways: sourced by a check, or invoked directly as a step
        # (lib/report.sh, which is a shared report rather than a sourced helper). Both count.
        if os.path.dirname(path) == lib_dir:
            lib_consumers.setdefault(os.path.basename(path), set()).add(rel)
    for mod in sourced(own):
        if os.path.isfile(os.path.join(lib_dir, mod)):
            lib_consumers.setdefault(mod, set()).add(rel)

# Rule 1: a lib module needs more than one consumer to earn its place at the root.
for mod in sorted(os.listdir(lib_dir)):
    n = len(lib_consumers.get(mod, ()))
    if n < 2:
        problems.append('lib/%s has %d consumer(s); move it inside the action that uses it' % (mod, n))

# Rule 2: a script one action runs must sit in that action's own directory.
for path, owners in sorted(script_owners.items()):
    if len(owners) > 1:
        continue
    owner = next(iter(owners))
    if os.path.dirname(path) != os.path.dirname(os.path.join(root, owner)):
        problems.append('%s is run only by %s but lives elsewhere' % (path, owner))

print('|'.join(problems))
")
  assert_eq 'every lib module has 2+ consumers and every exclusive script sits in its own action' '' "$ownership"
else
  printf '  skip  PyYAML not installed; the manifests were not parsed\n'
fi

# ===============================================================================================
group 'marketplace metadata'
# ===============================================================================================
# The rules GitHub enforces before it will list an action. They are not optional polish: a missing
# `branding` key means the action cannot be published at all, and the rest are hard rejections.
# A list of categories and an icon exclusion list are copied into the manifests as comments, so this
# assertion is the part that keeps the two from drifting.
mkt=$(PRV_ROOT="$ROOT" python3 -c "
import os, yaml
root = os.environ['PRV_ROOT']
rels = [r for r in os.environ['PRV_MANIFESTS'].splitlines() if r]
COLORS = {'white','black','yellow','blue','green','orange','red','purple','gray-dark'}
CATEGORIES = {
    'testing','code quality','formatting','linting tools','monitoring','code analysis','chat',
    'dependencies','containers','database','files and directories','images and artwork','input',
    'integration','licensing','mail and messaging','mobile','other','project management','publishing',
    'security','seo','text processing','utility','version control','workflow automation',
}
BANNED_ICONS = {
    'coffee','columns','divide-circle','divide-square','divide','frown','hexagon','key','meh',
    'mouse-pointer','smile','tool','x-octagon',
}
owner = 'ailuracollective'
problems, names, seen = [], [], set()
for rel in rels:
    d = yaml.safe_load(open(os.path.join(root, rel)))
    name, desc = d.get('name', ''), d.get('description', '')
    label = '%s: %s' % (rel, name)
    names.append((label, name))
    if not name or not name[0].isupper():
        problems.append(label + ' name must begin with a capital letter')
    if name.lower() in CATEGORIES:
        problems.append(label + ' name collides with a Marketplace category')
    if name.lower() == owner:
        problems.append(label + ' name must not match the publishing owner')
    if name in seen:
        problems.append(label + ' duplicates another action name in this repository')
    seen.add(name)
    if not desc or not desc[0].isupper():
        problems.append(label + ' description must begin with a capital letter')
    # Under 125 characters. The Marketplace rejects a longer one at publish time, which is the worst
    # place to find out: the submission is already filled in when the error appears.
    flat = ' '.join(desc.split())
    if len(flat) >= 125:
        problems.append(label + ' description is %d characters; must be under 125' % len(flat))
    b = d.get('branding')
    if not b:
        problems.append(label + ' has no branding; it cannot be listed in the Marketplace')
        continue
    if b.get('color') not in COLORS:
        problems.append(label + ' branding.color must be one of %s, got %r' % (sorted(COLORS), b.get('color')))
    icon = b.get('icon')
    if not icon:
        problems.append(label + ' branding.icon is missing')
    elif icon in BANNED_ICONS:
        problems.append(label + ' branding.icon %r is on the excluded list' % icon)
print('|'.join(problems))
")
  assert_eq 'every action satisfies the Marketplace metadata rules' '' "$mkt"

# ===============================================================================================
group 'syntax of every script'
# ===============================================================================================
# Every script must parse, and they are discovered rather than listed. `bash -n` stops at a `source`
# line without reading the file, so lib/ is included too; an earlier version globbed directories the
# multi-action layout had removed, matched nothing, and silently checked one file of twelve.
mapfile -t all_scripts < <(
  find "$ROOT" -name '*.sh' \
    -not -path '*/.git/*' -not -path '*/.atl/*' -not -path "$ROOT/odd/*" -print \
    | sed "s|^$ROOT/||" | sort
)
for script in "${all_scripts[@]}"; do
  if bash -n "$ROOT/$script" 2>/dev/null; then
    ok "bash -n $script"
  else
    bad "bash -n $script" "clean parse" "$(bash -n "$ROOT/$script" 2>&1 | head -3)"
  fi
done

# ===============================================================================================
printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
