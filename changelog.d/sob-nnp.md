### Added

- `StatifierOban.Config` takes `:unresolved_handler` (`:retry`, the default, or `:cancel`); under `:cancel` an invoke job whose handler module does not resolve cancels on the attempt that finds it and delivers `error.communication.invoke.<invoke_id>` with `reason: "invalid_handler"` instead of retrying to exhaustion.
