#!/usr/bin/env bash
# Renders every check's verdict as a job-summary table, and is the only thing that fails the job.
# Each action invokes it as its final step.
#
# Shared by all four actions, so it takes its check list from the environment rather than holding one:
#   PRV_CHECKS   pipe-separated check names, in report order
#   PRV_LABELS   pipe-separated human labels, positionally parallel to PRV_CHECKS
#   PRV_TITLE    heading for the summary table
#   PRV_NOTE     optional advisory appended under the table
#   PRV_ACTION   optional key owning this action's sticky pull request comment, read by lib/comment.sh
# A check that recorded nothing is reported as `error`, never as a pass: an unexpected crash must not
# read as a clean run.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=lib/comment.sh
source "$(dirname "${BASH_SOURCE[0]}")/comment.sh"

checks_string=${PRV_CHECKS:-}
labels_string=${PRV_LABELS:-}

if [ -z "$checks_string" ]; then
  printf '::error title=Validation did not complete::PRV_CHECKS is empty, so this action does not know which checks to report. Nothing about the pull request is at fault. Fix: a workflow defect in the action; every step must pass its own check list to this report.\n'
  exit 1
fi

IFS='|' read -r -a CHECKS <<< "$checks_string"
IFS='|' read -r -a LABELS <<< "$labels_string"

if [ "${#CHECKS[@]}" -ne "${#LABELS[@]}" ]; then
  printf '::error title=Workflow defect in the action::%s check names but %s labels were passed to the report; they must be parallel.\n' "${#CHECKS[@]}" "${#LABELS[@]}"
  exit 1
fi

status_icon() {
  case $1 in
    pass) printf '✅' ;;
    fail) printf '❌' ;;
    skip) printf '⏭️' ;;
    *)    printf '🚨' ;;
  esac
}

rows=""
failures=0
skipped=0
errors=0

for i in "${!CHECKS[@]}"; do
  check=${CHECKS[$i]}
  status=error
  message='This check recorded no verdict. The check script exited unexpectedly before reporting.'

  if [ -f "$RESULTS_DIR/$check.status" ]; then
    status=$(cat "$RESULTS_DIR/$check.status")
    message=''
    [ -f "$RESULTS_DIR/$check.msg" ] && message=$(cat "$RESULTS_DIR/$check.msg")
  else
    errors=$((errors + 1))
    failures=$((failures + 1))
  fi

  case $status in
    fail) failures=$((failures + 1)) ;;
    skip) skipped=$((skipped + 1)) ;;
    pass) ;;
    *)
      if [ "$status" != 'error' ]; then
        message="Unrecognised status '$status' recorded by the check script for '$check'."
        errors=$((errors + 1))
        failures=$((failures + 1))
        status=error
      fi
      ;;
  esac

  # The detail is escaped before it reaches the table: a pull request body can contain a pipe, which
  # would otherwise add a spurious column.
  detail=${message//|/\\|}
  rows+="| $(status_icon "$status") | ${LABELS[$i]} | $detail |"$'\n'
done

summary=""
summary+="## ${PRV_TITLE:-Validation}"$'\n\n'
summary+="| | Check | Detail |"$'\n'
summary+="| --- | --- | --- |"$'\n'
summary+="$rows"

total=${#CHECKS[@]}
if [ "$failures" -eq 0 ]; then
  summary+=$'\n\n'"All $(( total - skipped - errors )) checks passed"
  if [ "$skipped" -gt 0 ]; then
    # Not one meaning any more: a check skips when the event does not apply, when it cannot reach a
    # verdict, and when the author is on the consumer's `skip-actors` list. Each row says which.
    summary+=" ($skipped skipped, not run for this pull request)"
  else
    summary+="."
  fi
  summary+=$'\n'
else
  summary+=$'\n\n'"**$failures of $total checks failed.** Fix every one of them and push once — this action reports all of its findings in a single run, so there is no need to discover them one push at a time."$'\n'
fi

if [ -n "${PRV_NOTE:-}" ]; then
  summary+=$'\n> [!NOTE]'$'\n'"$PRV_NOTE"$'\n'
fi

printf '%s' "$summary"
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$summary" >> "$GITHUB_STEP_SUMMARY"

# The same rendering, published to the pull request conversation, so the status is where the author is
# already looking. It cannot change the verdict, which is why it runs after the summary and why its
# own failures are warnings: the job summary above is the reporting this action guarantees, and a
# comment is an addition to it.
prv_publish_status_comment "$summary" || true

if [ "$failures" -eq 0 ]; then
  exit 0
fi

if [ "$errors" -gt 0 ]; then
  printf '::error title=Validation did not complete::%s check(s) recorded no verdict at all. The action is misconfigured or a check script crashed; the job summary lists which.\n' "$errors"
fi
printf '::error title=Contribution policy not satisfied::%s of %s checks failed. See the job summary table for which ones and why.\n' "$failures" "$total"
exit 1
