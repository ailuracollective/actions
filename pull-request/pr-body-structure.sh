#!/usr/bin/env bash
# Check: the pull request body carries every section its type's template declares.
# Invoked as scripts/pr-body-structure.sh. Records a verdict and always exits 0; report.sh fails the job.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/template.sh"

prv_init pr-body-structure

prv_gate 'pull_request' || exit 0

# After the gate: whether the event applies is decided before whether the actor is exempt. `&& exit 0`
# is the inverse of prv_gate's `|| exit 0`: the helper returns 0 when the author IS exempt.
prv_actor_exempt "$AUTHOR_LOGIN" "$INPUT_SKIP_ACTORS" && exit 0

matched=$(prv_matched_type_labels)
count=$(printf '%s' "$matched" | grep -c . || true)

# Zero or several type labels is `type-label`'s failure, not this one's. Inside a single job there is
# no sibling job to defer to, so this is reported as skipped rather than as a pass it never earned.
if [ "$count" -eq 0 ] || [ "$count" -gt 1 ]; then
  prv_note "This pull request carries $count type labels, so the template it should have used is undetermined. Skipping the body-section check; the type-label check owns this failure."
  prv_record skip "The pull request carries $count type labels, so its template is undetermined. The type-label check owns this failure."
  exit 0
fi

type=$(printf '%s' "$matched" | tr '[:upper:]' '[:lower:]')

runner_tmp=${RUNNER_TEMP:-/tmp}
template_file="$runner_tmp/pr-template.md"
mkdir -p "$runner_tmp"

# The resolution rule lives in lib/template.sh, shared with the standalone pr-template action.
# BASE_SHA is the pull request base, never `github.sha`: on a fork that is the attacker-controlled
# head, and this check holds a token.
# `|| code=$?` rather than `if ! …; then code=$?`, because `!` inverts the status and `$?` would
# report 0 for every failure, collapsing the two distinct diagnostics into one.
code=0
prv_template_resolve "$type" "$INPUT_TEMPLATE_DIR" "$INPUT_DEFAULT_TEMPLATE" \
  "$GH_REPO" "$BASE_SHA" "$template_file" || code=$?

if [ "$code" -eq 2 ]; then
  prv_error 'Workflow misconfiguration: unsupported type label' \
    "The type label '$type' is in the allowed set but cannot be used as a template name. Nothing about this pull request is at fault. Fix: drop path characters from the 'type-labels' input, or use only letters, digits, dots, hyphens and underscores."
  prv_record fail "The configured type label '$type' cannot be used as a template name."
  exit 0
fi

if [ "$code" -eq 1 ]; then
  prv_error 'Workflow misconfiguration: type template not found' \
    "The template '$INPUT_DEFAULT_TEMPLATE' could not be read from $GH_REPO at base ref $BASE_SHA. Nothing about this pull request is at fault. Fix: restore that file on the default branch, or correct the 'template-dir' and 'default-template' inputs."
  prv_record fail "The template '$INPUT_DEFAULT_TEMPLATE' could not be read at base ref $BASE_SHA."
  exit 0
fi

template=$PRV_TEMPLATE_PATH
source_kind=$PRV_TEMPLATE_SOURCE
[ "$source_kind" = dedicated ] || prv_note "No dedicated template for type '$type'; using $template."

# Normalised headings, so template and body are compared the same way; the trailing '(required)' is
# stripped, else an unchanged copied template fails on the suffix.
# `|| :` is load bearing: the last grep exits 1 on empty input and a function returns its last
# status, so `present=$(...)` would kill the script under `errexit` before any annotation.
# Emptiness is asserted below instead.
headings() {
  {
    grep '^## ' \
      | sed -E 's/^##[[:space:]]+//' \
      | sed -E 's/[[:space:]]*\([^()]*\)[[:space:]]*$//' \
      | tr -d '\r' \
      | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' \
      | tr '[:upper:]' '[:lower:]' \
      | grep -v '^$'
  } || :
}

required=$(headings < "$template_file" || :)
present=$(printf '%s' "$PR_BODY" | headings || :)

if [ -z "$required" ]; then
  prv_error 'Workflow misconfiguration: type template declares no sections' \
    "The template '$template' was read from $GH_REPO at base ref $BASE_SHA but contains no '## ' headings, so this check cannot determine what a '$type' pull request must carry. Nothing about this pull request is at fault. Fix: restore the '## ' sections in that template on the default branch, or correct the 'template-dir' and 'default-template' inputs."
  prv_record fail "The template '$template' declares no '## ' sections."
  exit 0
fi

if [ -z "$present" ]; then
  prv_error 'PR body has no sections at all' \
    "This pull request's description contains no '## ' second-level heading, but the '$type' template ($template) declares $(printf '%s\n' "$required" | wc -l) required section(s). Fix: re-open the pull request from the matching template — the 'Create pull request' link on the Issue, or the '$INPUT_TEMPLATE_DIR/$type.md' template — then paste the template body into the description so every required '## ' section is present."
  prv_record fail 'The body carries no second-level heading at all.'
  exit 0
fi

missing=0
while IFS= read -r heading; do
  [ -n "$heading" ] || continue
  if ! printf '%s\n' "$present" | grep -qxF "$heading"; then
    missing=$((missing + 1))
    prv_error 'Missing required section' \
      "The '$type' template ($template) declares a section this pull request body does not carry: '$heading'. Fix: re-open the pull request from the matching template — the 'Create pull request' link on the Issue, or the '$INPUT_TEMPLATE_DIR/$type.md' template — so the '## $heading' section appears, then copy the template body into the description."
  fi
done <<< "$required"

if [ "$missing" -ne 0 ]; then
  # Counts what is MISSING, not what the template declares.
  noun=section
  [ "$missing" -eq 1 ] || noun=sections
  prv_record fail "The body is missing $missing required $noun of $(printf '%s\n' "$required" | wc -l | tr -d ' ') declared by $template."
  exit 0
fi

prv_note "PR body carries every section required by $template (type label: $type, template source: $source_kind)."
prv_record pass "The body carries every section required by $template (type source: $source_kind)."
