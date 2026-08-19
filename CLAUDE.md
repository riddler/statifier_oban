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
| The contract in statifier-ex looks wrong | Say so and raise it there. Do not work around it here: a host that quietly deviates from ADR-0052 is the failure that record exists to prevent |

## Agent authority in this repo

**This repository has not opted into any expanded profile, so the conservative
rules `bd prime` describes apply in full.** Agents track work in bd, run the
tests, and report; commits, pushes, requests, and bead closes are human calls.

Adopting statifier-ex's team-maintainer profile is a decision for a human to
make and record here. Do not infer it from that repo, from this file's
resemblance to that one, or from the fact that the same person works on both.

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

**Nothing is implemented yet.** The repository holds the scaffold only, so
almost every convention below is inherited rather than demonstrated.

Always refer to state machines as **state charts**, as statifier-ex does.

### Read before writing any code here

The contract this package implements lives in statifier-ex, not here, and it is
already specific about what a host may and may not do:

- `docs/durable-timers.md` - the host-facing recipe: consume the effect,
  schedule externally, feed the fired event back in.
- `docs/adr/0052-durable-timers-consume-the-effect-vocabulary.md` - the rules.
  Consume the **effect** vocabulary (`{:send_delayed, %SendDelayed{}}`,
  `{:cancel, %Cancel{}}`), never the instruction vocabulary (`{:schedule, ...}`,
  `{:cancel_timers, ...}`), which is explicitly opaque outside the library.

Two recorded limits shape what this package can promise:

- The contract covers delayed sends that resolve to the session itself. A send
  routed to `#_internal`, `#_parent`, `#_invokeid`, or an external session is
  left to the library, because the resolved route does not travel on the effect.
- The dedup key is `{session scope, send_id, macrostep, microstep, round,
  c_index, owner}`. Two sends executed in the same microstep from the same
  document position still collide, so a `<foreach>` body that schedules on every
  iteration needs author-generated ids.

Scoping is mandatory in any stored key: Statifier's `send_counter` restarts at 0
per chart run, so a bare `send_id` is unique only within a run.

## Build & Test

```bash
mix test      # the suite
mix format    # no quality gate is wired up yet
```

There is no `mix quality` gate here yet. statifier-ex runs ExQuality; adopting
it (or anything else) is an open decision, not an assumed one.

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
