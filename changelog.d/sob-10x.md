### Added

- An async invocation's `caller_context` is stored on its Oban job row and
  handed back when the invocation is answered, so a completion days later
  still links to the trace that started it.
- `StatifierOban.Invoke.Delivery` gains optional `deliver/4` and
  `deliver_failure/4`, which receive that `caller_context` for a
  process-less host building the answer event itself; implementations
  defining only the three-argument doors are called exactly as before.
