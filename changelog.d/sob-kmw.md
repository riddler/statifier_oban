### Added

- `StatifierOban.Telemetry` emits eleven `[:statifier_oban, ...]` events across
  the scheduling and delivery seams, with `events/0` returning the full list
  for `:telemetry.attach_many/4` (ADR-0006, `docs/telemetry.md`).
