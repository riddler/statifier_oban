# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries for unreleased work are not written here directly. Each issue drops a
fragment in [`changelog.d/`](changelog.d/README.md); the fragments are assembled
into a version section at release. See that README for the format and for when a
change warrants an entry at all.

## [0.3.0] 2026-08-27

### Added

- An invoke handler whose retries are exhausted now feeds
  `error.communication.invoke.<invoke_id>` back into the chart, carrying
  `%{"reason" => class, "attempts" => n, "detail" => text}` and delivered
  behind the same run-liveness check a completion goes through, so a chart
  parking failed work for operator recovery leaves the invoking state instead
  of hanging in it. Previously a permanent failure was visible only on the
  discarded job row. The failure classes are `"run_failed"` (the last attempt
  returned `{:error, reason}`) and `"run_crashed"` (it raised or exited); see
  ADR-0005.
- `StatifierOban.Config` accepts an optional `:opaque_codec`, a module
  implementing the new `StatifierOban.OpaqueTerm.Codec` behaviour, that
  transforms the bytes of a job's host-opaque args (a timer's `data` and
  `caller_context`, an invoke's `params` and `content`) before they are
  stored. The default (`nil`) is unchanged: today's plain Base64 encoding.
  For most hosts, passing entity ids instead of values and re-fetching at
  execution time remains the recommended shape - see the README's
  "Sensitive values in job args" section.

### Changed

- **Breaking for hosts implementing `StatifierOban.Invoke.Delivery`
  themselves:** the behaviour gains a required `deliver_failure/3` callback,
  and a delivery module that does not export it no longer resolves - its jobs
  retry with `{:error, {:invalid_delivery, name}}`. Add `deliver_failure/3`
  alongside your `deliver/3`, running the same liveness check and reporting the
  failure to the run. Hosts using the default
  `StatifierOban.Invoke.Delivery.Session` need no change.
- This package now requires `{:statifier, "~> 2.2"}`, the first release
  carrying `Statifier.Session.failed_invocation/3` (st-ADR-0068).
- The README now opens with a worked canonical-domain example (a card
  authorization's settlement window as a durable timer, plus an async
  invoke), and the project docs were refreshed to match the current
  surface.

## [0.2.1] 2026-08-24

Documentation-only release: brings the package docs to the shared
hexdocs standard.

### Changed

- ADRs are no longer published to hexdocs; they remain in the repo.
- README gains the standard badge row (CI, hex version, downloads,
  docs, license).

### Fixed

- README install snippet now points at `~> 0.2` to match the released
  package.
- Two `mix docs` reference warnings resolved; `mix docs` completes
  with zero warnings.

## [0.2.0] 2026-08-24

### Fixed

- A re-entered state's authored invoke id schedules a fresh Oban job
  instead of being deduped against a previous entry's job: invoke jobs
  are now unique on `{scope, invoke_id, macrostep}` rather than
  `{scope, invoke_id}`. Crash replays still dedup; cancellation still
  matches every job under `{scope, invoke_id}`.

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
