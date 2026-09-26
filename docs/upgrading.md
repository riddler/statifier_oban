# Upgrading a host from 0.11 to 0.14

This page says what a host changes to move `statifier_oban` from 0.11.0 to
0.12.0, from 0.12.0 to 0.13.0, and from 0.13.0 to 0.14.0. A host
here is the code that embeds the package: the `StatifierOban.Config` it
builds, the Oban instance and queues it runs the jobs on, its invoke
handlers, any `StatifierOban.Timer.Delivery` or
`StatifierOban.Invoke.Delivery` module of its own, and the telemetry
handlers it attaches. What each release added is in
[CHANGELOG.md](../CHANGELOG.md); this page lists only what a host has to do
about it, and says **NONE** where the answer is nothing.

Move the pin with each minor, as the README recommends:
`{:statifier_oban, "~> 0.14.0"}`. The `statifier` requirement (`~> 2.5`)
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
leaves room for the invoke worker's 5-second backstop; `Config.new/1`
rejects a larger integer, zero, or anything else with
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

The README's "Bounding a job's run time" section and the
`StatifierOban.Config` documentation carry the detail.

### Parking an invoke job whose handler is missing

`StatifierOban.Config.new/1` takes `:unresolved_handler`, `:retry` or
`:cancel`, and defaults to `:retry`. Under `:retry` an invoke job whose
handler module does not resolve retries to exhaustion and delivers
nothing, exactly as in 0.12.0. Any other value is rejected by
`Config.new/1`.

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
[ADR-0009](adr/0009-deferred-completion.md) carry the detail.

## Timers days out

Nothing on this page changes what a long timer needs from a host. A timer
that waits days is one Oban job row for all of that time;
[long-timers.md](long-timers.md) says what such a timer survives, what it
does not, and the Oban settings a host must keep for that to hold.
