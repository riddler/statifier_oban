### Added

- `StatifierOban.Config` takes `:invoke_timeout`, `:child_start_timeout` and `:timer_timeout` (milliseconds or `:infinity`, default `:infinity`), a per-attempt run-time bound for each job kind; a timed-out invoke's last attempt delivers `error.communication.invoke.<invoke_id>` with `reason: "run_crashed"`.
