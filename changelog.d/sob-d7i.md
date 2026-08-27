### Added

- `StatifierOban.Config` accepts an optional `:opaque_codec`, a module
  implementing the new `StatifierOban.OpaqueTerm.Codec` behaviour, that
  transforms the bytes of a job's host-opaque args (a timer's `data` and
  `caller_context`, an invoke's `params` and `content`) before they are
  stored. The default (`nil`) is unchanged: today's plain Base64 encoding.
  For most hosts, passing entity ids instead of values and re-fetching at
  execution time remains the recommended shape - see the README's
  "Sensitive values in job args" section.
