### Added

- Three fan-out telemetry events, taking `StatifierOban.Telemetry.events/0` from eleven names to fourteen: `[:statifier_oban, :invoke, :fan_out]` when an invocation's N child starts are stored, `[:statifier_oban, :invoke, :child_started]` when the host's `ChildStarter` seam creates one child, and `[:statifier_oban, :invoke, :unstarted_cancelled]` when a `first_error` cancel sweeps the starts that had not run. A fan-out was previously invisible in this stream: it delivers nothing, so no `:delivered` event fired for it, and a cancelled sibling was reported nowhere at all (ADR-0006's 2026-09-06 amendment).

### Changed

- `StatifierOban.Invoke.FanOut.start/5` returns `{:ok, summary}` rather than `:ok` on success, where `summary` is `%{count:, policy:, queue:}` - what the caller needs to emit `[:statifier_oban, :invoke, :fan_out]` without reading the invocation's `on` parameter a second time. `{:empty, []}`, `{:refused, _}` and `{:error, _}` are unchanged.
