# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries for unreleased work are not written here directly. Each issue drops a
fragment in [`changelog.d/`](changelog.d/README.md); the fragments are assembled
into a version section at release. See that README for the format and for when a
change warrants an entry at all.

## [0.9.1] 2026-09-06

### Changed

- The README and `StatifierOban.Invoke.Delivery` now state where an
  `<invoke>` handler is resolved from on every step, including the second
  one a completed invoke re-enters.

## [0.9.0] 2026-09-06

A fan-out is no longer invisible in the telemetry stream. Three events are
added - `:fan_out` when the child starts are stored, `:child_started` when
the `ChildStarter` seam creates one, and `:unstarted_cancelled` when a
`first_error` cancel sweeps the rest - taking
`StatifierOban.Telemetry.events/0` from eleven names to fourteen. A host
that calls `StatifierOban.Invoke.FanOut.start/5` directly now reads
`{:ok, summary}` on success where it read a bare `:ok` before; the other
three return shapes are unchanged.

### Added

- Three fan-out telemetry events, taking `StatifierOban.Telemetry.events/0` from eleven names to fourteen: `[:statifier_oban, :invoke, :fan_out]` when an invocation's N child starts are stored, `[:statifier_oban, :invoke, :child_started]` when the host's `ChildStarter` seam creates one child, and `[:statifier_oban, :invoke, :unstarted_cancelled]` when a `first_error` cancel sweeps the starts that had not run. A fan-out was previously invisible in this stream: it delivers nothing, so no `:delivered` event fired for it, and a cancelled sibling was reported nowhere at all (ADR-0006's 2026-09-06 amendment).

### Changed

- `StatifierOban.Invoke.FanOut.start/5` returns `{:ok, summary}` rather than `:ok` on success, where `summary` is `%{count:, policy:, queue:}` - what the caller needs to emit `[:statifier_oban, :invoke, :fan_out]` without reading the invocation's `on` parameter a second time. `{:empty, []}`, `{:refused, _}` and `{:error, _}` are unchanged.

## [0.8.0] 2026-09-06

No new public surface: this release changes what an existing arm does. A
fan-out whose `items` list comes back empty used to fail the invocation;
it now completes it. Nothing on the caller's side has to change for that
to take effect.

### Changed

- A fan-out over an empty `items` list succeeds over nothing: no child starts, the invocation is answered immediately with `[]`, and the `:empty_items` refusal reason is gone (`sb-ADR-0009` decision 8).

## [0.7.0] 2026-09-05

### Added

- `StatifierOban.Invoke.FanOut` schedules a fan-out invocation: a handler's `run/1` returns `{:fan_out, items}` and one start job goes out per item, keyed per index and resumable from the ones already stored.
- `StatifierOban.Invoke.ChildStarter` is the seam a fan-out's child runs are created through, named by the new `:child_starter` config option.
- `:max_fan_out` caps a fan-out's width (default `1_000`); a wider one starts no children and fails the invocation on `error.communication.invoke.<invoke_id>` with the count and the cap.
- `StatifierOban.Invoke.FanOut.cancel_unstarted/3` cancels the start jobs of an invocation whose children have not been created yet.
- A fan-out's aggregation policy reaches the starter seam: `StatifierOban.Invoke.ChildStarter.start_child/5` takes an option list carrying `policy: :all | :first_error`, read off the `core.map` invocation's `on` parameter (absent means `:all`; an unrecognised word refuses the fan-out), so a `first_error` fan-out is expressible through the seam. The callback's arity changed within this still-unreleased version - no published release carried the four-value shape.

## [0.6.1] 2026-09-03

### Fixed

- `StatifierOban.Timer.cancel/3` and
  `StatifierOban.Invoke.Handler.perform_cancel/3` no longer name the
  `suspended` job state on an Oban older than 2.21.0, where Postgres rejected
  it for the `oban_job_state` enum and every cancel raised; the cancellable
  states are now taken from the installed Oban at call time, so the declared
  `~> 2.19` floor holds.

## [0.6.0] 2026-09-02

### Added

- An async invocation's `caller_context` is stored on its Oban job row and
  handed back when the invocation is answered, so a completion days later
  still links to the trace that started it.
- `StatifierOban.Invoke.Delivery` gains optional `deliver/4` and
  `deliver_failure/4`, which receive that `caller_context` for a
  process-less host building the answer event itself; implementations
  defining only the three-argument doors are called exactly as before.

### Changed

- This package now requires `{:statifier, "~> 2.5"}`, the first release
  carrying `%Statifier.Effect.Invoke{}.caller_context` and
  `Statifier.Invoke.Answer.done/4` / `failed/4`. Upgrade statifier to 2.5.0
  or later alongside this release.

## [0.5.0] 2026-09-01

### Added

- `StatifierOban.Telemetry` emits eleven `[:statifier_oban, ...]` events across
  the scheduling and delivery seams, with `events/0` returning the full list
  for `:telemetry.attach_many/4` (ADR-0006, `docs/telemetry.md`).

## [0.4.0] 2026-09-01

### Added

- An invoke handler may define `run/2` instead of `run/1` and receive the run's
  scope alongside the invoke effect, so work keyed to the workflow instance can
  be written against the Oban handler base.
- `StatifierOban.Timer.Delivery.fired_event/2` builds the external event a
  fired timer feeds back, so a host delivery implementation restores the
  caller's trace context instead of assembling the event by hand and dropping
  it.

## [0.3.2] 2026-08-31

### Fixed

- A base handler's cancel no longer cancels an invoke job that is already
  executing, so an invocation whose own completion exits its invoking state is
  no longer killed mid-delivery by that state's `<cancel>`.

## [0.3.1] 2026-08-31

### Changed

- An undecodable invoke job now reports `error.communication.invoke.<invoke_id>`
  through the delivery seam before cancelling, whenever its row still names a
  scope and an invoke id, so a chart parked on `error.communication` no longer
  hangs on a corrupt row.

### Fixed

- `StatifierOban.Timer.cancel/3` no longer cancels a timer job that is already
  executing, so a fired timer whose delivery exits the state that armed it is
  no longer killed mid-step by its own `onexit` `<cancel>`.

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
