### Added

- `StatifierOban.Config` takes `:invoke_timeout`, `:child_start_timeout` and `:timer_timeout` (milliseconds up to the BEAM's `4_294_967_295` ms timeout limit, less the 5000 ms backstop for `:invoke_timeout`, or `:infinity`, the default), a per-attempt run-time bound for each job kind; a timed-out invoke's last attempt delivers `error.communication.invoke.<invoke_id>` with `reason: "run_crashed"`.
