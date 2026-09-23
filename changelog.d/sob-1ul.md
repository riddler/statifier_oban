### Added

- `use StatifierOban.Timer.PinSource, config: {module, function}` makes a host module a `StatifierPersistence.PinSource` that answers `%{timers: n}`, the timers still pending under the executions it is asked about; the module is compiled only when `statifier_persistence`, now an optional dependency (`~> 0.13`), is present.
