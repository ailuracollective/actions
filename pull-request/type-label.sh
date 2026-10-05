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
# The first allowed label, used as the worked example. Reading it from the configured set rather than
# hardcoding one is what keeps the advice true for a consumer whose family is `type/*`: this message
# used to insist the labels were "all bare", which is only true of the hub's own vocabulary and is
# actively wrong advice for anyone who has moved to a prefixed family.
first=$(prv_csv_lines "$INPUT_TYPE_LABELS" | sed -n '1p')
[ -n "$first" ] || first='feat'

# Untrusted labels reach this check as one JSON array and are filtered by jq, never interpolated.
found=$(prv_matched_type_labels)
count=$(printf '%s' "$found" | grep -c . || true)
names=$(printf '%s' "$found" | paste -sd, - | sed -e 's/,/, /g')
[ -n "$names" ] || names="(none)"

if [ "$count" -eq 0 ]; then
  prv_error 'No type label' \
    "This pull request carries none of the $count_types allowed type labels. Allowed: $human. Fix: add exactly one of them to this pull request (for example '$first')."
  prv_record fail 'The pull request carries no allowed type label.'
  exit 0
fi

if [ "$count" -gt 1 ]; then
  prv_error 'More than one type label' \
    "This pull request carries $count type labels: $names. A pull request must carry exactly one. Fix: remove all but the one that matches the change — a pull request that is both a fix and a chore is two pull requests."
  prv_record fail "The pull request carries $count type labels: $names."
  exit 0
fi

prv_note "Exactly one type label: $names"
prv_record pass "Exactly one type label: $names"
