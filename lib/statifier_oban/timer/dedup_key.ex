defmodule StatifierOban.Timer.DedupKey do
  @moduledoc """
  `{session scope, ordinal}` - the compact dedup key ADR-0059 decision 3
  blesses, read off the stored `%Statifier.Effect.SendDelayed{}`.

  ADR-0059 amended ADR-0054 decision 3: `%SendDelayed{}` and `%Cancel{}`
  carry a per-execution `ordinal` minted from a session-global, monotone
  counter, so `{session scope, ordinal}` is unique on its own. This package
  stores that pair as the key; the remaining components of the documented
  compound form - `send_id`, `macrostep`, `microstep`, `round`, `c_index`,
  `owner` - stay row data on the stored effect rather than key components.
  Both forms are conformant; the compound form remains upstream's documented
  default because it is self-describing in a store, and this package keeps
  that self-description by storing the effect itself alongside the key.

  Both components are deterministic as of scheduling rather than firing:
  the ordinal is pure fold state (ADR-0059 decision 2), so re-executing the
  same drive after a crash rebuilds a byte-identical key. Cancellation never
  addresses this key - spec 6.3 cancels every timer under a sendid, and
  `send_id` is row data here, so a cancel matches rows via
  `StatifierOban.Timer.Key.cancels?/3`.
  """

  @enforce_keys [:scope, :ordinal]
  defstruct [:scope, :ordinal]

  @type t :: %__MODULE__{
          scope: String.t(),
          ordinal: pos_integer()
        }
end
