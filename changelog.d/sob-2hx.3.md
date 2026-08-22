### Added

- `StatifierOban.Timer.schedule/3` consumes a `%Statifier.Effect.SendDelayed{}`
  into one Oban job on the host's instance, unique on the `{scope, ordinal}`
  dedup key across every job state, with the fire time computed at insert
  from the relative `delay_ms`. Only `nil`-target sends are schedulable
  (st-ADR-0055); a duplicate insert is a conflict no-op.

### Changed

- `StatifierOban.Config.new/1` now also requires `:timers_queue` - the host
  queue timer jobs target. Like `:oban`, it has no default.
