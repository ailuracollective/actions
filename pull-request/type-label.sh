#!/usr/bin/env bash
# Check: the pull request carries exactly one of the allowed type labels.
# Invoked as type-label.sh from this action's manifest. Records a verdict and always exits 0;
# lib/report.sh fails the job.
# fails the job.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

prv_init type-label

prv_gate 'pull_request' || exit 0

# After the gate: whether the event applies is decided before whether the actor is exempt. `&& exit 0`
# is the inverse of prv_gate's `|| exit 0`: the helper returns 0 when the author IS exempt.
prv_actor_exempt "$AUTHOR_LOGIN" "$INPUT_SKIP_ACTORS" && exit 0

count_types=$(prv_csv_lines "$INPUT_TYPE_LABELS" | wc -l)
human=$(prv_human_list "$INPUT_TYPE_LABELS")

# Untrusted labels reach this check as one JSON array and are filtered by jq, never interpolated.
found=$(prv_matched_type_labels)
count=$(printf '%s' "$found" | grep -c . || true)
names=$(printf '%s' "$found" | paste -sd, - | sed -e 's/,/, /g')
[ -n "$names" ] || names="(none)"

if [ "$count" -eq 0 ]; then
  prv_error 'No type label' \
    "This pull request carries none of the $count_types allowed type labels. Allowed: $human — all bare, with no 'type:' prefix. Fix: add exactly one of them to this pull request (for example 'feat')."
  prv_record fail 'The pull request carries no allowed type label.'
  exit 0
fi

if [ "$count" -gt 1 ]; then
  prv_error 'More than one type label' \
    "This pull request carries $count type labels: $names. A pull request must carry exactly one. Fix: remove all but the one label that matches the change (for example keep 'fix' and drop 'chore')."
  prv_record fail "The pull request carries $count type labels: $names."
  exit 0
fi

prv_note "Exactly one type label: $names"
prv_record pass "Exactly one type label: $names"
