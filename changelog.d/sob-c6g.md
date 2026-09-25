### Added

- An invoke handler's `run/1` or `run/2` may return `:deferred`: the job completes without delivering, the invocation stays open, and whoever finishes the work answers it later through the host's `StatifierOban.Invoke.Delivery` implementation (`deliver/3` or `deliver_failure/3`) by scope and invoke id.
