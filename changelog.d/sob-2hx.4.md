### Added

- `StatifierOban.Timer.cancel/3` consumes a `%Statifier.Effect.Cancel{}`
  into cancellation of every timer job stored under the `{scope, send_id}`
  cancellation key - several jobs may match, per spec 6.3. A cancel
  matching nothing returns `{:ok, 0}`, a no-op rather than an error. A
  cancel racing execution resolves to whichever transition commits first:
  a job already in a terminal state keeps its outcome and is not counted.
