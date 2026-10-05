# ailuracollective/actions

A hub of small GitHub Actions that enforce a contribution policy. Process gates, not CI: they read a
pull request's metadata and its linked issues, and they never check out or run the code under review.

## The actions

| Action | What it does | Adopt with |
| --- | --- | --- |
| **Branch validation** | Requires the head branch to read `<author>/<type>/<description>` and to be owned by the PR author | `ailuracollective/actions/branch-validation@v1` |
| **Pull request policy** | Linked issue (GitHub `#N` or Linear `TEAMKEY-N`), type label, title shape and length, description structure | `ailuracollective/actions/pull-request@v1` |
| **Issue triage** | Applies a triage label to newly opened issues | `ailuracollective/actions/triage@v1` |
| **Pull request template resolver** | Resolves a type's PR template and reports it through outputs, for use in a job of your own | `ailuracollective/actions/pull-request-template@v1` |

The root `action.yml` is not in that table because it is not an action. It is the index the four are
listed under, and adopting it by mistake fails on purpose: a consumer who writes
`ailuracollective/actions@v1` gets a failed run naming all four paths above.

They are separate because they answer different questions and need different permissions. Branch
naming needs no token at all. The PR policy needs `pull-requests: read` and `contents: read`. Issue
triage needs `issues: write` — the only one, and the only one that cannot work on a pull request from
a fork, because a fork event carries no secrets. A consumer that only wants branch naming should not
have to grant the others.

### One Marketplace listing

GitHub builds at most one listing per repository, and only from an `action.yml` at the repository
root. The root manifest here is that listing: its `name`, **Contribution policy**, is the title the
repository appears under, and the four actions keep their own paths underneath it. The listing is an
index, not a fifth action — it declares no inputs, runs no check, and needs no token.

Adopting it by mistake fails loudly, on purpose. `ailuracollective/actions@v1` resolves to the
index, the single step errors, and the job fails naming `branch-validation`, `pull-request`,
`triage` and `pull-request-template`. A green run there would have claimed a validation that never
happened.

## Versioning

This repository holds several actions, and a git tag versions the **whole repository**, so every
action in it moves version together. There is no per-action version.

`v1` is the moving major line. It carries the root index and all four directory actions, and every
one of them resolves at `@v1` today. A change that breaks a consumer — the move of branch validation
out of the repository root was one — moves the whole repository to a new major rather than shipping
under `v1`.

Two refs, and they do different jobs. This repository publishes the moving major line, not
patch-level tags:

| Ref | What it is | Use it when |
| --- | --- | --- |
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
      - uses: ailuracollective/actions/branch-validation@v1
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
| `pr-title-conventional` | `<type>(<scope>)!: <description>`, case-insensitive, with `<type>` from `title-types` | `enable-title-conventional` |
| `pr-body-structure` | Every `## ` heading declared by the title type's template | `enable-body-structure` |

Every failure names the check, what is wrong, and the exact fix.

### One status, every finding

All five checks produce **one** GitHub check status. That is the price of a composite action, and
three properties make it workable.

**Every check runs, then the job fails.** A failing check does not stop the others, so the author sees
every defect in one run and fixes them in one push instead of discovering one per push.

**The job summary is a table.** Each run writes all five verdicts to the workflow run's job summary.

**`skipped` is reported as skipped.** `pr-body-structure` cannot resolve a template when the title
names no allowed type. It reports `skipped` and names `pr-title-conventional` as the owner, rather
than a green tick for a validation that never happened. The closing line of the summary reads
`All N checks passed (M skipped, not run for this pull request)`: a skip is counted as a
non-failure, so a required status is still satisfied, but it is never folded into the passed count.

### Two vocabularies, two inputs

Labels and titles are different sets, and one input cannot be both:

| | Vocabulary | Size | Read by |
| --- | --- | --- | --- |
| `type-labels` | What the repository actually creates. A contributor picks the nearest of a coarse family. | 5 in this organisation | `type-label` |
| `title-types` | Conventional Commits, which release tooling parses out of the squashed subject. | 12 | `pr-title-conventional`, `pr-body-structure` |

`title-types` defaults to `type-labels`, so a consumer that uses one vocabulary for both declares
nothing extra. Declare the second input only when they differ:

```yaml
      - uses: ailuracollective/actions/pull-request@v1
        with:
          type-labels: type/feature,type/bug,type/documentation,type/improvement,type/task
          title-types: feat,fix,docs,chore,style,refactor,perf,test,build,ci,revert,breaking-change
```

With that set, a pull request titled `fix: …` and labelled `type/bug` passes both checks and is
measured against `.github/PULL_REQUEST_TEMPLATE/fix.md`. Before `title-types` existed the two checks
could not both be satisfied: a label set of `type/bug` left the title grammar demanding a literal
`type/bug:` subject, and a label set of `fix` left the label check unsatisfiable on any repository
that does not carry a label named `fix`.

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

The **title's type** resolves to a template by one rule, with no lookup table to maintain:

1. `<template-dir>/<type>.md`, if it exists
2. otherwise `default-template`

Adding a template file is all it takes to give a type its own required sections. The type is read from
the title rather than from a label, which is what lets the two vocabularies differ and what keeps this
check independent of `type-label`: when a title's type is not allowed, that is the grammar check's
failure, and when a type cannot be used as a file name that is a workflow defect reported as one. Types
are validated as path segments before being joined into a path, so a misconfigured `title-types` input
is reported rather than escaping the template directory. The template is read from the **base** branch
through the contents API, and the action never runs `actions/checkout`: a job holding a token must not
put untrusted fork code on the runner.

### Exempt actors

`dependabot[bot]` is the case that forces this. Its branches read
`dependabot/npm_and_yarn/pkg-1.2.3`, and two independent rules reject them: the type segment
`npm_and_yarn` is not in `branch-types`, and the ownership rule compares the branch's first segment
(`dependabot`) with the author login (`dependabot[bot]`), which can never be equal. Dependabot's
configurable `pull-request-branch-name.prefix` fixes neither the missing type segment nor the
comparison, so the mechanism is an explicit list:

```yaml
      - uses: ailuracollective/actions/pull-request@v1
        with:
          skip-actors: dependabot[bot]
          type-labels: feat,fix,chore,breaking-change
```

Both the branch validation and the PR policy actions take `skip-actors`, and the default is empty:
nobody loses validation without opting in.

- **The match is literal, whole-string and case-insensitive.** `dependabot` matches
  `dependabot[bot]` and nothing else — not `dependabot-malicious-fork`, and not `robotics-team` when
  you write `bot`. Entries are never patterns: a list you cannot read and verify is a list nobody
  verifies, and a substring rule is the one mistake that silently exempts the wrong pull requests.
  The tested identity is the **pull request author** (`github.event.pull_request.user.login`), not
  the actor that triggered the event.
- **An exemption is a `skip`, never a `pass`.** The check did not run, so it must not render a green
  tick. The row names the exempt login, so the bypass is visible in the run's audit trail, and
  `lib/report.sh` counts a skip as a non-failure — a required status stays satisfied.
- **The exemption covers the whole action, not one check.** A Dependabot pull request fails the
  linked-issue and type-label gates too, and per-check toggles are configuration nobody gets right.
  The event gate is still evaluated first, so a check that does not run reports its own
  not-applicable skip.
- **Keep the list short and reviewed.** Whoever can edit the workflow can also remove the action
  entirely, so the list is not a security boundary against a maintainer — it is a record of which
  automated accounts you chose to stop validating. Every entry is a policy decision, not a
  convenience.

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

Every check runs against the stubbed `gh`, `curl` and `jq` in `tests/stubs/`, with no network, no token and
no runner. The stubs live in `tests/stubs/` and are driven entirely by env vars. The suite discovers
every action in the repository, so it grows as the hub does.

The assertion count is deliberately not written down. A number in this sentence is wrong the moment a
script is added, and a test suite that documents a stale count of itself is a small lie that
everybody stops reading. `bash tests/run-checks.sh` prints the real one.

```
action.yml                      the index: the one Marketplace listing for the four actions below
branch-validation/action.yml        branch validation, one check
branch-validation/branch-name.sh    its entry point, beside its own manifest
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
.shellcheckrc                  source resolution, so the shared modules are analysed
.yamllint.yml                  the two YAML rules this repository's content cannot satisfy
```

An action's exclusive scripts live in the action's own directory, beside its `action.yml`. The
repository root holds only the index manifest, what is shared — `lib/` — plus one directory per
action. There is no `scripts/` container, the root is the listing rather than an action, and none of
the four directories is more principal than another.

A check and an action can need the same rule without either importing the other's reporting contract,
so a shared rule goes in `lib/` and both source it. What may not be duplicated is the rule, the
path-traversal guard, or the ref chain.

### The four layers of testing

The suite above is the first layer and the cheapest. It is not sufficient on its own, because a
shell suite cannot see a composite action, and the failure mode of trusting only it is a rule that is
correct in isolation and never runs.

| Layer | What it is | What it can catch |
| --- | --- | --- |
| Offline suite | `bash tests/run-checks.sh`, no network | The rules themselves: parsers, the path guard, the ref chain, verdict recording |
| Static analysis | `.github/workflows/checks.yml` runs shellcheck, yamllint and actionlint | Quoting and expansion mistakes, manifest shape, workflow expression and context errors |
| Self-validation | `.github/workflows/self-validation.yml` runs these actions, by directory path, against real pull requests | Everything the first two cannot: a composite action that fails to resolve, a missing `permissions` grant, an event that never reaches the check, a stub that disagrees with the real API |
| Release smoke | Not automated | Whether the published tag still works, which a directory path by definition never tests |

The split between layer 1 and layer 3 is the one that matters. A directory path means the pull
request is validated by the code the pull request contains, so a change that breaks the policy fails
its own run — that is the signal, and it is why layer 3 uses `./<name>` and not `@v1`. The cost is
that the published tag is untested by it, which is what the fourth layer is for. Run the smoke test
after a release: open a pull request, let it fail on purpose, and read the message as the author who
will receive it. Nothing in the suite checks whether a failure message is useful to a human.

Two deliberate asymmetries:

- **Fork pull requests are skipped by layer 3.** A directory path needs the head on the runner, and
  the policy holds a token while it runs — the combination the action's own README forbids for forks.
  The `if` is at workflow level so all three jobs agree.
- **The three linters are pinned by version and digest**, not taken from the runner image. A required
  status that changes verdict when GitHub ships a new image is a status nobody trusts.

To set the labels layer 3 depends on, run the **Bootstrap labels** workflow once. The policy reads
labels by name and cannot create one, so a fresh repository starts unable to pass `linked-issue`.

### Adding an action

The harness **discovers** actions rather than listing them, so a new action needs no test edits: the
suite finds every `action.yml` in any directory beside the root — the root manifest included — parses
it, and checks that
each step declares `run` and `shell: bash`, that every script a step invokes exists, that every
reporting action's check steps declare `continue-on-error`, that every module in `lib/` is
actually used, and that the root manifest declares no inputs and invokes no script. A new directory
that breaks any of those fails the suite.

The root is reserved for the index. A new action goes in its own directory and never in the root:
a fifth manifest there would be a second action competing with the listing, and the harness would
reject any root manifest that grows an input or a check step.

**1. `<name>/action.yml`.** A composite action, same shape as any other here. Put the directory at the
repository root, not under an `actions/` folder: the path in `uses:` is the directory path within the
repository, so `actions/<name>/` would make consumers write the doubled
`ailuracollective/actions/actions/<name>@v1`.

**2. `<name>/<verb>.sh`.** The entry point, one per check if it has several:

```bash
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../lib/common.sh
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
