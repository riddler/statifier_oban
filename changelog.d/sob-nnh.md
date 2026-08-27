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

### Changed

- **Breaking for hosts implementing `StatifierOban.Invoke.Delivery`
  themselves:** the behaviour gains a required `deliver_failure/3` callback,
  and a delivery module that does not export it no longer resolves - its jobs
  retry with `{:error, {:invalid_delivery, name}}`. Add `deliver_failure/3`
  alongside your `deliver/3`, running the same liveness check and reporting the
  failure to the run. Hosts using the default
  `StatifierOban.Invoke.Delivery.Session` need no change.
- This package now requires a `statifier` carrying
  `Statifier.Session.failed_invocation/3` (st-ADR-0068).
