#!/usr/bin/env bash
# Check: the head branch reads <github-username>/<type>/<description> and is owned by the PR author.
# Invoked as branch-name.sh from this action's manifest. Records a verdict and always exits 0;
# lib/report.sh fails the job.
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

prv_init branch-name

# `opened` only: GitHub cannot rename a branch an open pull request points at, so `head.ref` is
# immutable for the life of the pull request. A pull request already open when this check was
# added is therefore never validated by it.
prv_gate 'pull_request' 'opened' || exit 0

types=$(prv_csv_lines "$INPUT_BRANCH_TYPES" | paste -sd'|' -)
human=$(prv_human_list "$INPUT_BRANCH_TYPES")
branch_regex="^[a-z0-9-]+/($types)/[a-z0-9._-]+$"
author_segment=$(printf '%s' "$AUTHOR_LOGIN" | tr '[:upper:]' '[:lower:]')

if ! printf '%s' "$HEAD_REF" | grep -qE "$branch_regex"; then
  prv_error 'Invalid branch name' \
    "'$HEAD_REF' does not match <github-username>/<type>/<description>. Expected shape: janedoe/feat/parser-fallback. Fix: rename the branch to janedoe/<type>/<short-description> (all lowercase; the type must be one of $human; the description may use a-z, 0-9, dots, hyphens and underscores), then push the new name and update the pull request."
  prv_record fail "Head branch '$HEAD_REF' does not match <github-username>/<type>/<description>."
  exit 0
fi

owner_segment=${HEAD_REF%%/*}
if [ "$owner_segment" != "$author_segment" ]; then
  prv_error 'Branch owner does not match the pull request author' \
    "Branch '$HEAD_REF' starts with '$owner_segment', but this pull request was opened by '$AUTHOR_LOGIN' (expected segment '$author_segment'). Fix: rename the branch to $author_segment/<type>/<description> — for example janedoe/feat/parser-fallback — and update the pull request to point at the renamed branch. The first segment must be the GitHub username of the person responsible for the change, lowercased."
  prv_record fail "Head branch is owned by '$owner_segment' but the pull request author is '$AUTHOR_LOGIN'."
  exit 0
fi

prv_note "Branch '$HEAD_REF' is valid for author '$AUTHOR_LOGIN'."
prv_record pass "Branch '$HEAD_REF' is valid for author '$AUTHOR_LOGIN'."
