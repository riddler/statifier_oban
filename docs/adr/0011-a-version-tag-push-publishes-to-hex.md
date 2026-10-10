# ADR-0011: A version tag push publishes to Hex, through a release workflow

Status: accepted (2026-10-10, statifier_oban 0.17.1)

## Context

A release of this package has four steps. Three of them are already the
automation's: the version bump and the changelog promotion land as a release
prep (`.claude/wurk/release.md`), and once the prep is merged to the default
branch the conductor or the session that owns the release bead tags the merged
commit and pushes the tag (`CLAUDE.md`, the authority table's "tagging a
release prep" row and its "Release preps" paragraph). The fourth, the publish
to Hex, was a person running `mix hex.publish` by hand from a checkout: at
45a84cb the table's release row reads "never" for an agent and "always -
publishing is the operator's, in every campaign", and the "Release preps"
paragraph calls the publish "the operator's one release step".

A hand publish depends on whoever runs it checking what a machine can check:
that the tag sits on the default branch, that it names the version `mix.exs`
states at that commit, and that the gate is green there. It also waits on a
person being at a keyboard after the tag is already public. CI already runs
the gate on every push to the default branch
(`.github/workflows/ci.yml` at 45a84cb, its "Full quality gate" step), so
everything the publish needs except the Hex key is already in the repository.

The operator ruled on 2026-10-04 that the publish moves to a workflow started
by the tag push, and that no agent or session ever holds the key or runs the
publish command.

## Decision

**1. A pushed version tag starts the release workflow, and nothing else
does.** `.github/workflows/release.yml` triggers on a push of a tag matching
`v*.*.*` and on no other event: no branch push, no pull request, and no
manual dispatch (decided by the conductor under a standing consent,
2026-10-03). Its token is read-only (`permissions: contents: read`). One run
per tag, keyed by the tag ref, and a run in progress is never cancelled.

**2. Three conditions at the tagged commit, checked before anything is
built.** The workflow publishes only when all three hold:

- the tagged commit is on the default branch: the branch is named by the push
  event itself (`github.event.repository.default_branch`), never written in
  the file, fetched, and asked with `git merge-base --is-ancestor` (the step
  "Check the tagged commit is on the default branch");
- the tag without its leading `v` equals `@version` in `mix.exs` at the
  tagged commit (the step "Check the tag names the version in mix.exs");
- the full quality gate is green at the tagged commit (decision 3).

The first two stop the run before any toolchain is installed (decided by the
conductor under a standing consent, 2026-10-03). A fourth check sits beside
them: a version Hex already shows stops the run with a report, before the
toolchain, and is never published again (the step "Check Hex does not already
show this version"; decided by the conductor under a standing consent,
2026-10-04).

**3. The workflow runs the gate itself, provisioned exactly as CI is.** The
toolchain, the dependency cache, the dependency fetch and the gate step are
copied from `ci.yml` unchanged, so the gate is the command `gate.full` in
`.claude/wurk.json` names (today `mix quality`), read in the step as CI reads
it (decided by the conductor under a standing consent, 2026-10-03). The
workflow does not look up CI's result on the commit; it runs the gate on the
tagged commit and a red gate publishes nothing.

**4. The registry is Hex, and the key is a secret by name only.** The publish
step runs `mix hex.publish --yes` with `HEX_API_KEY` set from the
`HEX_API_KEY` secret (an organisation secret scoped to this repository; ruled
by the operator, 2026-10-04) in that one step's environment and nowhere else.
Hex reads `HEX_API_KEY` in place of a logged-in user. The key is created,
stored, rotated and revoked by the operator outside the repository; no agent
or session reads, writes or holds it. The last step prints the address of the
published version on hex.pm and on HexDocs.

**5. The docs publish with the package.** `mix hex.publish --yes` builds and
publishes the documentation with the package, as by default, so HexDocs keeps
every version's docs (decided by the conductor under a standing consent,
2026-10-04). The package-only form is not used.

**6. A failed run publishes nothing, and the workflow never retries.** A run
that stops at a check or at the gate publishes nothing, and the tag stands as
the record of what was attempted: the fix lands on the default branch and the
next version is tagged; a tag is never moved or pushed again. A run whose
publish step failed on a registry or network error is re-run once, by hand,
from the run's page in the Actions tab; a gate that failed is never re-run,
and a second failure of the publish step is the operator's. A version Hex
already shows is reported, never published again (decision 2). A local
publish is never the way round a failed run. (Decided by the conductor under
a standing consent, 2026-10-04.)

**7. A published version stands.** Hex lets an existing package's new version
be replaced or reverted only within one hour of its publication; after that
the version can only be retired, which marks it and leaves it installable.
Neither replace nor revert is run by an agent or a session, so a version the
workflow publishes is, for this repository, permanent.

## Consequences

- The authority table's release row and the version-bump row, the "Release
  preps" paragraph and `.claude/wurk/release.md` say the same thing: an agent
  or a session never runs `mix hex.publish`; the release workflow publishes on
  the tag push the tagging row already allows; a failed workflow is re-run from
  its Actions page, never worked round by a local publish (ruled by the
  operator, 2026-10-04).
- Pushing a version tag is now the act that publishes. The tagging row's
  conditions (the bump merged to the default branch, the tag naming that
  version at the merged commit) are what decision 2 re-checks, so a tag pushed
  outside them stops before the gate.
- Each release costs one more gate run, on the runner, after the tag push.
- The workflow's own steps are not exercised by the gate or by CI; the first
  tag push after this record is the first run of everything after the checks.
- The toolchain steps are a copy: a change to `ci.yml`'s toolchain or gate
  steps is made in `release.yml` in the same change.
- This record stays proposed until a version of this package has been
  published through the workflow.

## Note (2026-10-10): accepted, the workflow first published 0.17.1

The first version of this package published through the release workflow
is 0.17.1: tag `v0.17.1` at `97513dd`, workflow run
https://github.com/riddler/statifier_oban/actions/runs/37310196157, every
step of it green on its first attempt, the publish step included. The
workflow has published once more since, also on its first attempt: 0.17.2,
tag `v0.17.2` at `7e72408`, workflow run
https://github.com/riddler/statifier_oban/actions/runs/37743115234. Hex
and HexDocs both show 0.17.1 and 0.17.2. That first publish is the
evidence that flips this record, ruled by the operator, 2026-10-06; the
Status line names the first version so published (decided by the
conductor under a standing consent, 2026-10-10). The status line at the
top flips in place from proposed to accepted, and the ADR index row with
it; no other line of the record changes. The last Consequences bullet,
"This record stays proposed until a version of this package has been
published through the workflow", is met by 0.17.1 and stays as written.

Every claim was read at `7e72408`, which is both the `v0.17.2` tag and
`main` on the day of the flip. Since `v0.17.1`, two commits have reached
`main` (`3d02205`, the upgrading page, and `7e72408`, the 0.17.2 release
prep); neither touches `.github/workflows/`, `CLAUDE.md` or
`.claude/wurk/release.md`. In `mix.exs` the first adds a docs extra and
the second moves `@version` to `0.17.2`, still the single attribute
decision 2's version check reads.

- Context: at `45a84cb` the authority table's release row read "never"
  and "always - publishing is the operator's, in every campaign", and the
  "Release preps" paragraph called the publish "the operator's one release
  step"; `ci.yml` there had its "Full quality gate" step.
- Decision 1: `.github/workflows/release.yml` triggers on `push` of tags
  matching `v*.*.*` and on no other event; `permissions: contents: read`;
  its concurrency group is `release-${{ github.ref }}` with
  `cancel-in-progress: false`.
- Decision 2: the steps "Check the tagged commit is on the default branch"
  (the branch read from `github.event.repository.default_branch`, fetched,
  then `git merge-base --is-ancestor`), "Check the tag names the version in
  mix.exs" and "Check Hex does not already show this version" all run
  before "Read the toolchain out of mise.toml".
- Decision 3: the toolchain, cache, dependency fetch and "Full quality
  gate" steps of `release.yml` match those of `ci.yml` line for line, and
  the gate step reads `gate.full` from `.claude/wurk.json` (today `mix
  quality`); nothing in the workflow reads CI's result.
- Decision 4: the "Publish to Hex" step runs `mix hex.publish --yes` with
  `HEX_API_KEY` from the secret of that name in that step's `env` alone; a
  secret named `HEX_API_KEY` is an organisation secret available to this
  repository (its name read, never its value); the last step prints the
  hex.pm and HexDocs addresses.
- Decision 5: the publish command carries no package-only flag, and
  HexDocs serves the docs of both published versions.
- Decision 6: the workflow has no retry or re-run step, and both runs
  succeeded on attempt 1.
- Decision 7 restates Hex's own replace and revert window, which nothing
  in this repository changes.
- The Consequences: `CLAUDE.md`'s version-bump row, release row and
  "Release preps" paragraph, and `.claude/wurk/release.md`, between them
  say an agent or a session never runs `mix hex.publish`, the workflow
  publishes on the tag push, and a failed workflow is re-run from its
  Actions page, never worked round by a local publish; each says the
  first two, and the release row, the paragraph and `release.md` say the
  third.
