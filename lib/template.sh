#!/usr/bin/env bash
# The PR template resolution rule, in one place. Sourced, never executed.
#
# Two consumers share it, which is the reason it lives here rather than in either of them:
#   pull-request/pr-body-structure.sh  the PR policy's checks, which report a verdict
#   pull-request-template/resolve.sh          the standalone action, which reports step outputs
# The rule and its failure modes are the same for both; only the reporting contract differs.

# prv_template_ref <explicit> <base_sha> <event_sha> — the ref to read templates at.
#
# The order is the safety property, not a preference. On a fork `pull_request`, the base sha is a
# commit in the base repository that the fork author cannot move, while the event sha is the pull
# request head and is therefore attacker-controlled. The base sha is preferred so an unconfigured
# call cannot be redirected to a template the author wrote. Outside a pull request the base sha is
# empty and the event sha is used, which on `issues` and `push` is the base branch tip.
prv_template_ref() {
  if [ -n "$1" ]; then printf '%s' "$1"
  elif [ -n "$2" ]; then printf '%s' "$2"
  else printf '%s' "$3"
  fi
}

# prv_template_fetch <repo> <path> <ref> <dest> — download one template. Returns 1 when absent.
#
# Read through the contents API, never `actions/checkout`: the caller holds a token, and checking out
# a pull request would put untrusted fork code on the runner.
prv_template_fetch() {
  gh api -H 'Accept: application/vnd.github.raw+json' \
    "repos/$1/contents/$2?ref=$3" > "$4" 2>/dev/null
}

# prv_template_resolve <type> <template_dir> <default_template> <repo> <ref> <dest>
#
# Sets PRV_TEMPLATE_PATH and PRV_TEMPLATE_SOURCE. A dedicated `<dir>/<type>.md` wins; when it does
# not exist the default template is used. A type therefore needs no entry anywhere, and adding one
# file to the template directory is all it takes to give a type its own sections.
#
# Return codes, so each consumer can report the failure in its own words:
#   0  resolved; PRV_TEMPLATE_PATH and PRV_TEMPLATE_SOURCE are set
#   1  neither the dedicated nor the default template could be read
#   2  the type is not usable as a path segment
# The two PRV_TEMPLATE_* variables are the function's output contract, read by both consumers after
# it returns. ShellCheck sees them assigned and never read inside this file, which is exactly what a
# sourced module's interface looks like, so the warning is silenced here rather than at six sites.
# shellcheck disable=SC2034
prv_template_resolve() {
  local type=$1 template_dir=$2 default_template=$3 repo=$4 ref=$5 dest=$6

  # A type becomes a URL path segment, so refuse anything that could escape the directory. Callers
  # also rely on this being the JSON-safety precondition for any later use of the value.
  if ! printf '%s' "$type" | grep -qE '^[A-Za-z0-9._-]+$'; then
    return 2
  fi

  local lower
  lower=$(printf '%s' "$type" | tr '[:upper:]' '[:lower:]')

  local dedicated="$template_dir/$lower.md"
  if prv_template_fetch "$repo" "$dedicated" "$ref" "$dest"; then
    PRV_TEMPLATE_PATH=$dedicated
    PRV_TEMPLATE_SOURCE=dedicated
    return 0
  fi

  if prv_template_fetch "$repo" "$default_template" "$ref" "$dest"; then
    PRV_TEMPLATE_PATH=$default_template
    PRV_TEMPLATE_SOURCE=default
    return 0
  fi

  # Reported so a caller can name the default, which is the path that was actually tried last.
  PRV_TEMPLATE_PATH=$default_template
  PRV_TEMPLATE_SOURCE=none
  return 1
}
