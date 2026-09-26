# ADR-0009: Deferred completion - a handler may hand its work on and be answered later

Status: accepted (2026-09-25, sob-c6g)

## Context

An invoke handler built on `StatifierOban.Invoke.Handler` answers its
invocation from inside the Oban job that runs it. At bab4cf3 `c:run/1` and
`c:run/2` (`lib/statifier_oban/invoke/handler.ex`) have three returns:
`{:ok, donedata}`, delivered as `done.invoke.<invoke_id>`; `{:error, reason}`,
which retries and on the terminal attempt delivers
`error.communication.invoke.<invoke_id>` (ADR-0005); and `{:fan_out, items}`,
which completes the job without delivering and leaves the invocation open for
the settlement side (ADR-0007).

None of the three fits work that runs somewhere else. A host whose work is
done by a different Oban instance in a different release - its own queue, its
own deploy cadence, its own retry policy - can enqueue that work from `run/2`,
but then has no honest thing to return. `{:ok, _}` would answer the invocation
before the work is done. `{:error, _}` would retry a hand-off that succeeded,
and eventually tell the chart it failed. Blocking inside `run/2` until the other
release finishes holds a job slot for as long as the work takes, and a
run-time bound (`:invoke_timeout`, ADR-0005's 2026-09-24 Note) would kill it.

The doors for answering later already exist. `StatifierOban.Invoke.Delivery`
at bab4cf3 defines `c:deliver/3` and `c:deliver_failure/3`
(`lib/statifier_oban/invoke/delivery.ex`) - callbacks, not functions this
package exports - and the host's implementation of that behaviour is what the
worker calls to feed `done.invoke.<invoke_id>` or
`error.communication.invoke.<invoke_id>` into the execution, behind the
liveness check. Each call is keyed by the execution's scope and the invoke id,
both plain strings. Nothing in either door requires that the caller be the
Oban job that ran `run/2`.

The operator ruled the shape on 2026-09-25: a handler whose work runs elsewhere
answers `:deferred`; the job completes without delivering; the invocation stays
open; the foreign side answers through the host's delivery implementation by
scope and invoke id, with access to the engine's execution store; and while the
answer is outstanding the engine does nothing new - cancel goes through the
existing cancel path, and a deadline is the chart's own delayed send.

## Decision

**1. `:deferred` is a fourth return of `run/1` and `run/2`.** The Handler
behaviour's callback types gain it as `t:deferred/0`
(`lib/statifier_oban/invoke/handler.ex`, this change). It means "the work was
handed on, and the answer will come later, from outside this job". It carries
no payload: whatever the finishing side needs to answer - the scope and the
invoke id - is already on the `t:run_ctx/0` that `run/2` is handed, and on the
effect.

**2. The job completes without delivering.** `StatifierOban.Invoke.Worker`'s
`execute/5` (this change) returns `:ok` for a `:deferred` return, so the Oban job
completes and neither door is called. This is the fan-out arm's outcome
(ADR-0007) with one difference: after a fan-out, the settlement side of this
family answers the invocation; after a deferral, nothing in this package ever
does.

**3. The door is the host's `StatifierOban.Invoke.Delivery` implementation.**
The finishing side answers by calling `c:deliver/3` with donedata, or
`c:deliver_failure/3` with a `t:StatifierOban.Invoke.Delivery.failure/0`, on
the host's delivery module - the same module the handler's config names as
`:invoke_delivery` - passing the scope and invoke id the deferring job ran
under. The four-argument forms serve a host that builds the answer event
itself, as they do for the worker. Everything those callbacks already promise
holds unchanged for a later caller: the liveness check first, `:delivered` or
`{:discarded, reason}` back, and a raise for an environment failure. The door
has to reach the execution: a process-less host's implementation needs the
engine's execution store, and the default `StatifierOban.Invoke.Delivery.Session`
at bab4cf3 (`lib/statifier_oban/invoke/delivery/session.ex`) needs to run
where `Statifier.Registry` holds the session.

A failure delivered this way names its own class. `"reason"`, `"attempts"` and
`"detail"` are whatever the finishing side reports; none of the five classes
`StatifierOban.Invoke.Worker` emits (ADR-0005) is produced on this path,
because this package never sees the work fail.

**4. While the answer is outstanding, this package does nothing.** No job
waits, polls, or times out on the answer, and no new row is written for it. Two things
a chart may still want are already available and are not duplicated:

- **Cancel** is the existing path. Leaving the invoking state runs the
  handler's `cancel/2`, and `StatifierOban.Invoke.Handler.perform_cancel/3` at
  bab4cf3 cancels the invocation's jobs that have not run - which, after a
  deferral, is none, because the deferring job has already completed. The
  engine drops the invocation; an answer that arrives afterwards is then a
  no-op in the default delivery, which `Statifier.Session.done_invocation/3`
  documents for an invocation the session already popped. Telling the other
  release to stop is the host's to arrange.
- **A deadline** is the chart's own delayed send: a `<send delay="...">` in the
  invoking state, with a transition out of it, cancels the invocation through
  the path above when it fires first.

**5. The hand-off is at least once.** `run/2` returning `:deferred` is work
done inside an Oban job like any other, so a crash between the hand-off and
the job's completion re-runs it. The handler keys the hand-off on `invoke_id`
(for example, a unique insert on the other instance), exactly as the
at-least-once contract already asks of every `run/1`.

## Consequences

- A host can split an invocation's work across releases without holding a job
  slot for the work's whole duration, and without a timeout that the work's
  duration decides.
- The package emits no invoke telemetry event of its own for a deferral: the
  job's completion is visible as Oban's own job stop event, and the eventual
  answer is invisible to this package, so ADR-0006's
  `[:statifier_oban, :invoke, :delivered | :discarded | :failed]` events do
  not fire for it.
- An invocation deferred and never answered stays open for as long as its
  state is active. That is the chart's to bound, with the delayed send of
  decision 4; this package has no view of the answer to bound it with.
- An answer can arrive before the deferring job has completed - the other
  release may be fast. Nothing depends on the order: the answer steps the
  execution through the door, and the job then completes without delivering.
- The return set of `run/1` and `run/2` grows, so the change ships in a minor
  release. A handler that never returns `:deferred` behaves exactly as before.

## Note (2026-09-25): accepted, the code shipped in 0.14.0

The operator accepted this record on 2026-09-25. The code that implements
it is `f155ff5` (`sob-c6g`, PR 110), carried by the published release
0.14.0 (tag `v0.14.0`, `35e8534`). The status line at the top flips in
place from proposed to accepted, and the ADR index row with it; no other
line of the record changes. Every decision was read at that tag, which
is also `main` at the time of the flip.

- Decision 1: `t:StatifierOban.Invoke.Handler.deferred/0` is `:deferred`,
  and the callback types of `run/1` and `run/2` carry it
  (`lib/statifier_oban/invoke/handler.ex`).
- Decision 2: the `:deferred` arm of `StatifierOban.Invoke.Worker`'s
  private `execute/5` answers `:ok` and calls neither door.
- Decision 3: `StatifierOban.Invoke.Delivery` declares `deliver/3`,
  `deliver_failure/3` and their four-argument forms, unchanged by the
  deferral.
- Decision 4: no job, row or timeout is added for an outstanding answer;
  the cancel path is `StatifierOban.Invoke.Handler.perform_cancel/3`,
  unchanged.
- Decision 5 and the Consequences: `test/statifier_oban/invoke/worker_test.exs`
  carries "a deferred return completes the job without delivering through
  either door", and the 0.14.0 section of `CHANGELOG.md` names the new
  return.

Two follow-ups sit on the accepted text and do not hold the flip, each to
land as a dated Note or Amendment on this record: sob-v6x, on decision
4's narration of a call chain and decision 2's naming of a private
function, and sob-9xp, on whether a deferral gets an invoke telemetry
event of its own, which the Consequences say it does not today.

## Note (2026-09-26): a deferral now emits `[:statifier_oban, :invoke, :deferred]`

The Consequences above say the package "emits no invoke telemetry event of its
own for a deferral". That sentence is changed by ADR-0006's 2026-09-26
amendment (proposed, sob-9xp), which adds the event
`[:statifier_oban, :invoke, :deferred]`: the `:deferred` arm of
`StatifierOban.Invoke.Worker`'s private `execute/5` emits it, through
`StatifierOban.Telemetry.invoke_deferred/5`, when `run/1` or `run/2` answers
`:deferred`, and still answers `:ok` without calling either door. Its
measurements and metadata are stated in that amendment's table.

The rest of that bullet stands: the eventual answer is invisible to this
package, and `[:statifier_oban, :invoke, :delivered | :discarded | :failed]`
still do not fire for a deferral. No decision of this record moves; decision 2's
outcome, a job that completes without delivering, is unchanged. The event ships
in a minor release, because it grows the closed set `events/0` returns.

## Note (2026-09-26): decisions 2 and 4 restated as facts

This Note restates two decisions of the accepted text without moving either.
Decision 2 names a function private to the worker, and decision 4's cancel
bullet follows one call into the next; below, each fact stands on its own
with one anchor, read at `72b08b3`. It is the first of the two follow-ups the
2026-09-25 Note names. No line above changes.

**Decision 2.** A `:deferred` return from `run/1` or `run/2` completes the
Oban job, and neither door of the host's `StatifierOban.Invoke.Delivery`
implementation is called. `StatifierOban.Invoke.Worker`'s moduledoc states
this outcome, and `test/statifier_oban/invoke/worker_test.exs` pins it in "a
deferred return completes the job without delivering through either door".
The 2026-09-25 Note's decision 2 bullet and the 2026-09-26 Note name the
same outcome by the worker's private function; the fact they record is this
one. The event the 2026-09-26 Note adds is emitted by the invoke worker's
deferred arm, through `StatifierOban.Telemetry.invoke_deferred/5`.

**Decision 4.** While the answer is outstanding:

- **Cancel is the existing path.** `StatifierOban.Invoke.Handler.perform_cancel/3`
  cancels only the invocation's jobs that have not run. After a deferral the
  deferring job has already completed (decision 2), so it cancels none.
- **A late answer is a no-op.** The no-op is the session's, not the
  delivery's: `Statifier.Session.done_invocation/3` (and
  `failed_invocation/3`), in statifier 2.7.0 as `mix.lock` pins it,
  documents a call for an invocation the session already popped as a
  harmless no-op. While the execution is still running, the default
  delivery's liveness check passes and it returns `:delivered`; the accepted
  text's "a no-op in the default delivery" is this fact. When the execution
  has ended or halted instead, `c:StatifierOban.Invoke.Delivery.deliver/3`
  returns `{:discarded, reason}`.
- **Stopping the other release is the host's.** This package holds nothing
  that reaches the release the work was handed to; the README's "Enqueue
  elsewhere, answer later" section says telling it to stop is the host's to
  arrange.
