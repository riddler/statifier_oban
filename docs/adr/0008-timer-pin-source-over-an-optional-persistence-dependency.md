# ADR-0008: The timer pin source ships here, over an optional dependency on statifier_persistence

Status: proposed (2026-09-23, sob-1ul)

## Context

`statifier_persistence` asks before it retires a chart whether anything
still pins it, and `StatifierPersistence.PinSource` is how a host answers
for state that package cannot see (`sp-ADR-0012` decision 4). The behaviour
has one callback, `pins(content_hash, context)`, answering a map of atom to
non-negative integer; the context carries `:execution_ids`, the ids of the
`:active` executions on the hash. `StatifierPersistence.PinSource.collect/3`
calls each source through its private `ask/3`, whose `rescue` turns a
raise into `{:error, {:raised, exception}}`, and `collect/3` answers
`{:error, {module, reason}}` with it, so a source that cannot answer
refuses the retirement instead of answering zero
(`lib/statifier_persistence/pin_source.ex`, `defp ask`, read at
`statifier_persistence` `9cd192b`). The behaviour first shipped in
`statifier_persistence` 0.13.0, which is on Hex.

Retirement is not the only reader. `statifier_persistence`'s chart
migration, in flight as its bead `sp-bn0` and not on its main, reads
pending timers through a pin source the host supplies, and refuses a plan
that unmaps or drops a state that could own a timer when no source is
supplied. The same `pins/2` answer serves both callers.

A pending timer is exactly that kind of state, and this package already
answers the question it needs. `StatifierOban.Timer.pending_for/2` takes a
`StatifierOban.Config` and a list of scopes and answers a map carrying
every requested scope, `0` for a scope with nothing pending, counting only
this package's timer jobs in the states a timer that has not fired can be
in (`lib/statifier_oban/timer.ex`, `def pending_for`, read at `53631ca`).
It resolves the host's instance through `Oban.config/1`, which raises when
no instance of that name is running, and counts through `Oban.Repo.all/2`,
which raises when the repo cannot be reached (same function, same SHA).

Today nothing ships the adapter between the two. The README section
"Timers as a chart pin source" shows it as the host's own module,
`MyApp.TimerPins`, and says "Neither package depends on the other and
nothing below ships in either of them" (`README.md`, that section, read at
`53631ca`). `mix.exs` has no `statifier_persistence` entry (`defp deps`,
read at `53631ca`). `statifier_persistence` says the same from its side:
its `PinSource` moduledoc's "This package ships no source" section puts
every implementation in a host's hands (read at `9cd192b`). So every host
that runs both packages writes the same small module, and each one is a
place to get the refusal rule wrong by rescuing.

Shipping the module here reverses the direction this README states, so it
is a record's to decide rather than a code change's.

Two facts about what a timer job stores shape the answer.

**A timer job carries no chart identity.** The args are the scope and the
send (`StatifierOban.Timer.JobArgs.from_effect/3`, read at `53631ca`);
nothing on the row names a content hash, so this package cannot answer a
question asked by hash.

**The scope is whatever the host scheduled under.** It is `ctx.session_id`
for a live session and the host's own durable execution id for a
process-less host (`StatifierOban.Timer.Key` moduledoc, read at `53631ca`).
Only the second is an execution id.

## Decision

**1. `statifier_oban` ships the timer pin source, as
`StatifierOban.Timer.PinSource` in `lib/statifier_oban/timer/pin_source.ex`.**
It lives beside `StatifierOban.Timer` because it is a reading of the same
timer jobs, and it answers through `StatifierOban.Timer.pending_for/2`
rather than a second query, so "pending" means one thing in this package.

**2. The dependency on `statifier_persistence` is optional, with a floor
of `~> 0.13`.** `mix.exs` gains `{:statifier_persistence, "~> 0.13",
optional: true}`. 0.13.0 is the first release carrying the behaviour, and
nothing this record decides needs a later one. The module is compiled only
when `StatifierPersistence.PinSource` is loaded, so a host that runs this
package without `statifier_persistence` gains no module and no dependency,
and a host that runs both gets the source without writing it.

A required dependency was the alternative and loses: most of this
package's surface - timers under a live session, invoke handlers - has no
use for a persistence layer, and a required edge would put one in every
host's tree for the sake of one module.

**3. The source answers one count, `:timers`.** For a context's
`:execution_ids` it answers `%{timers: n}`, `n` being the sum of
`pending_for/2`'s answers over those ids. An empty list answers
`%{timers: 0}`. The name is the one the README's host module already uses,
so a host replacing its own module with this one sees the same key in a
refusal.

**4. The content hash is unused.** No chart identity travels on a timer
job (Context), so the source cannot answer by hash and does not try. The
hash still reaches it because `sp-ADR-0012` decision 4 hands every source
the same arguments, and other sources are answerable by it.

**5. The config is the host's, named where the host adopts the source.**
`pins/2` receives no `StatifierOban.Config`, and this package reads no
application environment to find one (no `Application` call in `lib/` at
`53631ca`): every public entry point takes the host's instance in the
config its caller hands it (`ADR-0002`'s decision). So the source is
adopted with `use StatifierOban.Timer.PinSource, config: {module,
function}`, naming a
zero-arity function in the host that returns the host's
`%StatifierOban.Config{}`. The `use` defines `pins/2` in the host's module,
declares the behaviour there, and calls the function on every `pins/2`, so
a config built at runtime is read at the time of the count. To count,
the injected `pins/2` calls the existing public
`StatifierOban.Timer.pending_for/2` with that config and the context's
`:execution_ids`, and sums the answer; no new public function is added
for it. The host passes its own module to the retire call, or to a
migration; this package ships the counting, the host ships only the name
of its config.

**6. The source is correct only for a host that schedules under durable
execution ids.** The execution ids a pin source is handed are the scopes
a process-less host's timers were scheduled under, which is why they can
go straight to `pending_for/2`. A host that schedules under a live
session's id is scoping by session, and the execution ids it is handed
match no stored scope: the source would answer `%{timers: 0}` for timers
that exist. That zero is wrong for both readers: a retirement would
proceed with timers pending on the chart, and a migration that leaves a
state that could own a timer unmapped would proceed while timers are
pending on the execution (the migration case, `sp-bn0`, Context). The
source cannot see which choice a host made, so it cannot refuse on the
mismatch. The rule is therefore stated where a host adopts
it, in the module's documentation and in the README section: a
session-scoped host does not adopt this source, and answers with its own
module that maps its executions to the sessions its timers were scheduled
under.

**7. A repo the source cannot reach raises, and the source rescues
nothing.** `pending_for/2` raises when the Oban instance is not running
or the repo cannot answer (Context), and the source lets the raise
through. `collect/3` answers a refusal naming the host module that
adopted the source (decision 5), from the raise its private `ask/3`
rescues, which is the answer `sp-ADR-0012`
decision 4 requires: "the source could not answer" and "the source
answered zero" must stay two facts. A source that rescued to
`%{timers: 0}` would retire a chart with timers still pending on it.

`ask/3` at `9cd192b` rescues raises only; a failure that surfaces as
an exit or a throw is not turned into a refusal there. Widening that
rescue is `statifier_persistence`'s bead `sp-2fe`, and nothing in this
record depends on it.

**8. The contract tests live in this repository.** `statifier_persistence`
ships no conformance suite for pin sources: its `Testing` namespace holds
the storage suite and its chart fixtures only
(`lib/statifier_persistence/testing/`, read at `9cd192b`). The code that
implements this record therefore tests the contract here: the count for
the execution ids given, zero for ids with nothing pending, the refusal
when the repo cannot answer, and the same answer read back through
`StatifierPersistence.PinSource.collect/3`.

**9. A timer kept across an explicit migration carries stale compiled
indices, and that is harmless to this package.** A timer job stores the
`c_index` and `owner` of the chart that scheduled it as row data
(`StatifierOban.Timer.JobArgs.from_effect/3`, read at `53631ca`). They
are not dedup-key components (`StatifierOban.Timer.Worker`'s `unique`
`keys`, read at `53631ca`), and the event a fired timer feeds back is
built without them (`StatifierOban.Timer.Delivery.fired_event/2`, read at
`53631ca`). If an execution is re-pinned to another chart by an explicit
migration and a timer is kept, the fired event is the same event either
way; the stored indices describe the chart the timer was scheduled under
and are never read to decide anything here. They still reach a host's
`c:StatifierOban.Timer.Delivery.deliver/2` on the rebuilt
`%SendDelayed{}` (`StatifierOban.Timer.JobArgs.to_effect/1`, read at
`53631ca`), so a host delivery that reads them reads the old chart's
indices. No shipped delivery does.

## Consequences

**The README's stated direction reverses in two places.** The section
"Timers as a chart pin source" is rewritten to name the shipped module and
the one line that adopts it, with the host's own module kept as a valid
alternative for a session-scoped host (decision 6). The section
"Delivering timers to a durable execution" also says "Neither package
depends on the other" (`README.md`, that section, read at `53631ca`); the
delivery adapter it shows stays the host's, and that sentence is
corrected to the optional edge in the same change.

**This package's lock moves.** An optional dependency is still resolved in
this repository's own build, and `statifier_persistence` 0.13.0 requires
`statifier ~> 2.6`, so `mix.lock` moves `statifier` from 2.5.0 to a
release at 2.6 or later and gains whichever of `statifier_persistence`'s
dependencies it does not already carry. The `{:statifier, "~> 2.5"}`
requirement in `mix.exs` is unchanged: a host
without `statifier_persistence` still resolves any 2.5 release.

**A host that runs both packages gets a refusal it did not have to
write.** The example is the library's hold: a hold chart that waits for
`copy.collected` and schedules a `pickup.expired` timer when the copy
becomes available. While that timer is pending, a retirement of the hold
chart is refused with `%{timers: 1}` under the host's module name; once it
fires or is cancelled the count is zero and the timer no longer holds the
chart.

**The hazard decision 6 names is documentation, not a check.** A
session-scoped host that adopts the source anyway gets zeros, so a
retirement it should have refused goes through, and a migration that
leaves a state that could own a timer unmapped proceeds while timers are
pending. That is why such a host must not adopt the source. Nothing here
can detect the mismatch. It is the same trade `StatifierOban.Timer.Key`
already makes by leaving the scope to the caller.

**Nothing here is implemented.** This record changes no file under `lib/`
or `test/` and no changelog fragment is written for it. The module, the
`mix.exs` entry, the lock, the README sections and the tests follow in the
code change that implements it.
