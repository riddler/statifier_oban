# Upgrading a host from 0.11 to 0.17

This page says what a host changes to move `statifier_oban` from 0.11.0 to
0.17.1, one minor at a time: 0.11 to 0.12, 0.12 to 0.13, 0.13 to 0.14,
0.14 to 0.15, 0.15 to 0.16 and 0.16 to 0.17. A host
here is the code that embeds the package: the `StatifierOban.Config` it
builds, the Oban instance and queues it runs the jobs on, its invoke
handlers, any `StatifierOban.Timer.Delivery` or
`StatifierOban.Invoke.Delivery` module of its own, and the telemetry
handlers it attaches. What each release added is in
[CHANGELOG.md](../CHANGELOG.md); this page lists only what a host has to do
about it, and says **NONE** where the answer is nothing.

Move the pin with each minor, as the README recommends:
`{:statifier_oban, "~> 0.17.0"}`. The `statifier` requirement (`~> 2.5`)
and the `oban` requirement (`~> 2.19`) are the same on every step of this
page. No step here adds a migration: the jobs are Oban's rows, in Oban's
table.

## 0.11 to 0.12

Must change: **NONE** for a host that does not depend on
`statifier_persistence`. 0.12.0 adds it as an *optional* dependency, so
such a host gains neither the dependency nor the module that needs it.

- **If you depend on `statifier_persistence`**, it must be 0.13.0 or later.
  The optional requirement is `~> 0.13`, and Mix applies an optional
  dependency's requirement whenever the host brings the package in, so an
  older pin no longer resolves. 0.13.0 is the first release carrying the
  `StatifierPersistence.PinSource` behaviour.

May start doing:

- **Let a chart's pending timers hold it against retirement.** A host
  running both packages can declare a pin source in one line,

      defmodule MyApp.TimerPins do
        use StatifierOban.Timer.PinSource, config: {MyApp, :statifier_oban_config}
      end

  where `MyApp.statifier_oban_config/0` returns the host's
  `%StatifierOban.Config{}`, and pass `MyApp.TimerPins` wherever
  `statifier_persistence` takes pin sources. It answers `%{timers: n}`,
  the timers still pending under the execution ids it is handed. It is for
  a host that schedules its timers under its durable execution ids; a host
  that schedules under a live session's id writes its own source instead,
  as the `StatifierOban.Timer.PinSource` documentation explains. The
  README's "Timers as a chart pin source" section has the full picture.

## 0.12 to 0.13

0.13.0 makes two changes to `StatifierOban.Config`.
Must change: **NONE** for either. Every new option is optional, and its
default does exactly what 0.12.0 does. Both are fixed on the job row when
the job is enqueued, so a job stored before the upgrade keeps the old
behaviour, and a host that sets them after the upgrade changes only the
jobs enqueued from then on.

### Run-time bounds

`StatifierOban.Config.new/1` takes `:invoke_timeout`,
`:child_start_timeout` and `:timer_timeout`, one per job kind: an invoke
job, a fan-out child start job and a fired-timer job. Each is a positive
integer of milliseconds or `:infinity`, and each defaults to `:infinity`,
no bound, which is what every job had before. The largest accepted value is
`4_294_967_295` for `:child_start_timeout` and `:timer_timeout`, the
BEAM's largest timeout, and `4_294_962_295` for `:invoke_timeout`, which
leaves room for the invoke worker's 5-second backstop;
`StatifierOban.Config.new/1` rejects a larger integer, zero, or anything
else with
`{:error, {:invalid_option, key, value}}`.

Must change: **NONE**.

May start doing:

- **Set a bound on a job kind that can hang.** An attempt that runs past
  its bound fails with `Oban.TimeoutError` and retries while attempts
  remain, like any other failed attempt. An invoke whose last attempt
  times out delivers `error.communication.invoke.<invoke_id>` with
  `reason: "run_crashed"`, the class a raising handler's last attempt
  already delivers, so a chart that handles `error.communication` needs no
  new transition.
- **Check what your invoke handlers read of their own process before you
  set `:invoke_timeout`.** Under a finite bound the handler's `run/1` or
  `run/2` is called in a task linked to the job process, so `self()` and
  the process dictionary are the task's, not the job's. Under the
  `:infinity` default no task is started.
- **If you run `Oban.Plugins.Lifeline`, set its `:rescue_after` above the
  largest bound you configure**; for invoke jobs that is the bound plus the
  5-second margin.

The README's "Bounding how long an attempt takes" section and the
`StatifierOban.Config` documentation carry the detail.

### Parking an invoke job whose handler is missing

`StatifierOban.Config.new/1` takes `:unresolved_handler`, `:retry` or
`:cancel`, and defaults to `:retry`. Under `:retry` an invoke job whose
handler module does not resolve retries to exhaustion and delivers
nothing, exactly as in 0.12.0. Any other value is rejected by
`StatifierOban.Config.new/1`.

Must change: **NONE**.

May start doing:

- **Set `unresolved_handler: :cancel` if you deploy handler code in a
  separate release from the one that enqueues invocations.** The job is
  then cancelled on the attempt that finds the handler missing, and the
  chart hears about it at once: `error.communication.invoke.<invoke_id>`
  with `reason: "invalid_handler"`, `detail` the handler name as stored,
  and `attempts` that attempt's own number. A transition on
  `error.communication` can re-enqueue the invocation once the handler is
  deployed. An unresolvable *delivery* module still retries under either
  value.
- **If you turn `:cancel` on, accept the new failure class wherever you
  match one exhaustively.** Your own `StatifierOban.Invoke.Delivery`
  module's `deliver_failure/3` (or `deliver_failure/4`) receives
  `reason: "invalid_handler"`, and
  a handler on `[:statifier_oban, :invoke, :failed]` sees the same
  `reason` with `handler` `nil`. Under the default `:retry` neither ever
  sees it.
- **Upgrade every node that runs the invoke queue before you turn
  `:cancel` on.** The policy travels in the job's meta, and a node still
  on 0.12.0 does not read it: a job it picks up retries as before.

The README's "Parking a job whose handler is missing" section and the
`StatifierOban.Config` documentation carry the detail.

## 0.13 to 0.14

0.14.0 adds one return to an invoke handler's `run/1` and `run/2`.
Must change: **NONE**. The returns a handler already gives mean what they
meant in 0.13.0, and nothing in `StatifierOban.Config`, the job rows, the
delivery behaviours or the telemetry events changes.

May start doing:

- **Return `:deferred` from a handler whose work runs somewhere else.** A
  handler that hands its work on - enqueued on another release's own Oban
  instance and queue, say - returns `:deferred` once the hand-off is made.
  The job completes without delivering, the invocation stays open, and the
  chart stays in its invoking state. Whoever finishes the work answers it
  later, by scope and invoke id, through the host's own
  `StatifierOban.Invoke.Delivery` implementation, the module the config
  names as `:invoke_delivery`: `deliver/3` for `done.invoke.<invoke_id>`,
  `deliver_failure/3` for `error.communication.invoke.<invoke_id>`.
  Implement `run/2` rather than `run/1` for this: its context carries the
  scope the answer needs.
- **Key the hand-off on the invoke id.** A handler's run is at least once,
  so a re-run of the job must not hand the work on twice; the README's
  example inserts the other release's job unique on the scope and the
  invoke id. Under a finite `:invoke_timeout` the bound covers the hand-off
  only, not the work handed on.
- **Give the chart its own deadline if the answer may never come.** While
  the answer is outstanding this package does nothing: no job waits, polls
  or times out on it. A deadline is the chart's own delayed send. Leaving
  the invoking state cancels the invocation through the ordinary cancel
  path, and a late answer for it is then dropped; telling the other
  release to stop is the host's to arrange.

The README's "Enqueue elsewhere, answer later" section and
[ADR-0009](https://github.com/riddler/statifier_oban/blob/main/docs/adr/0009-deferred-completion.md)
carry the detail.

## 0.14 to 0.15

0.15.0 adds one telemetry event, `[:statifier_oban, :invoke, :deferred]`,
emitted inside the invoke job when a handler's `run/1` or `run/2` answers
`:deferred`, and only then. `StatifierOban.Telemetry.events/0` lists it, so
the list grows from fourteen names to fifteen: the five
`[:statifier_oban, :timer, kind]` names and ten
`[:statifier_oban, :invoke, kind]` names.

Must change: **NONE** for a host none of whose invoke handlers answers
`:deferred`: the event is never emitted for it. Every other event keeps
its name, measurements and metadata.

- **If you attach one telemetry handler to every name in
  `StatifierOban.Telemetry.events/0` and match on the event name with no
  catch-all clause**, add a clause for `[:statifier_oban, :invoke,
  :deferred]` before a handler of yours answers `:deferred`. Its
  measurements are `system_time` and `attempt`, its metadata `scope`,
  `invoke_id`, `macrostep`, `handler`, `delivery` and `job_id`. Without
  the clause your telemetry handler raises on the event, and `:telemetry`
  detaches a handler that raises, so it stops hearing every other event
  as well.
- **If you run `opentelemetry_statifier`'s Oban bridge**, 0.8.0 is the
  first bridge that spans the new event. An older bridge attaches to its
  own list of events, which does not name it, so a deferred invocation
  gets no span there and nothing fails.

The `StatifierOban.Telemetry` documentation and
[telemetry.md](https://github.com/riddler/statifier_oban/blob/main/docs/telemetry.md)
carry the detail.

## 0.15 to 0.16

0.16.0 adds one option to `use StatifierOban.Invoke.Handler`:
`max_attempts:`. Must change: **NONE**. A handler that declares no cap
enqueues its jobs exactly as in 0.15.0, with the invoke worker's own
attempt count, Oban's default of 20.

May start doing:

- **Cap a handler whose work should not be repeated that often** with
  `use StatifierOban.Invoke.Handler, max_attempts: n`, `n` a positive
  integer. The permanent failure, `error.communication.invoke.<invoke_id>`,
  is then delivered on the capped attempt, so a chart that handles
  `error.communication` needs no new transition. The cap is written onto
  each job when it is enqueued: jobs stored before the change keep the
  count they were enqueued with.
- **Write the option as a literal keyword list in the `use` itself.** Any
  value but a positive integer fails the handler's compile. An argument
  that only holds a keyword list (a module attribute, a variable, a
  function call) is ignored whole and declares no cap, and so is a
  misspelt key; neither is an error, so check the handler's jobs carry
  the cap you meant.
- **If you cap a handler whose work cannot be keyed on `invoke_id`, give
  the chart its own deadline.** A node lost in the middle of the capped
  attempt leaves the job to `Oban.Plugins.Lifeline`, which discards a job
  with no attempts left without running it again and without delivering,
  so the chart hears nothing from this package.

The README's "Capping handler attempts" section and the
`StatifierOban.Invoke.Handler` documentation carry the detail.

## 0.16 to 0.17

0.17.0 adds one answer to `deliver/2` on a
`StatifierOban.Timer.Delivery` implementation: `{:snooze, seconds}`.
0.17.1 is documentation only; its `lib/` is 0.17.0's, and a host changes
nothing for it.

Must change: **NONE**. A delivery that answers `:delivered` or
`{:discarded, reason}`, or raises, means what it meant in 0.16.0, and the
default `StatifierOban.Timer.Delivery.Session` never answers a snooze.
`seconds` must be a positive integer: zero, a negative count and Oban's
period tuples match no clause, so each raises and retries, as every
snooze-shaped answer did in 0.16.0.

May start doing:

- **If your `Timer.Delivery` raises or discards on an execution parked by
  a chart migration, answer `{:snooze, seconds}` there instead.** Such an
  execution (`statifier_persistence`'s `step/5` answers
  `{:error, {:needs_migration, execution}}`) is neither live nor finished.
  A raise is retried, but each retry spends an attempt: the timer worker
  sets no `max_attempts`, so a park that outlasts Oban's default of 20
  attempts, twelve to thirteen and a half days under its default
  backoff, ends the job discarded by Oban, and the timer does not fire
  after the unpark. A
  `{:discarded, _}` answer cancels the timer for good. A snooze
  reschedules the job at least `seconds` later, spends no retry, and
  leaves it a pending timer that `StatifierOban.Timer.cancel/3` still
  reaches and `StatifierOban.Timer.pending_for/2` still counts.
- **Choose the period, and keep your own ceiling if you want one.** This
  package counts no snoozes and caps none, so a delivery that snoozes for
  as long as the park lasts keeps the timer pending that long. A short
  period re-reads your store often while the park lasts; a long one
  delays the event after the unpark by up to the period.

The README's "Delivering timers to a durable execution" section and the
`StatifierOban.Timer.Delivery` documentation carry the detail.

## Timers days out

Nothing on this page changes what a long timer needs from a host. A timer
that waits days is one Oban job row for all of that time;
[long-timers.md](https://github.com/riddler/statifier_oban/blob/main/docs/long-timers.md)
says what such a timer survives, what it does not, and the Oban settings
a host must keep for that to hold.
