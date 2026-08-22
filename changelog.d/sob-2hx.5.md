### Added

- Fired timer jobs now deliver: `StatifierOban.Timer.Worker` feeds the
  stored event back through a `StatifierOban.Timer.Delivery` module,
  behind the run-liveness check st-ADR-0054 decision 4 requires - a run
  that is not live discards the event (spec 6.2), recorded on the
  cancelled job as `{:discarded, reason}`. The default
  (`StatifierOban.Timer.Delivery.Session`, configurable via
  `StatifierOban.Config`'s new `:delivery` option) checks a live
  `Statifier.Session` in two steps - registry lookup, then `status/1` -
  so a halted-but-alive session discards rather than queueing.
