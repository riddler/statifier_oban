defmodule StatifierOban.OpaqueTerm.Codec do
  @moduledoc """
  A host-supplied transform over the bytes of an opaque job-arg payload.

  `StatifierOban.OpaqueTerm.encode/2` accepts a module implementing this
  behaviour and runs its `encode/1` over the `:erlang.term_to_binary/1`
  bytes before they are Base64-encoded onto the row; `decode_field/2` runs
  the matching `decode/1` on the way back, before `binary_to_term`. Neither
  side of `StatifierOban.OpaqueTerm` prescribes what a codec does with the
  bytes - only that it round-trips them.

  Implementations MUST satisfy, for every binary `b`:

      {:ok, encoded} = MyCodec.encode(b)
      {:ok, ^b} = MyCodec.decode(encoded)

  byte-identical, on any node that can read the row, for as long as a
  stored job can live - which, for a durable timer or a slow-to-complete
  invoke, can be days. `encode/1` need not be deterministic (a codec that
  authenticates its own output typically is not), but `decode/1` must
  accept every value its own `encode/1` ever produced, on every node that
  will read the row.

  The module's own name travels on the row, under the `"codec"` tag
  `StatifierOban.OpaqueTerm` writes next to the encoded payload, so a
  reading node resolves it back the same way `StatifierOban.Timer.Worker`
  resolves its delivery module. That has two consequences a host must
  plan for:

  - **The module must stay resolvable.** Renaming or removing a codec a
    stored row still names turns every future decode of that row into
    `{:error, {:invalid_codec, field, name}}` - not a crash, but a row
    the host can no longer read.
  - **Key rotation is the codec's job, not this seam's.** A codec that
    carries its own key material (a key id, a nonce, a version byte)
    inside the bytes it returns from `encode/1` can rotate freely:
    `decode/1` reads whatever it needs to reverse itself back out of
    those bytes. `StatifierOban.OpaqueTerm` stores only the module name
    and treats the bytes themselves as opaque in both directions.

  A codec is called at exactly one boundary in this library (this
  module's internal `apply_codec/3` in `StatifierOban.OpaqueTerm`), which
  catches a raise or exit from either callback and turns it into a typed
  error rather than crashing the job - a host codec failing is a fact the
  caller decides what to do with, never a silent fall-back to storing the
  bytes untransformed.
  """

  @doc """
  Transforms `binary` before it is stored. Any two-way byte transform is
  valid, as long as `decode/1` reverses it exactly.
  """
  @callback encode(binary()) :: {:ok, binary()} | {:error, term()}

  @doc """
  Reverses `encode/1`, byte-identical, on any node that resolves this
  module.
  """
  @callback decode(binary()) :: {:ok, binary()} | {:error, term()}
end
