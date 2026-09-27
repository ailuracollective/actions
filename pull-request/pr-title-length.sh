#!/usr/bin/env bash
# Check: the pull request title falls inside the configured character window.
# Invoked as pr-title-length.sh from this action's manifest. Records a verdict and always exits 0;
# lib/report.sh fails the job.
# fails the job.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

prv_init pr-title-length

prv_gate 'pull_request' || exit 0

# After the gate: whether the event applies is decided before whether the actor is exempt. `&& exit 0`
# is the inverse of prv_gate's `|| exit 0`: the helper returns 0 when the author IS exempt.
prv_actor_exempt "$AUTHOR_LOGIN" "$INPUT_SKIP_ACTORS" && exit 0

# `LC_ALL=C.UTF-8` is load bearing: without it `wc -m` counts bytes and a non-Latin title is wrongly
# rejected as too long. `printf '%s'` avoids a trailing newline inflating the count by one.
length=$(printf '%s' "$PR_TITLE" | LC_ALL=C.UTF-8 wc -m)
length=$((length + 0))  # strip the whitespace `wc -m` may pad with

min=$INPUT_TITLE_MIN
max=$INPUT_TITLE_MAX

if ! printf '%s' "$PR_TITLE" | grep -qE '[^[:space:]]'; then
  prv_error 'PR title is empty or whitespace only' \
    "The title has no visible characters (measured length $length). Fix: set a real title of $min-$max characters, for example 'feat: add x-counter directive'."
  prv_record fail 'The title has no visible characters.'
  exit 0
fi

if [ "$length" -lt "$min" ]; then
  prv_error 'PR title is too short' \
    "The title measures $length character(s); the minimum is $min and the maximum is $max. Fix: lengthen the description without padding it with filler — for example 'fix: guard the x-for parser against empty input' is 47 characters."
  prv_record fail "The title measures $length characters, below the minimum of $min."
  exit 0
fi

if [ "$length" -gt "$max" ]; then
  prv_error 'PR title is too long' \
    "The title measures $length character(s); the minimum is $min and the maximum is $max. Fix: move the detail into the pull request body and keep the title to one line — for example 'feat: add x-counter directive' is 29 characters."
  prv_record fail "The title measures $length characters, above the maximum of $max."
  exit 0
fi

prv_note "PR title measures $length characters (allowed range: $min-$max)."
prv_record pass "The title measures $length characters (allowed range: $min-$max)."
