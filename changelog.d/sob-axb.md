### Fixed

- `StatifierOban.Timer.cancel/3` and
  `StatifierOban.Invoke.Handler.perform_cancel/3` no longer name the
  `suspended` job state on an Oban older than 2.21.0, where Postgres rejected
  it for the `oban_job_state` enum and every cancel raised; the cancellable
  states are now taken from the installed Oban at call time, so the declared
  `~> 2.19` floor holds.
