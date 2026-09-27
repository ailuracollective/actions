# ailuracollective/actions

A hub of small GitHub Actions that enforce a contribution policy. Process gates, not CI: they read a
pull request's metadata and its linked issues, and they never check out or run the code under review.

## The actions

| Action | What it does | Adopt with |
| --- | --- | --- |
| **Branch validation** | Requires the head branch to read `<author>/<type>/<description>` and to be owned by the PR author | `ailuracollective/actions@v1` |
| **Pull request policy** | Linked issue (GitHub `#N` or Linear `TEAMKEY-N`), type label, title shape and length, description structure | `ailuracollective/actions/pull-request@v1` |
| **Issue triage** | Applies a triage label to newly opened issues | `ailuracollective/actions/triage@v1` |
| **Pull request template resolver** | Resolves a type's PR template and reports it through outputs, for use in a job of your own | `ailuracollective/actions/pull-request-template@v1` |

They are separate because they answer different questions and need different permissions. Branch
naming needs no token at all. The PR policy needs `pull-requests: read` and `contents: read`. Issue
triage needs `issues: write` — the only one, and the only one that cannot work on a pull request from
a fork, because a fork event carries no secrets. A consumer that only wants branch naming should not
have to grant the others.

### One Marketplace listing

GitHub allows one listing per repository and builds it from the root `action.yml`. Actions in
sub-directories are fully supported and consumed by path, but never get a listing:

> Each repository must contain a single action metadata file (`action.yml` or `action.yaml`) at the
> root. Repositories may include other actions metadata files in sub-folders, but they will not be
> automatically listed in the marketplace.

So the root `name` titles the listing for all four actions — it is `Contribution policy`, not the name
of the one action that happens to sit at the root. The listing body is this README, and a `name`
change is expected to mint a new listing and retire the old slug, so it is worth choosing before
consumers arrive. Runtime titles are unaffected: a run still says *Branch validation*, because
`PRV_TITLE` names the action that ran.

## Versioning

This repository holds several actions, and a git tag versions the **whole repository**, so every
action in it moves version together. There is no per-action version.

Two refs, and they do different jobs:

| Ref | What it is | Use it when |
| --- | --- | --- |
| `v1.0.0` | An immutable release | You want reproducibility and will upgrade deliberately |
| `v1` | A floating alias meaning **"the latest 1.\*"** | You want security and critical fixes without touching your workflow |
| `89420d0…` | A commit SHA | You want the only truly immutable ref GitHub offers |

This follows GitHub's own guidance for actions: binding to a major version receives fixes while
staying compatible, and a major version must guarantee compatibility. A change that breaks a consumer
bumps the whole repository to `v2`, never silently under `v1`.

Prefer the SHA. GitHub documents a full commit SHA as *"the only way to use an action as an
immutable release"*, because a tag can be moved or deleted by anyone who compromises this repository,
and organization policies can require SHA pinning. A floating `v1` is the convenient option, not the
safe one.

Never reference a branch. A branch ref means anyone with push access decides what runs on your pull
requests.

Independent per-action versioning would need real tooling and namespaced tags; it is not worth it
while the actions ship together. See [When to stop and split](#when-to-stop-and-split) for the point
at which that changes.

## Branch validation

```yaml
jobs:
  branch-validation:
    runs-on: ubuntu-latest
    permissions: {}
    steps:
      - uses: ailuracollective/actions@v1
        with:
          branch-types: feat,fix,chore
```

`permissions: {}` is correct and worth keeping: this check reads nothing from the API.

It runs on `opened` only. GitHub cannot rename a branch an open pull request points at, so
`head.ref` is fixed for the life of the pull request, and re-validating it on every event would spend
runner minutes re-deriving a fact that cannot have changed.

## Pull request policy

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened, edited, labeled, unlabeled]

jobs:
  pr-policy:
    runs-on: ubuntu-latest
    # One token serves all five checks, so least privilege is a single block.
    permissions:
      pull-requests: read
      contents: read
    steps:
      - uses: ailuracollective/actions/pull-request@v1
        with:
          title-max: 80
          type-labels: feat,fix,chore,breaking-change
          enable-title-length: false
```

### Checks

| Check | Requires | Disable with |
| --- | --- | --- |
| `linked-issue` | A `Closes`/`Fixes`/`Resolves` pointing at an issue carrying the approved label, in GitHub or Linear | `enable-linked-issue` |
| `type-label` | Exactly one label from `type-labels` | `enable-type-label` |
| `pr-title-length` | `title-min`–`title-max` characters, counted as characters | `enable-title-length` |
| `pr-title-conventional` | `<type>(<scope>)!: <description>`, case-insensitive | `enable-title-conventional` |
| `pr-body-structure` | Every `## ` heading declared by the type's template | `enable-body-structure` |

Every failure names the check, what is wrong, and the exact fix.

### One status, every finding

All five checks produce **one** GitHub check status. That is the price of a composite action, and
three properties make it workable.

**Every check runs, then the job fails.** A failing check does not stop the others, so the author sees
every defect in one run and fixes them in one push instead of discovering one per push.

**The job summary is a table.** Each run writes all five verdicts to the workflow run's job summary.

**`skipped` is reported as skipped.** `pr-body-structure` cannot resolve a template when the pull
request carries zero or several type labels. It reports `skipped` and names `type-label` as the
owner, rather than a green tick for a validation that never happened.

### Linked issues, in GitHub or Linear

The shape of the reference picks the source: `#N` is GitHub, `TEAMKEY-N` is Linear. Both require a
closing keyword, so a stray identifier pasted out of a log never satisfies the gate. Linear is **off
by default**.

```yaml
      - uses: ailuracollective/actions/pull-request@v1
        with:
          linked-issue-sources: github,linear
          linear-approved-label: approved
        env:
          LINEAR_API_KEY: ${{ secrets.LINEAR_API_KEY }}
```

The key is a secret passed through `env:`, not a `with:` input, because a `with:` value is rendered
into the step's command. `linear-approved-label` works exactly like `approved-label`: the issue must
carry it, and a maintainer applies it during triage.

- **`TEAMKEY-N` is not actually closed by the keyword.** GitHub closes `#N` on merge; it has no idea
  what a Linear issue is. The keyword is still required so the gate reads the same in both worlds.
- **A missing key is a failure, not a skip**, reported as a configuration defect naming the secret. A
  `pull_request` from a fork never receives secrets, so fork pull requests cannot be validated this
  way — the message says so rather than leaving a bare auth error. The gate is strongest against pull
  requests opened from branches, and only advisory against forks.
- **A rejected key is distinguished from an unreachable network.** An HTTP 400/401/403 reports the
  key as invalid, expired, or lacking access to that team; a transport failure names the host.

### Template resolution

A type label resolves to a template by one rule, with no lookup table to maintain:

1. `<template-dir>/<type>.md`, if it exists
2. otherwise `default-template`

Adding a template file is all it takes to give a type its own required sections. Type labels are
validated as path segments before being joined into a path, so a misconfigured `type-labels` input is
reported as a workflow defect rather than escaping the template directory. The template is read from
the **base** branch through the contents API, and the action never runs `actions/checkout`: a job
holding a token must not put untrusted fork code on the runner.

## Issue triage

```yaml
on:
  issues:
    types: [opened]

jobs:
  triage:
    runs-on: ubuntu-latest
    permissions:
      issues: write
    steps:
      - uses: ailuracollective/actions/triage@v1
        with:
          auto-label-name: status:needs-review
```

`--add-label` is a no-op when the label is present, so this never duplicates it. Nothing removes it,
so a deliberate maintainer removal sticks. A missing label on the remote repository is a warning, not
a failure — but a refused token is reported as a configuration defect naming the `issues: write`
grant, because that is the mistake consumers actually make.

## PR template resolver

For consumers who want template resolution inside a job of their own, rather than the whole policy
gate.

```yaml
- uses: ailuracollective/actions/pull-request-template@v1
  id: tpl
  with:
    type: feat
- run: echo "sections come from ${{ steps.tpl.outputs.path }}"
```

Outputs: `path`, `source` (`dedicated`, `default`, or `none` when nothing was read), `found`, `ref`,
`file`. A missing template is a `::warning::` with `found=false` by default; set `fail-on-missing:
true` for a hard failure. See [its README](pull-request-template/README.md) for the ref fallback chain and why
it shares code with the PR policy instead of duplicating it.

## Working on this hub

```bash
bash tests/run-checks.sh
```

157 assertions run every check against stubbed `gh`, `curl` and `jq`, with no network, no token and
no runner. The stubs live in `tests/stubs/` and are driven entirely by env vars. The suite discovers
every action in the repository, so it grows as the hub does.

```
action.yml                     the flagship: branch validation
branch-name.sh                 its entry point, beside its own manifest
lib/common.sh                  shared module: result recording, event gating, escaping, parsers
lib/template.sh                shared module: the template resolution rule
lib/report.sh                  shared module: the job-summary table and the aggregated exit
pull-request/action.yml        PR policy, five checks
pull-request/<check>.sh        its entry points
triage/action.yml              issue triage
triage/auto-label.sh           its entry point
pull-request-template/action.yml         the standalone resolver
pull-request-template/resolve.sh         its entry point
tests/run-checks.sh            the harness; discovers every action
tests/stubs/                   offline stand-ins
```

An action's exclusive scripts live in the action's own directory, beside its `action.yml`. The
repository root holds only what is shared — `lib/` — plus each action's manifest and its own scripts.
The flagship is the root, so its check sits at the root next to its `action.yml`, the same position a
directory action's check occupies inside its directory. There is no `scripts/` container.

A check and an action can need the same rule without either importing the other's reporting contract,
so a shared rule goes in `lib/` and both source it. What may not be duplicated is the rule, the
path-traversal guard, or the ref chain.

### Adding an action

The harness **discovers** actions rather than listing them, so a new action needs no test edits: the
suite finds every `action.yml` at the root and in any directory beside it, parses it, and checks that
each step declares `run` and `shell: bash`, that every script a step invokes exists, that every
reporting action's check steps declare `continue-on-error`, and that every module in `lib/` is
actually used. A new directory that breaks any of those fails the suite.

**1. `<name>/action.yml`.** A composite action, same shape as any other here. Put the directory at the
repository root, not under an `actions/` folder: the path in `uses:` is the directory path within the
repository, so `actions/<name>/` would make consumers write the doubled
`ailuracollective/actions/actions/<name>@v1`.

**2. `<name>/<verb>.sh`.** The entry point, one per check if it has several:

```bash
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

prv_init my-check
prv_gate 'pull_request' || exit 0
prv_escape "${INPUT_THING}"   # untrusted input is read quoted, and escaped before any command
prv_record pass 'looks good'
```

One `../` hop, because an action's directory is a sibling of `lib/`. Invoke it as
`bash ${{ github.action_path }}/my-check.sh`, not as a bare path, so a consumer who lost the
executable bit on a clone or a zip download does not get a failure they cannot diagnose.

**3. A report step**, unless the action is a single step with nothing to aggregate:

```yaml
    - name: Report
      if: always()
      shell: bash
      env:
        RESULTS_DIR: ${{ runner.temp }}/prv-results
        GITHUB_STEP_SUMMARY: ${{ env.GITHUB_STEP_SUMMARY }}
        PRV_TITLE: 'My action'
        PRV_CHECKS: 'my-check|my-other-check'
        PRV_LABELS: 'My check|My other check'
      run: bash ${{ github.action_path }}/../lib/report.sh
```

**4. `<name>/README.md`.** Usage, outputs, and what the action does *not* do.

**5. Tests.** A group in `tests/run-checks.sh` exercising the entry point against the stubs. The
manifest, syntax and discovery checks come for free.

### Conventions

- Untrusted pull request input reaches a script only through `env:`, is always read quoted, and is
  never spliced into script text.
- A Linear identifier from a pull request body travels as a GraphQL **variable**, never inside the
  query text, and is shape-checked before it is placed in the JSON payload.
- User-controlled text in a workflow command is percent-escaped, and `%` is escaped first.
- **No check script exits non-zero to signal failure.** Each records a verdict and exits 0; only
  `lib/report.sh` fails the job, which is what makes aggregation possible.
- A check that records nothing is reported as `error`, never as a pass.
- Every script uses `set -euo pipefail`.
- Comments are one line, and only where a competent editor would otherwise get it wrong: security
  invariants, non-obvious footguns, and facts not derivable from the code.

### Two costs of the hub, stated plainly

**Tags are repository-wide.** A git tag versions the whole repository, so every action in it moves
version together. You cannot ship a breaking change to one action without moving the others. If the
actions start releasing at genuinely different cadences, that becomes the bottleneck and the answer
is separate repositories, not a better tag scheme.

**An action that reads `lib/` is not extractable.** `pull-request-template` depends on `lib/` at the repository
root, so copying `pull-request-template/` into another repository does not work. It works here because a tag
download brings the whole repository. The alternative is inlining a second copy, which is what this
layout deliberately removed: an inlined copy cannot be tested against the same fixtures as the one it
duplicates.

### When to stop and split

- **Actions release at different cadences.** The shared tag starts forcing artificial releases.
- **One action needs permissions another must not have.** They cannot share a caller's single token
  block, and least-privilege guidance stops being expressible. Triage and the PR policy are separated
  for exactly this reason, and they are still in one repository because that cost is only paid when a
  consumer adopts both.

Neither is true today.
