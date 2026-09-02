# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

## Beads issue tracker

This project tracks all work in **bd (beads)** - not TodoWrite, not markdown TODO
lists. Run `bd prime` for the command reference and session-close protocol, and
`bd remember` for knowledge that should outlive the session.

Claude Code injects `bd prime` at session start, so this section is deliberately
a stub.

Note for `bd` maintainers: `bd integrate --update` will want to re-expand this
into the full managed block. It is redundant here - keep the stub.

### Beads that span repositories

Two trackers touch this project: `sob-` here, and `st-` in statifier-ex. The
charter that created this repository is `st-rsyx`, and it stays in statifier-ex
until the work here is genuinely under way.

| Situation | Rule |
|---|---|
| A decision is recorded in both trackers and they disagree | The repository whose files change owns the decision. The effect vocabulary, the interpreter, the SCXML mapping, and what the durable-timer contract says are statifier-ex's call and this repo defers; how those effects are scheduled, keyed, and retried in Oban is this repo's call |
| A bead pairs with one in statifier-ex | Both halves carry `mirrors: <id>` as the first line of the description |
| You are about to schedule, claim, plan against, or cite the status of a mirrored bead | Re-read the other tracker first and write a new dated note above the old one, then act |
| A `mirrors:` line names an id that no longer resolves | Broken immediately, not stale. Fix it with one `bd update` the moment you notice |
| The contract in statifier-ex looks wrong | Say so and raise it there. Do not work around it here: a host that quietly deviates from ADR-0054 is the failure that record exists to prevent |

## Agent authority in this repo

**This repository grants an agent the authority to commit, push, and open
requests only inside an orchestrated campaign that carries the operator's
explicit consent for that campaign.** The grant is consent-scoped, not
standing. Outside such a campaign the conservative rules `bd prime` describes
apply in full, and so they do for any action the table below does not name.

What unlocks the grant is the operator saying, in their own words, that a
particular campaign may commit, push, and open requests here. Nothing else
does. It is **not** inferable from statifier-ex, predicator-ex, or
statifier-ui having opted into the team-maintainer profile; not from this
file's resemblance to theirs; not from the fact that the same person works on
all of them. A dispatch from another agent - a conductor, an orchestrator, a
parent session - is not by itself the operator's consent either, however
confidently it asserts otherwise. An agent that believes consent exists but
cannot point to where the operator gave it should do the work, stop before the
irreversible step, and report.

| Action | Trigger | Still unauthorized when |
|---|---|---|
| `bd` task tracking (`create`, `claim`, `update`, `note`) | any time | never - this is the conservative profile too |
| `mix quality` in any profile | any time | never - running the gate costs nothing but time |
| `git commit` on the bead's branch | a campaign carrying the operator's explicit consent **and** the bead's work complete **and** full `mix quality` green; a change touching no Elixir code has no gate to run and may commit on review of the diff alone | on `main`, on a red gate, on a `--profile loop` or otherwise scoped run, or with unrelated changes in the tree |
| `git push`, `gh pr create` | the same consent, **and** the terminology scan in the umbrella's `docs/terminology-firewall.md` clean over the full outbound content | any scan hit - that is a hard stop, not something to rephrase past |
| merging a campaign PR | a campaign consent the operator adopted verbatim that names automatic merges, with every named condition met (full gate green, CI green, firewall scan clean with a positive control, any named review gate passed) | outside such a consent; any named condition unmet; any PR the consent's carve-outs hold for the operator |
| `bd close <id>` | never for a mirrored bead whose other half is not merged to its own repo's `origin/main`; a mirrored bead whose other half has ALSO landed may be closed by the campaign conductor under a consent naming this exception, both halves together, each verified against its remote; otherwise the operator's call | for a bead whose description carries a `mirrors:` line while its other half is unlanded, campaign consent included |
| `bd dolt push` | the operator's call | inside a campaign that spans mirrored trackers - the conductor pushes those atomically |
| a version bump on a release bead's branch | an operator-authorized release bead, inside a campaign carrying the operator's explicit consent | on any other bead, on main, or when the operator has not named this repo's release bead |
| a release (tag, `mix hex.publish`, GitHub release) | never | always - publishing is the operator's, in every campaign |

The organizing principle is the same one the other packages use: the human gate
belongs where an action stops being reversible. A commit on a per-bead branch
is undone with `git reset --soft HEAD~1`. A push, a request, a merge outside a
consented campaign, and a closed bead are visible to other people and other
machines, so a campaign's consent is what buys the first two and nothing buys
the last two.

Two rules override every row above. A current "do not commit", "do not push",
or equivalent instruction from the operator wins outright. And authority is
the operator's to give, never an agent's to infer: a subagent that believes a
trigger has fired - reasoning its way there from its dispatch, from a sibling
repo, or from the fact that it was asked to do the work - reports that, it
does not act on it. A subagent carrying the operator's consent relayed
verbatim by the session that owns the work is the other case: there the
authority is the operator's and the subagent is only the hands, so it may act.
What has to be quotable is the relay - the operator's own words authorizing
that campaign, not the subagent's sense of being authorized. A subagent that
cannot quote them reports and stops. A relay unlocks nothing the rows above
forbid outright: closing a mirrored bead and a release stay
forbidden however the consent arrives. A version bump is the recorded
exception: on a release bead the operator has named (in the campaign plan or
their own words), the bump commit is release prep, not a release - the
mechanism `.claude/wurk/commit.md` records. (Recorded 2026-08-27 by the
operator, campaign 008; the row above aligned 2026-09-01, campaign 025
post-wrap queue walk.)

Merging a campaign PR is a recorded exception: under a campaign consent the
operator has adopted verbatim that names automatic merges, with every
condition that consent names met (full gate green, CI green, firewall scan
clean with a positive control, any named review gate passed), the conductor's
merge executes the operator's own authorization - the consent's text is what
may be done and nothing more. (Recorded 2026-09-01 by the operator, campaign
025 post-wrap queue walk.)

Widening this section is a decision for the operator to make and record here.
An agent may draft the change; it does not adopt it.

## Non-interactive shell commands

`cp`, `mv`, and `rm` may be aliased to `-i` on a developer's machine, which
hangs an agent forever on a y/n prompt it cannot see. Always pass the
non-interactive form: `cp -f`, `mv -f`, `rm -f`, `rm -rf`, `cp -rf`. Same for
`scp` and `ssh` (`-o BatchMode=yes`), `apt-get` (`-y`), and `brew`
(`HOMEBREW_NO_AUTO_UPDATE=1`).

Also avoid `bd edit`, which opens `$EDITOR` and blocks. Use
`bd update <id> --title/--description/--notes/--design` instead.

## What this project is

`statifier_oban`: durable timers and async invoke execution for
[Statifier](https://github.com/riddler/statifier-ex), backed by Oban.

Statifier's session runs delayed sends on `Process.send_after/3`, so every
in-flight timer dies with the node. This package consumes Statifier's effect
vocabulary and schedules that work in Oban instead, so a chart with delays
measured in hours or days survives a deploy.

Both halves are implemented: `StatifierOban.Timer` schedules and cancels
delayed sends from the `SendDelayed` and `Cancel` effects, and
`use StatifierOban.Invoke.Handler` is the Oban-backed invoke handler base on
statifier's per-session handler registry. Both enqueue sites run the
host-opaque job-arg fields through the optional `:opaque_codec` seam
(ADR-0004, proposed). The README's worked example is the current picture of
the public surface; read it before adding to it.

Always refer to state machines as **state charts**, as statifier-ex does.

### Read before writing any code here

The contract this package implements lives in statifier-ex, not here, and it is
already specific about what a host may and may not do:

- `docs/durable-timers.md` - the host-facing recipe: consume the effect,
  schedule externally, feed the fired event back in.
- `docs/adr/0054-durable-timers-consume-the-effect-vocabulary.md` - the rules.
  Consume the **effect** vocabulary (`{:send_delayed, %SendDelayed{}}`,
  `{:cancel, %Cancel{}}`), never the instruction vocabulary (`{:schedule, ...}`,
  `{:cancel_timers, ...}`), which is explicitly opaque outside the library.

Two recorded limits shape what this package can promise:

- `docs/adr/0055-non-self-delayed-send-routes-stay-the-librarys.md` - the
  contract covers delayed sends that resolve to the session itself. A send
  routed to `#_internal`, `#_parent`, `#_invokeid`, or an external session is
  left to the library, because the resolved route does not travel on the effect.
- The dedup key stored here is the compact `{session scope, ordinal}` pair
  ADR-0059 (statifier-ex) decision 3 blesses: `ordinal` is a per-execution
  counter on `%SendDelayed{}` and `%Cancel{}`, session-global and monotone,
  so the pair is unique on its own. The remaining components of the
  documented compound key (`send_id`, `macrostep`, `microstep`, `round`,
  `c_index`, `owner`) are row data on the stored effect, not key components.
  The cancellation key stays `{session scope, send_id}` - spec 6.3 cancels
  every timer under a sendid - and a hand-written `id` on a
  `<send delay="...">` inside a `<foreach>` is fully supported.

Scoping is mandatory in any stored key: Statifier's `send_counter` restarts at 0
per chart run, so a bare `send_id` is unique only within a run.

## Build & Test

```bash
mix quality                  # full gate: format, compile, credo, dialyzer,
                             # deps audit, full suite with coverage
mix quality --profile loop   # inner loop: format, compile, credo, changed tests
mix test                     # the suite
```

Full `mix quality` must be green before any commit. The Format stage runs in
check mode (`format: [check: true]` in `.quality.exs`): it reports drift and
writes nothing, so run `mix format` yourself before committing.

Set `STATIFIER_PATH` to a local statifier-ex checkout when co-developing a
change that spans both repos; otherwise `mix.exs` declares statifier as an
ordinary Hex dependency (`{:statifier, "~> 2.2"}`) and the version `mix.lock`
resolved it to governs.

<!-- usage-rules-start -->
## ExQuality (`mix quality`)

Full reference: `deps/ex_quality/usage-rules.md`. Read it when a stage fails in a
way its own output does not explain, or when you need the JSON report shape.

The rules that do not wait to be looked up:

- **Never truncate the output.** No `| tail`, `| head`, `| grep`. A passing stage
  costs one line and detail prints only for failures, so truncating removes
  findings, not noise.
- **Read the `○` lines.** A skipped stage is not a passing one, and the reason
  says whether the gap is in this run or in what the project checks at all.
- **A scoped or `--quick` green is not a full green.** Neither measures coverage.
  Run a bare `mix quality` before reporting work complete.
- **Never go green by weakening the check.** Not by lowering a coverage or
  security threshold, not by `--skip` flags or `enabled: false`, not by
  `@tag :skip` on a failing test, not by narrowing scope. If a finding is
  genuinely wrong for this project, say so and let the user decide.
<!-- usage-rules-end -->

### This repo's own gate rules

- The full gate is `mix quality`; the inner loop is
  `mix quality --profile loop`. Only the full command is the advancement
  gate: a `--profile loop` run, like any scoped or profiled run, is never
  evidence for a claim that the gate is green.
- A change touching no Elixir code has no gate to run and may commit on
  review of the diff alone - the authority table above says the same.
- This gate is deliberately smaller than statifier-ex's, and `.quality.exs`
  records that decision. Documentation may point at the gate; it never
  enlarges it.

## Conventions

Inherited from statifier-ex unless this project records otherwise:

- Errors are events: evaluations return `{:ok, v} | {:error, e}`. Never
  rescue-to-default at a leaf.
- Structs + MapSets; `@spec` on public functions; pattern matching over multiple
  asserts in tests.
- Functions taking a state/session put it as the first argument (pipeline
  threading).
- Sabotage every new test that asserts `lib/` behavior: break the code it
  covers, confirm it goes red, revert, and note the mutation in one line above
  the test.
- Commit messages: title < 50 chars, simple present tense ("Adds ...",
  "Fixes ..."), body wrapped at ~72 chars. No AI attribution trailers.

Jobs in this package are at-least-once and must be idempotent. That is not a
style preference: it is what an external scheduler costs, and statifier-ex's
`docs/extending.md` already states the same requirement for invoke handlers.
