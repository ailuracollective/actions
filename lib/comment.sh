#!/usr/bin/env bash
# The sticky pull request status comment: one comment per action, updated in place on every run.
# Sourced by lib/report.sh, never executed.
#
# lib/report.sh already renders every verdict exactly once, so publishing it needs no second
# rendering: this module takes that text to the place the author reads without opening the run, the
# pull request conversation. The job summary is still written — the comment is an addition to the
# reporting, never a replacement for it.
#
# Three properties keep it a status board rather than a comment per push:
#   * an HTML marker naming the action identifies the comment to update, so the second run edits the
#     first run's comment instead of adding another one;
#   * the same marker carries the run that wrote it, and run ids only increase, so a slow run cannot
#     leave its outdated result as the current status;
#   * publishing never changes a verdict, so a refused token is a warning rather than a failed gate.
#
# Read from the report step's environment:
#   PRV_ACTION            the key that owns the comment, one per action. The only thing that tells
#                         one action's comment from another's. Unset means nothing is published.
#   PRV_PUBLISH_COMMENT   'false' opts out, which is what `enable-status-comment: false` passes.
#   PRV_COMMENT_AUTHOR    the login that must own the comment, from the `comment-author` input. A
#                         token writes as whoever it belongs to, so this is the only way to hold the
#                         publishing identity to AiluraKitty rather than to whatever token a
#                         consumer happened to pass.
#   PR_NUMBER             the pull request to comment on. Not a runner default, so the manifest passes it.
#   GH_TOKEN              the token for the comment API: `inputs.github-token`, which may be neither the
#                         workflow's token nor a token that may write comments.
#   GH_REPO               owner/repo. Falls back to the runner default GITHUB_REPOSITORY.
# Read from the runner's own defaults, never from a manifest, because they cannot be misconfigured:
#   GITHUB_EVENT_NAME, GITHUB_RUN_ID, GITHUB_REPOSITORY, GITHUB_SERVER_URL

# prv_comment_valid_key <key> — the action key is spliced into the marker that identifies the
# comment, so it is shape-checked before it reaches a payload. Letters, digits, '.', '_' and '-':
# enough for every action directory here, and nothing that could carry HTML, a newline or a quote.
prv_comment_valid_key() {
  printf '%s' "$1" | grep -qE '^[A-Za-z0-9._-]+$'
}

# prv_comment_run_id <value> — true for a run id. Both the id we publish and the one we read back
# from an existing comment are checked with it, because both are compared as numbers below.
prv_comment_run_id() {
  case $1 in
    '' | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# prv_comment_login — the account the comment would be written as, or nothing.
#
# `gh api user` is the only place GitHub answers that: a comment's author is the owner of the token
# that wrote it, not something the payload can carry, so the identity has to be asked for rather
# than declared. A GitHub App installation token answers with the app slug instead of a user, which
# is why the comparison below rejects one.
prv_comment_login() {
  local login
  # Captured first, trimmed second: in a pipeline the exit status is the last command's, and a token
  # whose identity cannot be read would then look like an empty one rather than a failed one.
  login=$(gh api user --jq .login 2>/dev/null) || return 1
  printf '%s' "$login" | tr -d '\r\n'
}

# prv_comment_author <expected> — true when the comment will be written as <expected>.
#
# A status board that lies about its own author is the failure this module must never have: a reader
# who sees `github-actions[bot]` learns nothing about who to ask, and the next thing to do is ask the
# wrong person. So a token that is not the expected account publishes nothing and says why, naming
# both logins — the one it is and the one it has to be. Returns 1 either way, and the caller turns
# that into a warning rather than a verdict.
prv_comment_author() {
  local expected=$1 actual
  actual=$(prv_comment_login) || true
  if [ -z "$expected" ]; then
    prv_warn 'No status comment published: the report step declares no PRV_COMMENT_AUTHOR, so there is no identity to hold the comment to. Fix: set PRV_COMMENT_AUTHOR in the report step. The checks are unaffected.'
    return 1
  fi
  if [ -z "$actual" ]; then
    prv_warn "No status comment published: the identity of the token could not be read, so nothing can say whether the comment would be written as $expected. Fix: check that the token is valid and that 'gh api user' works for it."
    return 1
  fi
  # Case-insensitive, because GitHub logins are: `AiluraKitty` and `ailurakatty` are one account.
  if [ "${actual,,}" != "${expected,,}" ]; then
    prv_warn "No status comment published: the token belongs to $actual, so the comment would be written as $actual and not as $expected. Fix: pass a token for $expected in the report step's GH_TOKEN, or set 'comment-author: $actual' to accept this identity, or set 'enable-status-comment: false'."
    return 1
  fi
}

# prv_comment_marker <key> — the marker prefix that identifies this action's comment.
#
# The searched string deliberately stops at `run=`, and is matched against the *start* of a body
# rather than anywhere inside it. A fixed `-->` marker would match any comment that quotes it and we
# would overwrite a contributor's text with our table; matching only a prefix that also carries a run
# id, and only at the top of the body, means the comments we can rewrite are exactly the ones this
# module wrote, since prv_comment_body puts the marker first. The same substring carries the
# concurrency guard, so one string identifies the comment and orders the runs that wrote it.
prv_comment_marker() {
  printf '<!-- ailuracollective-actions:status action=%s run=' "$1"
}

# prv_comment_body <key> <run_id> <run_url> <summary> — the comment body, marker first.
#
# The marker is the first line so that reading the run id back with `grep -m1` cannot be raced by a
# check message that quotes it: `prv_record` collapses a message to one line, and a message can carry
# pull request text. `summary` is report.sh's rendering verbatim, which ends in a newline; the blank
# line before the link is what keeps Markdown from reflowing the two together.
prv_comment_body() {
  local key=$1 run_id=$2 run_url=$3 summary=$4
  printf '%s%s -->\n\n%s' "$(prv_comment_marker "$key")" "$run_id" "$summary"
  if [ -n "$run_url" ]; then
    printf '\n[Workflow run](%s)\n' "$run_url"
  fi
}

# prv_comment_failure <what> <number> <output> — say why a status comment did not happen.
#
# A refused token is the common case and it has one cause: the checks read with a token somebody was
# happy to grant read access to, and nothing has told the consumer that commenting needs write. Any
# other failure is quoted instead, because "HTTP 500" and "you are missing a permission" call for
# different responses from whoever reads the run.
prv_comment_failure() {
  if printf '%s' "$3" | grep -qiE 'HTTP 403|403 Forbidden|not accessible by'; then
    prv_warn "Could not $1 pull request #$2: the token was refused. Nothing about the pull request is at fault, and the verdict above is unchanged. Fix: add 'pull-requests: write' to the permissions of the job that calls this action, or set 'enable-status-comment: false'. Note that a 'pull_request' trigger from a fork gets a read-only token that no permission block can widen."
    return
  fi
  prv_warn "Could not $1 pull request #$2: $3. The verdict above is unchanged, and the same table is in the job summary."
}

# prv_comment_fetch <repo> <number> <page_file> <error_file> — every page of a pull request's
# comments into <page_file>, returning 1 with the API's own message in <error_file>.
#
# Files rather than a `$(…)` capture, and not for style: a command substitution swallows everything
# printed inside it, so a diagnostic raised here would be captured along with the output and never
# reach the log. That is a silent failure, which is the one thing a status board must never have.
prv_comment_fetch() {
  gh api --paginate "repos/$1/issues/$2/comments?per_page=100" > "$3" 2> "$4"
}

# prv_comment_ids <page_file> <marker> <ids_file> <error_file> — the ids of every comment whose body
# starts with the marker, oldest first, one per line into <ids_file>.
#
# Returns 1 when the page could not be parsed, because a failure to read must not be mistaken for "no
# comment exists" — that would post a second copy of the very comment being looked for.
#
# Every page is read and every match kept. A pull request with more than one page of comments must
# still find its own status comment: reading only the first page would hide it and post a duplicate
# on every run, which is exactly what this module exists to prevent.
prv_comment_ids() {
  jq -s -r --arg m "$2" 'add[]? | select((.body // "") | startswith($m)) | .id' \
    < "$1" > "$3" 2> "$4"
}

# prv_comment_run <repo> <id> <marker> — the run that last wrote a comment, or nothing.
#
# Parameter expansion, not a regex: the marker is a literal, so `${line##*"$marker"}` removes exactly
# it, and `${line%% *}` takes the digits that follow. Returns 1 when the comment cannot be read.
prv_comment_run() {
  local body line
  body=$(gh api "repos/$1/issues/comments/$2" 2>/dev/null | jq -r '.body' 2>/dev/null) || return 1
  line=$(printf '%s\n' "$body" | grep -F -m1 "$3") || return 1
  line=${line##*"$3"}
  printf '%s' "${line%% *}"
}

# prv_publish_status_comment <summary> — create or update this action's status comment.
#
# Returns 0 when the comment is current, including when nothing needed publishing, and 1 when it
# could not be published. Nothing here changes a verdict: report.sh ignores the return code, because
# a gate that cannot comment must still fail the pull requests it found defects in, and a gate that
# passes must not be failed by a comment.
prv_publish_status_comment() {
  local summary=$1

  # A pull request is the only thing with a conversation to comment in. Issue triage runs this same
  # report on the `issues` stream, where there is no pull request to comment on and nothing to say.
  if [ "${GITHUB_EVENT_NAME:-}" != 'pull_request' ]; then
    return 0
  fi

  # The opt-out is read from the manifest rather than inferred from a refused token: a consumer who
  # does not want a comment should not also have to read a warning telling them to grant one.
  if [ "${PRV_PUBLISH_COMMENT:-true}" != 'true' ]; then
    return 0
  fi

  local action=${PRV_ACTION:-}
  local run_id=${GITHUB_RUN_ID:-}
  local repo=${GH_REPO:-${GITHUB_REPOSITORY:-}}
  local number=${PR_NUMBER:-}

  if [ -z "$action" ]; then
    prv_warn "No status comment published: this action's report step declares no PRV_ACTION, so no comment belongs to it. Fix: set PRV_ACTION to the action's directory name in the report step. The checks are unaffected."
    return 1
  fi
  if ! prv_comment_valid_key "$action"; then
    prv_warn "No status comment published: PRV_ACTION '$action' is not a plain action key. Fix: use the action's directory name — letters, digits, '.', '_' and '-' only — because the key is spliced into the marker that identifies the comment."
    return 1
  fi
  if ! prv_comment_run_id "$run_id"; then
    prv_warn 'No status comment published: GITHUB_RUN_ID is missing or unreadable, so this run cannot be ordered against the comment it found and a slower run could overwrite a newer result.'
    return 1
  fi
  if ! prv_comment_run_id "$number"; then
    prv_warn "No status comment published: PR_NUMBER is '$number'. Fix: pass 'PR_NUMBER: \${{ github.event.pull_request.number }}' in the report step; it is not a runner default."
    return 1
  fi
  if [ -z "$repo" ] || [ -z "${GH_TOKEN:-}" ]; then
    # shellcheck disable=SC2016  # `${{ … }}` is the expression a manifest passes, not a shell one
    prv_warn 'No status comment published: the report step has no GH_REPO/GH_TOKEN. Fix: pass "GH_TOKEN: \${{ inputs.github-token }}" and "GH_REPO: \${{ github.repository }}" in the report step.'
    return 1
  fi
  # Before the token is used for anything: writing as the wrong account is worse than not writing,
  # because the wrong account's comment is a comment nobody can take back or correct.
  prv_comment_author "${PRV_COMMENT_AUTHOR:-}" || return 1

  local tmp=${RUNNER_TEMP:-/tmp}
  local page="$tmp/prv-comment-page.json"
  local listed="$tmp/prv-comment-ids.txt"
  local error="$tmp/prv-comment-error.txt"
  local id='' recorded run_url body_text output='' marker
  marker=$(prv_comment_marker "$action")

  if ! prv_comment_fetch "$repo" "$number" "$page" "$error"; then
    prv_comment_failure 'read the comments of' "$number" "$(cat "$error")"
    return 1
  fi
  if ! prv_comment_ids "$page" "$marker" "$listed" "$error"; then
    prv_warn "Could not read the comments of pull request #$number, so no status comment was published. The verdict above is unchanged."
    return 1
  fi
  # The newest match wins. If a duplicate exists from an earlier run, this one keeps updating and the
  # others are left alone: a pull request with two status comments is untidy, a third is worse.
  # `|| true` because grep's exit code is how "no match" is reported, and no match is an ordinary
  # outcome here rather than a failure — the ids file may legitimately hold nothing.
  id=$(grep -E '^[0-9]+$' "$listed" | tail -n 1) || true

  if [ -n "$id" ]; then
    # The comment is read again here instead of having its run id parsed out of the listing above.
    # The comparison is a best-effort ordering rather than a lock — the comments API offers no
    # conditional update, so the newest comment cannot be claimed atomically — and reading the
    # comment immediately before writing is as late as this API allows the decision to be made.
    if recorded=$(prv_comment_run "$repo" "$id" "$marker") && prv_comment_run_id "$recorded"; then
      if [ "$recorded" -gt "$run_id" ]; then
        prv_note "A newer run ($recorded) already reported this action's result, so run $run_id leaves it in place. An outdated result is never the current status."
        return 0
      fi
    else
      # The comment exists but its run id could not be read: it was deleted while this run worked, or
      # the token can list comments but not read one. Creating a new one beats leaving the pull
      # request with no status at all.
      id=''
    fi
  fi

  run_url=''
  if [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
    run_url="${GITHUB_SERVER_URL%/}/${GITHUB_REPOSITORY}/actions/runs/${run_id}"
  fi
  body_text=$(prv_comment_body "$action" "$run_id" "$run_url" "$summary")

  if [ -n "$id" ]; then
    if output=$(gh api --method PATCH "repos/$repo/issues/comments/$id" -F "body=$body_text" --silent 2>&1); then
      prv_note "Status comment updated on pull request #$number."
      return 0
    fi
    prv_comment_failure 'update the status comment on' "$number" "$output"
    return 1
  fi

  if output=$(gh api --method POST "repos/$repo/issues/$number/comments" -F "body=$body_text" --silent 2>&1); then
    prv_note "Status comment posted on pull request #$number."
    return 0
  fi
  prv_comment_failure 'post the status comment on' "$number" "$output"
  return 1
}
