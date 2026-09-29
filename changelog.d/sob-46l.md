### Added

- A `StatifierOban.Timer.Delivery` implementation may answer `deliver/2` with `{:snooze, seconds}` (`seconds` a positive integer): the timer job is rescheduled at least `seconds` later without spending a retry and stays a pending, cancellable timer, so a delivery can hold the timer of an execution a chart migration parked instead of raising; any other snooze-shaped answer raises and retries as before.
