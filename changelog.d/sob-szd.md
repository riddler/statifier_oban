### Added

- An invoke handler can cap its own attempts with `use StatifierOban.Invoke.Handler, max_attempts: n`; its jobs carry `n` as `max_attempts`, the permanent-failure event is delivered on the capped attempt, and a handler that declares no cap keeps Oban's default.
