### Fixed

- A re-entered state's authored invoke id schedules a fresh Oban job
  instead of being deduped against a previous entry's job: invoke jobs
  are now unique on `{scope, invoke_id, macrostep}` rather than
  `{scope, invoke_id}`. Crash replays still dedup; cancellation still
  matches every job under `{scope, invoke_id}`.
