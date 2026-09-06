# Statifier_oban extension: /wurk:commit

Additional required steps and project facts. Adds only - see
`~/.claude/skills/wurk:commit/SKILL.md` for everything this does not repeat.

## Authority: consent-scoped, and the gate is the whole check

The trigger for `git commit` is the authority table in this repo's
`CLAUDE.md`, which this file points at and does not restate: a campaign
carrying the operator's explicit consent, the bead's work complete, and full
`mix quality` green. That section is operator-adopted; nothing here widens or
narrows it.

Two consequences worth spelling out at commit time:

- **The gate before the commit is the only pre-commit verification.** CI
  exists (`.github/workflows/ci.yml` runs the manifest's `gate.full` on
  pushes to `main` and on pull requests), but it fires after the push, and
  there is no second reviewer, so nothing catches a bad commit before it
  leaves this machine. A `--profile loop` green is not the trigger - it skips
  dialyzer, deps audit, and coverage.
- **A diff touching no Elixir code has no gate to run** and may commit on
  review of the diff alone (the authority table says so explicitly). The
  manifest's `gate.build_paths` is the boundary: a docs-only or
  `.claude/`-only change falls outside it. Say in the commit body review that
  this is why the gate did not apply, rather than leaving it ambiguous.

## Sabotage discipline (the project's answer to `data.sabotage.missing`)

`data.sabotage.missing` is a report, not a gate, per the generic skill - but
this project's convention (CLAUDE.md: sabotage every new test that asserts
`lib/` behavior) makes it a real refusal condition:

- A test with no `# sabotage:` note directly above it has been *observed*
  passing, not *verified*. Break the `lib/` code it covers, confirm it goes
  red for the right reason, revert, confirm green, then write the one-line
  note above the test. Re-run the gate afterward.
- Never invent a note for a mutation that was not run - a fabricated note is
  the one failure mode this check cannot catch afterward. Refuse and report
  which tests are unverified instead.
- There are no exempt test roots here (`gate.sabotage.exempt_prefixes` is
  empty); every `lib/`-asserting test carries a note.
- **StreamData properties are scanned too.** `gate.sabotage.test_pattern` is
  `\b(?:test|property)\s+"`, so a `property "..." do` declaration is held to
  the same bar as a `test "..." do` one. It was `\btest\s+"` until sob-fc0
  (2026-09-06), which is why the properties in
  `test/statifier_oban/timer/key_property_test.exs` and
  `test/statifier_oban/timer/job_args_test.exs` were verified by hand rather
  than by the scan.
- **Put the note directly above the declaration, not above the `describe`.**
  The scan walks upward from the declaration over the *contiguous* run of
  comment lines and stops at the first non-comment line, so a note sitting
  above the enclosing `describe` is invisible to it - the declaration reads
  as unnoted even though a human sees the note. A note covering two
  declarations is repeated above each.
- The marker itself is matched **case-insensitively** (`/#\s*sabotage:/i` in
  the wurk kit, per the operator's 2026-08-27 ruling to fix the scanner
  rather than the convention), so `# Sabotage:` is recognised. This repo
  writes it lowercase throughout (cd3e0e9); keep to that for consistency, not
  because the scan requires it.

## Changelog: fragments, judged by changelog.d/README.md

`changelog.mode` is `fragments` with `dir: changelog.d`. The needs/no-entry
test is written down in `changelog.d/README.md` - one file per bead, named
`changelog.d/<bead-id>.md`, standard Keep a Changelog headings, entries only
for changes visible to someone calling the public API. Scaffold and tooling
work needs no fragment, and that is the expected outcome, not a step you
skipped. `changelog.d/` holding nothing but its `README.md` is the normal
resting state between releases: fragments are assembled into a `CHANGELOG.md`
section at release and removed.

## Version bump: never

`mix.exs` holds `0.6.0` (release prepared 2026-09-02 on the `sob-jmr` bead;
0.4.0, published 2026-09-01, is still the last version actually on Hex - the
tag and the publish are the operator's) until a release bead says otherwise,
and the authority table marks releases and version bumps as never an
agent's. Never edit the version field as part of an ordinary commit,
and do not update this number here as a convenience - the released version
moves only through a release bead, which updates this line with it.

## Gate thresholds are the operator's call

`gate.moving_files` lists `.quality.exs` and `coveralls.json`. A diff that
moves a number in either needs the operator to have asked for it - "the gate
went red and the threshold looked too strict" is the signal working, not a
reason to move it. `.quality.exs` also records why this gate is deliberately
smaller than statifier-ex's; that decision stands (statifier-ex
docs/family-reference.md marks the custom stages as not-reference). Report
the finding and stop.

## Gate attestation: dep-provided `mix quality.verify`

The manifest wires `gate.attest` to `mix quality.verify`. The task ships in
`ex_quality` (`~> 0.14`, `only: :dev`, locked at `0.14.0`), so this repo
carries no local copy of it, on purpose, per the operator's ruling on
st-hcgl. It adds no gate stage and does not touch `.quality.exs`: it runs
the gate with a machine-readable report and attests that the run was full
(status ok, scope all, no profile, no run-narrowing skip). An unattended
(`/wurk:commit --auto`) run therefore advances only on `attested: true`; do
not fake an attestation, and treat an attest failure as a narrowed or red
gate to fix, not a prompt to bypass.

The earlier wiring named `mix gate.verify` (bead `sob-ehl`) and attributed
the task to the `statifier` dependency. Both were false - no
`Mix.Tasks.Gate.Verify` was ever adopted here or shipped by any dependency -
and `7ee1426` (`sob-569`, fleet ruling F2 2026-08-27) dropped the
declaration outright, because a dangling attest command can yield a blocked
`gate_attest_could_not_start` envelope. Re-pointing it at the published
`ex_quality` task is what that commit deferred.
