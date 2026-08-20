defmodule StatifierOban.Timer.DedupKey do
  @moduledoc """
  `{session scope, send_id, macrostep, microstep, round, c_index, owner}` -
  read off the stored `%Statifier.Effect.SendDelayed{}` (ADR-0054
  decision 3).

  Every component is a deterministic counter or a static content position,
  stamped as of scheduling rather than firing (ADR-0046), so re-executing
  the same drive after a crash rebuilds a byte-identical key. `c_index` and
  `owner` are mandatory members, not decoration: without them two
  `<send id="x" delay="...">` in one `<onentry>` collapse into one row.
  """

  alias Statifier.Machine.Content

  @enforce_keys [:scope, :send_id, :macrostep, :microstep, :round, :c_index, :owner]
  defstruct [:scope, :send_id, :macrostep, :microstep, :round, :c_index, :owner]

  @type t :: %__MODULE__{
          scope: String.t(),
          send_id: String.t(),
          macrostep: non_neg_integer(),
          microstep: non_neg_integer(),
          round: non_neg_integer(),
          c_index: non_neg_integer() | nil,
          owner: Content.owner() | nil
        }
end
