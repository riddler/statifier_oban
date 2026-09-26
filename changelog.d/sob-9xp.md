### Added

- A `[:statifier_oban, :invoke, :deferred]` telemetry event, taking `StatifierOban.Telemetry.events/0` from fourteen names to fifteen: emitted inside the invoke job when `run/1` or `run/2` answers `:deferred`, with measurements `system_time` and `attempt` and metadata `scope`, `invoke_id`, `macrostep`, `handler`, `delivery` and `job_id`. A deferred invocation was previously silent in this stream after `:enqueued` (ADR-0006's 2026-09-26 amendment).
