#!/usr/bin/env bash
# Shared helpers for the pull-request-validation checks. Sourced by every check, never executed.
#
# The repository's contribution-policy checks run as steps of ONE composite action, so there is a
# single GitHub check status. Each check therefore records a verdict and exits 0; lib/report.sh
# runs last, renders every verdict, and is the only thing that fails the job.

# ---------------------------------------------------------------------------------------------
# Result contract. Written by prv_record, read only by lib/report.sh.
#
#   $RESULTS_DIR/<check>.status   exactly one of: pass | fail | skip
#   $RESULTS_DIR/<check>.msg      one line of human text, verbatim, untrusted characters included
#
# One file per field, never a delimited line: a pull request body can contain any delimiter we might
# pick, and a tab- or pipe-separated status line would be silently misread as extra fields.
# A check that records nothing leaves no status file, which report.sh reports as `error` — an
# unexpected crash can never be mistaken for a pass.
# ---------------------------------------------------------------------------------------------
: "${RESULTS_DIR:=${RUNNER_TEMP:-/tmp}/prv-results}"

# Name the calling check and make its results directory available. Call first, before any verdict.
prv_init() {
  CHECK_NAME=$1
  export CHECK_NAME
  mkdir -p "$RESULTS_DIR"
}

# prv_record <pass|fail|skip> <message...>
prv_record() {
  local status=$1
  shift
  # The message may span lines; collapse whitespace so the summary table stays one row per check.
  printf '%s' "$*" | tr '\n' ' ' | tr -d '\r' | sed -E -e 's/[[:space:]]+/ /g' -e 's/^ //' -e 's/ $//' \
    > "$RESULTS_DIR/$CHECK_NAME.msg"
  printf '%s' "$status" > "$RESULTS_DIR/$CHECK_NAME.status"
}

# Percent-escape text destined for a workflow command. Untrusted pull request text reaches
# `::error` through here; the caller must pass every interpolated value through it.
prv_escape() {
  # `%` is escaped FIRST, or the `%` introduced by the later replacements gets escaped in turn.
  printf '%s' "$1" | sed -e 's/%/%%/g' -e 's/\r/%0D/g' -e 's/\n/%0A/g'
}

# prv_error <title> <message...> — a failing check's annotation, fully escaped.
prv_error() {
  local title=$1
  shift
  printf '::error title=%s::%s\n' "$(prv_escape "$title")" "$(prv_escape "$*")"
}

# prv_note <message...> — a passing check's trace, or an advisory that is not a failure.
prv_note() {
  printf '%s\n' "$*"
}

# prv_warn <message...> — something the consumer should know that does not fail the check.
prv_warn() {
  printf '::warning::%s\n' "$(prv_escape "$*")"
}

# prv_gate <event> [action] — return 0 to proceed, 1 when this check does not apply to the current
# event. Callers write `prv_gate ... || exit 0`; errexit cannot fire inside that `||` list, so a
# gated-out check records `skip` and stops without ever reaching a verdict it was not triggered for.
prv_gate() {
  local want_event=$1 want_action=${2:-*}
  if [ "$GITHUB_EVENT_NAME" != "$want_event" ]; then
    prv_record skip "Not applicable: this check runs on the '$want_event' stream and this job was triggered by '$GITHUB_EVENT_NAME'."
    return 1
  fi
  if [ "$want_action" != '*' ] && [ "$GITHUB_EVENT_ACTION" != "$want_action" ]; then
    prv_record skip "Not applicable: this check runs on '$want_event' action '$want_action' and this job was triggered by '$GITHUB_EVENT_ACTION'."
    return 1
  fi
  return 0
}

# prv_actor_exempt <login> <csv> — return 0 when the pull request author is on the consumer's
# exemption list, 1 otherwise. Callers write `prv_actor_exempt ... && exit 0`, the inverse of
# prv_gate: here 0 means "exempt, stop", not "proceed". An exempt author records `skip` naming the
# login; a non-exempt one records nothing, so the check runs and records its own verdict exactly as
# prv_gate does for an inapplicable event. Never `pass`: a green tick would claim a validation that
# never happened.
prv_actor_exempt() {
  local entry target
  target=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  # Literal whole-string comparison, never a regex: an unanchored pattern would exempt
  # `robotics-team` for an entry of `bot`, and a list a reader cannot audit is a list nobody audits.
  # Both sides downcased, so the match is case-insensitive. An empty list exempts nobody: a blank
  # entry must never match an author whose login is somehow empty too.
  while IFS= read -r entry; do
    entry=$(printf '%s' "$entry" | tr '[:upper:]' '[:lower:]')
    if [ -n "$entry" ] && [ "$entry" = "$target" ]; then
      # The login is untrusted context, so it is escaped before it reaches the log line.
      prv_note "Exempt actor: '$(prv_escape "$1")' is listed in 'skip-actors', so this check did not run."
      prv_record skip "Exempt actor: the pull request author '$1' is listed in 'skip-actors', so this check was not run."
      return 0
    fi
  done <<< "$(prv_csv_lines "$2")"
  return 1
}

# prv_csv_lines <value> — a comma-separated input, one trimmed element per line.
# Empty input must emit nothing rather than one blank line, or `wc -l` and `jq -s` both count 1.
prv_csv_lines() {
  local out
  out=$(printf '%s' "$1" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d')
  [ -z "$out" ] || printf '%s\n' "$out"
}

# prv_allowed_labels <csv> — the same list as a JSON array, for `jq --argjson`.
prv_allowed_labels() {
  prv_csv_lines "$1" | jq -R . | jq -s .
}

# prv_human_list <csv> — the same list, comma-and-space separated, for a human message.
prv_human_list() {
  # `paste -sd,` then a substitute: a multi-character `-d` list would cycle its delimiters.
  prv_csv_lines "$1" | paste -sd, - | sed -e 's/,/, /g'
}

# prv_matched_type_labels — the pull request's labels that are in the configured type set, original
# casing, one per line. Matching is case-insensitive because GitHub label names are not. Read by
# `type-label` alone now: `pr-body-structure` resolves its template from the title's type instead, so
# the two vocabularies stay independent.
prv_matched_type_labels() {
  local allowed
  allowed=$(prv_allowed_labels "$INPUT_TYPE_LABELS")
  # Untrusted labels: one JSON array in, filtered by jq, never interpolated into this script.
  printf '%s' "$PR_LABELS" | jq -r --argjson allowed "$allowed" \
    '.[] | select((.name | ascii_downcase) as $n | $allowed | index($n)) | .name'
}

# prv_title_types — the Conventional Commit vocabulary: `title-types` when the consumer declares a
# second one, `type-labels` otherwise.
#
# The two are different sets on purpose, and one input cannot be both. Labels are what a repository
# actually creates, so a label set is coarse — a contributor picks the nearest of five. Titles follow
# Conventional Commits, so a title set is the twelve types, and release tooling parses the squashed
# subject. A consumer whose labels are `type/feature,type/bug,…` and whose templates are named
# `feat.md`, `fix.md`, … needs to declare both. Falling back to `type-labels` is what keeps every
# consumer that declares only one vocabulary behaving exactly as it did before.
prv_title_types() {
  if [ -n "${INPUT_TITLE_TYPES:-}" ]; then
    printf '%s' "$INPUT_TITLE_TYPES"
  else
    printf '%s' "${INPUT_TYPE_LABELS:-}"
  fi
}

# prv_title_type <title> — the Conventional Commit type of a subject, lowercased. Returns 1 when the
# title has no readable type.
#
# Deliberately lenient. This is not a grammar check: it reads the type out of a title so the caller
# can resolve a template, and a title it cannot read belongs to pr-title-conventional, which owns the
# grammar. Diagnosing it here as well would fail a pull request twice for one mistake.
prv_title_type() {
  local lower head
  lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case $lower in
    *:*) ;;
    *) return 1 ;;
  esac
  head=${lower%%:*}
  head=${head%!}
  case $head in
    *'('*) head=${head%%(*} ;;
  esac
  [ -n "$head" ] || return 1
  printf '%s\n' "$head"
}

# prv_valid_linear_identifier <value> — true for a Linear `TEAMKEY-N` identifier.
# This doubles as the guard that makes splicing the identifier into a JSON payload safe: nothing
# outside the class can carry a quote, a backslash or a control character.
prv_valid_linear_identifier() {
  printf '%s' "$1" | grep -qE '^[A-Za-z][A-Za-z0-9]*-[0-9]+$'
}
