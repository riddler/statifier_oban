defmodule StatifierOban.Timer.CancellationKey do
  @moduledoc """
  `{session scope, send_id}` - the key a cancel addresses.

  Deliberately not unique: spec 6.3 cancels every delayed send under a
  sendid, and an author-written `id` is reused verbatim without advancing
  `send_counter`, so one `<send id="x" delay="...">` executed twice stores
  two rows under one key. A cancel matching nothing is a no-op, not an
  error (ADR-0054 decision 3).

  ADR-0059 leaves this key untouched where it amends the dedup key: spec
  6.3's cancel-them-all semantics is exactly what the pair exists to express.
  """

  @enforce_keys [:scope, :send_id]
  defstruct [:scope, :send_id]

  @type t :: %__MODULE__{scope: String.t(), send_id: String.t()}
end
