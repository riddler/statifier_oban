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
| `git merge`, merging a request | never | always - merging is the operator's, in every campaign and outside every campaign |
| `bd close <id>` | never for a mirrored bead; otherwise the operator's call | always for a bead whose description carries a `mirrors:` line, campaign consent included |
| `bd dolt push` | the operator's call | inside a campaign that spans mirrored trackers - the conductor pushes those atomically |
| a release, a version bump | never | always |

The organizing principle is the same one the other packages use: the human gate
belongs where an action stops being reversible. A commit on a per-bead branch
is undone with `git reset --soft HEAD~1`. A push, a request, a merge, and a
closed bead are visible to other people and other machines, so a campaign's
consent is what buys the first two and nothing buys the last two.

Two rules override every row above. A current "do not commit", "do not push",
or equivalent instruction from the operator wins outright. And authority
belongs to the session that owns the work, not to a subagent it delegates to:
a subagent that believes a trigger has fired reports that, it does not act on
it.

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

**Nothing is implemented yet.** The repository holds the scaffold only, so
almost every convention below is inherited rather than demonstrated.

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
- The dedup key is `{session scope, send_id, macrostep, microstep, round,
  c_index, owner}`. A `<foreach>` body re-executes the same static `c_index`
  list every iteration, so a hand-written `id` on a `<send delay="...">` inside
  one collides on every field of the key. Leave the `id` off: a library-
  generated id advances `send_counter` per execution and the key is unique
  again.

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
