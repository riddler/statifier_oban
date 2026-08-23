# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries for unreleased work are not written here directly. Each issue drops a
fragment in [`changelog.d/`](changelog.d/README.md); the fragments are assembled
into a version section at release. See that README for the format and for when a
change warrants an entry at all.

## [0.1.1] 2026-08-23

### Changed

- Relaxed oban dependency to 2.19

## [0.1.0] 2026-08-22

First release: durable timers and async invoke execution for the
[statifier](https://hex.pm/packages/statifier) statechart engine, on the
host's own Oban instance. This package is one implementation of the
host-facing pattern statifier specifies (its `docs/durable-timers.md`
recipe and ADR-0054/0055/0059/0051), not the definition of it.

### Added

- `StatifierOban.Config` carries the host-supplied Oban instance name plus
  the required `:timers_queue` and `:invoke_queue` (no defaults - a missing
  queue is a typed error, never a silent fallback), and the `:delivery` /
  `:invoke_delivery` seams. The package never starts or names an Oban
  instance of its own (ADR-0002).
- `StatifierOban.Timer.schedule/3` consumes a `%Statifier.Effect.SendDelayed{}`
  into one Oban job on the host's instance, unique on the `{scope, ordinal}`
  dedup key across every job state, with the fire time computed at insert
  from the relative `delay_ms`. Only `nil`-target sends are schedulable
  (st-ADR-0055); a duplicate insert is a conflict no-op.
- `StatifierOban.Timer.cancel/3` consumes a `%Statifier.Effect.Cancel{}`
  into cancellation of every timer job stored under the `{scope, send_id}`
  cancellation key - several jobs may match, per spec 6.3. A cancel
  matching nothing returns `{:ok, 0}`, a no-op rather than an error. A
  cancel racing execution resolves to whichever transition commits first:
  a job already in a terminal state keeps its outcome and is not counted.
- Fired timer jobs deliver: `StatifierOban.Timer.Worker` feeds the
  stored event back through a `StatifierOban.Timer.Delivery` module,
  behind the run-liveness check st-ADR-0054 decision 4 requires - a run
  that is not live discards the event (spec 6.2), recorded on the
  cancelled job as `{:discarded, reason}`. The default
  (`StatifierOban.Timer.Delivery.Session`, configurable via
  `StatifierOban.Config`'s `:delivery` option) checks a live
  `Statifier.Session` in two steps - registry lookup, then `status/1` -
  so a halted-but-alive session discards rather than queueing.
- An Oban-backed invoke handler base: `use StatifierOban.Invoke.Handler`
  implements statifier's `Statifier.Invoke.Handler` behaviour (st-ADR-0051)
  with pure planning callbacks whose `perform/2` inserts one
  `StatifierOban.Invoke.Worker` job - unique on `{scope, invoke_id}` over
  every state, so an at-least-once replay conflicts instead of duplicating -
  into the host's Oban instance. The `use`-ing module supplies `config/0`
  and `run/1`; the worker runs `run/1` inside the job and delivers
  `{:ok, donedata}` back into the run as `done.invoke.<invoke_id>` (the
  session runs `<finalize>` off the arriving event). Exiting the invoking
  state cancels the stored job through the same handler.
- `StatifierOban.Invoke.Delivery`, the seam a completed invoke's
  `done.invoke` goes back through - the same run-liveness shape as
  `StatifierOban.Timer.Delivery`: a completed invoke against a dead or
  halted run is discarded the way a fired timer is, recorded on the
  cancelled job as `{:discarded, reason}`. The default
  (`StatifierOban.Invoke.Delivery.Session`) delivers through
  `Statifier.Session.done_invocation/3` behind the two-step liveness check.
