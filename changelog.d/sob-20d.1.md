### Added

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
- `StatifierOban.Config` gains `:invoke_queue` (required before the first
  handler `perform/2`, no default - a missing queue is a typed error, never
  a silent fallback) and `:invoke_delivery` (defaults to the Session-backed
  seam).
