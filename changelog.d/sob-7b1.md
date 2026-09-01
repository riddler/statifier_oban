### Added

- An invoke handler may define `run/2` instead of `run/1` and receive the run's
  scope alongside the invoke effect, so work keyed to the workflow instance can
  be written against the Oban handler base.
