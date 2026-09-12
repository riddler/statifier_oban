### Changed

- `StatifierOban.Invoke.ChildStarter.start_child/5`'s first argument is named `parent_execution_id` rather than `parent_run_id`; the argument is positional, so an existing starter module compiles and behaves unchanged.
- Documentation calls the durable record a chart's progress is persisted against an *execution* rather than a *run* (`statifier_persistence` ADR-0011); no job argument, unique key, or telemetry event name or metadata key changes.
