#!/usr/bin/env bash
# Check: the pull request closes an issue that exists and carries the approved label.
# Invoked as linked-issue.sh from this action's manifest. Records a verdict and always exits 0;
# lib/report.sh fails the job.
# fails the job.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

prv_init linked-issue

prv_gate 'pull_request' || exit 0

sources=$(prv_csv_lines "$INPUT_LINKED_ISSUE_SOURCES" | tr '[:upper:]' '[:lower:]')
source_github=no
source_linear=no
printf '%s\n' "$sources" | grep -qx 'github' && source_github=yes
printf '%s\n' "$sources" | grep -qx 'linear' && source_linear=yes

# Untrusted body: read from the environment and piped to grep on stdin, never spliced into this script.
# `#N` and `TEAMKEY-N` are the two reference shapes; both require a closing keyword, so a bare mention
# pasted out of a log never satisfies the gate.
reference=$(printf '%s' "$PR_BODY" \
  | grep -oiE '\b(closes|fixes|resolves)[[:space:]]+(#[0-9]+|[A-Za-z][A-Za-z0-9]*-[0-9]+)\b' \
  | head -n 1 \
  | grep -oiE '#[0-9]+|[A-Za-z][A-Za-z0-9]*-[0-9]+' || true)

if [ -z "$reference" ]; then
  non_closing=$(printf '%s' "$PR_BODY" | grep -oiE '\brefs[[:space:]]+(#[0-9]+|[A-Za-z][A-Za-z0-9]*-[0-9]+)\b' | head -n 1 || true)
  if [ -n "$non_closing" ]; then
    prv_error 'PR body has no closing keyword' \
      "Found '$non_closing', which is a non-closing reference: 'Refs' never closes the issue. Fix: change it to Closes, Fixes or Resolves followed by the reference on a line of its own under 'Linked issue' in the pull request body."
    prv_record fail "The body references '$non_closing', which is a non-closing reference."
  else
    prv_error 'PR body has no closing keyword' \
      "No closing reference found. Fix: add a line reading 'Closes #N' for a GitHub issue, or 'Closes TEAMKEY-N' for a Linear one, under 'Linked issue' in the pull request body. A bare issue URL, a 'Refs' line, or an unprefixed identifier does not count."
    prv_record fail 'The body carries no Closes/Fixes/Resolves reference.'
  fi
  exit 0
fi

linear_label=${INPUT_LINEAR_APPROVED_LABEL:-approved}
linear_label_lower=$(printf '%s' "$linear_label" | tr '[:upper:]' '[:lower:]')

# The GraphQL document is static; the identifier travels as a variable, never inside the query text.
# Safe to build with printf because prv_valid_linear_identifier has already constrained the value.
# shellcheck disable=SC2016  # `$id` is a GraphQL variable, not a shell expansion
linear_payload() {
  printf '{"query":"query IssueApproval($id: String!) { issue(id: $id) { identifier state { name } labels { nodes { name } } } }","variables":{"id":"%s"}}' "$1"
}

# ----------------------------------------------------------------------------------------------
# A GitHub issue: must exist in this repository and carry the approved label.
# ----------------------------------------------------------------------------------------------
check_github_issue() {
  local number=$1

  if [ "$source_github" = no ]; then
    # shellcheck disable=SC2016  # backticks quote the input name in the message, not a subshell
    prv_error 'PR links a GitHub issue, but `github` is not an enabled linked-issue source' \
      "The body closes #$number, but 'linked-issue-sources' is '$INPUT_LINKED_ISSUE_SOURCES'. Fix: add 'github' to the 'linked-issue-sources' input, or change the body to reference an enabled source."
    prv_record fail "The body closes #$number but 'github' is not an enabled linked-issue source."
    return 0
  fi

  if ! labels=$(gh api "repos/$GH_REPO/issues/$number" --jq '.labels[].name' 2>/dev/null); then
    prv_error 'Linked issue not found' \
      "Issue #$number referenced by this pull request could not be read in $GH_REPO (it may not exist, or it is a pull request rather than an issue). Fix: point 'Closes #N' at a real issue number in this repository, or create the issue first."
    prv_record fail "Issue #$number could not be read in $GH_REPO."
    return 0
  fi

  if ! printf '%s\n' "$labels" | tr '[:upper:]' '[:lower:]' | grep -qx "$INPUT_APPROVED_LABEL"; then
    current=$(printf '%s' "$labels" | paste -sd, - )
    [ -n "$current" ] || current="(none)"
    prv_error 'Linked issue is not approved' \
      "Issue #$number does not carry the '$INPUT_APPROVED_LABEL' label. Its current labels: $current. Fix: ask a maintainer to triage issue #$number and apply '$INPUT_APPROVED_LABEL' to it, then re-run this check. Do not add the label yourself."
    prv_record fail "Issue #$number does not carry '$INPUT_APPROVED_LABEL'."
    return 0
  fi

  prv_note "Issue #$number exists and is approved."
  prv_record pass "Issue #$number exists and carries '$INPUT_APPROVED_LABEL'."
}

# ----------------------------------------------------------------------------------------------
# A Linear issue: must exist in the workspace and carry the approved label.
#
# Unlike `#N`, `TEAMKEY-N` is not a GitHub issue and no closing keyword actually closes it. The
# keyword is still required, so the gate reads the same in both worlds and a stray identifier pasted
# out of a log cannot satisfy it.
# ----------------------------------------------------------------------------------------------
check_linear_issue() {
  local identifier=$1

  if [ "$source_linear" = no ]; then
    # shellcheck disable=SC2016  # backticks quote the input name in the message, not a subshell
    prv_error 'PR links a Linear issue, but `linear` is not an enabled linked-issue source' \
      "The body closes $identifier, but 'linked-issue-sources' is '$INPUT_LINKED_ISSUE_SOURCES', which does not include 'linear'. Fix: add 'linear' to the 'linked-issue-sources' input, or change the body to reference an enabled source."
    prv_record fail "The body closes $identifier but 'linear' is not an enabled linked-issue source."
    return 0
  fi

  # The identifier reached us from a pull request body, so it is untrusted even though the extraction
  # regex already constrains it. Re-checking the shape here is what makes splicing it into the JSON
  # payload below safe: nothing outside this character class can break out of a JSON string.
  if ! prv_valid_linear_identifier "$identifier"; then
    prv_error 'Malformed Linear reference' \
      "'$identifier' is not a Linear issue identifier. Fix: use the team key and number, for example 'Closes ENG-123'."
    prv_record fail "'$(prv_escape "$identifier")' is not a Linear issue identifier."
    return 0
  fi

  # No key is a configuration defect, not a skip. A `pull_request` from a fork has no secrets at all,
  # so this is the common way to hit it: the maintainer must add the secret, and the message says so.
  if [ -z "${LINEAR_API_KEY:-}" ]; then
    prv_error 'Workflow misconfiguration: no Linear API key' \
      "The body closes $identifier, which needs a Linear lookup, but LINEAR_API_KEY is empty. Nothing about the pull request is at fault. Fix: add LINEAR_API_KEY as a repository secret and pass it into the job that calls this action, as 'env: LINEAR_API_KEY: \${{ secrets.LINEAR_API_KEY }}'. Note that a 'pull_request' trigger from a fork never receives secrets, so that pull request cannot be validated this way."
    prv_record fail 'LINEAR_API_KEY is empty, so the Linear lookup could not be attempted.'
    return 0
  fi

  local runner_tmp=${RUNNER_TEMP:-/tmp}
  local response="$runner_tmp/linear-response.json"
  local http_code
  # A personal API key goes in the Authorization header RAW. Linear rejects a `Bearer` prefix for
  # personal keys, unlike an OAuth access token.
  http_code=$(curl -sS -o "$response" -w '%{http_code}' \
    -X POST 'https://api.linear.app/graphql' \
    -H 'Content-Type: application/json' \
    -H "Authorization: $LINEAR_API_KEY" \
    --data "$(linear_payload "$identifier")" 2>/dev/null) || http_code=000

  case $http_code in
    000)
      prv_error 'Linear could not be reached' \
        "The request to Linear for $identifier did not complete (HTTP $http_code). Fix: check the runner's network access to api.linear.app, and retry."
      prv_record fail "The Linear request for $identifier did not complete."
      return 0
      ;;
    400 | 401 | 403)
      prv_error 'Workflow misconfiguration: Linear rejected the API key' \
        "Linear answered HTTP $http_code for $identifier, which means LINEAR_API_KEY is invalid, expired, or lacks access to the workspace holding $identifier. Fix: issue a new personal API key with issue read access, store it as the LINEAR_API_KEY secret, and retry."
      prv_record fail "Linear rejected LINEAR_API_KEY with HTTP $http_code."
      return 0
      ;;
    2*) ;;
    *)
      prv_error 'Linear returned an unexpected response' \
        "The request for $identifier returned HTTP $http_code. Fix: retry; if it persists, Linear's API may have changed."
      prv_record fail "Linear returned HTTP $http_code for $identifier."
      return 0
      ;;
  esac

  local issue
  issue=$(jq -r '.data.issue' < "$response" 2>/dev/null || printf 'unreadable')

  if [ "$issue" = 'null' ] || [ "$issue" = 'unreadable' ] || [ -z "$issue" ]; then
    prv_error 'Linked Linear issue not found' \
      "Issue $identifier could not be read from Linear. It may not exist, or LINEAR_API_KEY may not have access to the workspace or team that owns it. Fix: confirm the identifier in Linear, or grant the key access to that team."
    prv_record fail "Linear issue $identifier could not be read."
    return 0
  fi

  local labels
  labels=$(jq -r '.data.issue.labels.nodes[].name' < "$response" 2>/dev/null || true)

  if ! printf '%s\n' "$labels" | tr '[:upper:]' '[:lower:]' | grep -qx "$linear_label_lower"; then
    current=$(printf '%s' "$labels" | paste -sd, - )
    [ -n "$current" ] || current="(none)"
    prv_error 'Linked Linear issue is not approved' \
      "Linear issue $identifier does not carry the '$linear_label' label. Its current labels: $current. Fix: ask a maintainer to triage $identifier in Linear and apply '$linear_label', then re-run this check. Do not add the label yourself."
    prv_record fail "Linear issue $identifier does not carry '$linear_label'."
    return 0
  fi

  prv_note "Linear issue $identifier exists and is approved."
  prv_record pass "Linear issue $identifier exists and carries '$linear_label'."
}

# ----------------------------------------------------------------------------------------------
# Dispatch. Last, because bash executes top-down: both handlers must exist before either is called.
# ----------------------------------------------------------------------------------------------
case $reference in
  '#'*)
    check_github_issue "${reference#\#}"
    ;;
  *)
    check_linear_issue "$reference"
    ;;
esac
