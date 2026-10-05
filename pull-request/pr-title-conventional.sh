#!/usr/bin/env bash
# Check: the pull request title is a Conventional Commit subject.
# Invoked as pr-title-conventional.sh from this action's manifest. Records a verdict and always exits 0;
# lib/report.sh fails the job.
# fails the job.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

prv_init pr-title-conventional

prv_gate 'pull_request' || exit 0

# After the gate: whether the event applies is decided before whether the actor is exempt. `&& exit 0`
# is the inverse of prv_gate's `|| exit 0`: the helper returns 0 when the author IS exempt.
prv_actor_exempt "$AUTHOR_LOGIN" "$INPUT_SKIP_ACTORS" && exit 0

# The type vocabulary, not the label vocabulary: a title follows Conventional Commits, and the twelve
# types release tooling parses are not the five labels a repository creates. `prv_title_types` falls
# back to `type-labels` for a consumer that declares only one set.
cleaned=$(prv_csv_lines "$(prv_title_types)")
# One derivation feeds the accept regex and the diagnosis messages, so the two cannot drift.
types=$(printf '%s\n' "$cleaned" | paste -sd'|' -)
human=$(prv_human_list "$(prv_title_types)")
count_types=$(printf '%s\n' "$cleaned" | wc -l)

title_regex="^(${types})(\([a-z0-9][a-z0-9._/-]*\))?!?:[[:space:]]*[^[:space:]].*$"

# Lowercasing first is what makes every later comparison case-insensitive.
lower=$(printf '%s' "$PR_TITLE" | tr '[:upper:]' '[:lower:]')

# This guard MUST precede the accept regex: `.` does not match a newline in `grep -E` and `$`
# anchors per line, so a two-line title would otherwise pass on its first line.
if [[ $PR_TITLE == *$'\n'* ]]; then
  prv_error 'PR title must be a single line' \
    "A Conventional Commit subject is one line. Fix: replace the title with a single line of the form '<type>(<scope>)!: <description>' and move everything else into the pull request body."
  prv_record fail 'The title spans more than one line.'
  exit 0
fi

if printf '%s' "$lower" | grep -qE "$title_regex"; then
  prv_note 'PR title matches <type>(<scope>)!: <description>.'
  prv_record pass 'The title matches <type>(<scope>)!: <description>.'
  exit 0
fi

if ! printf '%s' "$lower" | grep -q ':'; then
  prv_error 'PR title is missing the ':' separator' \
    "Conventional Commits are '<type>(<scope>): <description>'. Fix: add the colon after the type and scope — for example 'feat: add x-counter directive'."
  prv_record fail "The title carries no ':' separator."
  exit 0
fi

head_part=${lower%%:*}
head_part=${head_part%!}

if [[ $head_part == *\(*\)* ]]; then
  scope=${head_part#*(}
  scope=${scope%)}
  head_part=${head_part%%(*}
  if ! printf '%s' "$scope" | grep -qE '^[a-z0-9][a-z0-9._/-]*$'; then
    # Matched after lowercasing, so `feat(UI): x` passes: do not claim a lowercase constraint.
    # What this rejects is spaces and empty parentheses.
    prv_error 'PR title has an invalid scope' \
      "The scope '($(prv_escape "$scope"))' is not usable. Fix: use a short single-word scope with no spaces — for example 'feat(ui): add x-counter directive' — or drop the parentheses entirely: 'feat: add x-counter directive'."
    prv_record fail "The scope '$(prv_escape "$scope")' is not usable."
    exit 0
  fi
fi

if ! printf '%s\n' "$head_part" | grep -qxE "($types)"; then
  # The 'breaking' hint is only true when the configured set spells it 'breaking-change' and has no
  # bare 'breaking'; otherwise it would assert something false about a custom set.
  breaking_note=''
  if printf '%s\n' "$cleaned" | grep -qx 'breaking-change' && ! printf '%s\n' "$cleaned" | grep -qx 'breaking'; then
    breaking_note=", and note that the breaking type is 'breaking-change', not 'breaking'"
  fi
  prv_error 'PR title has an unknown type' \
    "'$(prv_escape "$PR_TITLE")' starts with '$(prv_escape "$head_part")', which is not one of the $count_types allowed types. Allowed: $human — all lowercase$breaking_note. Fix: replace the type with one of those, for example 'feat: add x-counter directive'."
  prv_record fail "'$(prv_escape "$head_part")' is not an allowed type."
  exit 0
fi

description=${lower#*:}
# `%s\n`, not `%s`: an empty description emits zero lines, grep exits 1, and this branch is never
# reached.
if printf '%s\n' "$description" | grep -qE '^[[:space:]]*$'; then
  prv_error 'PR title has no description' \
    "A Conventional Commit needs a description after the colon. Fix: describe the change after the colon, for example 'feat: add x-counter directive'."
  prv_record fail 'The title has a type but no description after the colon.'
  exit 0
fi

prv_error 'PR title is not a Conventional Commit' \
  "'$(prv_escape "$PR_TITLE")' does not match '<type>(<scope>)!: <description>'. Fix: rewrite it as 'feat: add x-counter directive' (or 'refactor(core)!: split the parser module')."
prv_record fail 'The title does not match the Conventional Commit subject shape.'
