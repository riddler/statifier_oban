defmodule StatifierOban.EffectGenerators do
  @moduledoc "StreamData generators for the two effects this package consumes."

  import StreamData

  alias Statifier.Effect.{Cancel, SendDelayed}

  @spec scope() :: StreamData.t(String.t())
  def scope, do: string(:alphanumeric, min_length: 1, max_length: 12)

  @spec send_id() :: StreamData.t(String.t())
  def send_id, do: string(:alphanumeric, min_length: 1, max_length: 8)

  @spec counter() :: StreamData.t(non_neg_integer())
  def counter, do: integer(0..20)

  @spec ordinal() :: StreamData.t(pos_integer())
  def ordinal, do: integer(1..20)

  @spec owner() :: StreamData.t(Statifier.Machine.Content.owner() | nil)
  def owner do
    one_of([
      tuple({constant(:onentry), counter(), counter()}),
      tuple({constant(:onexit), counter(), counter()}),
      tuple({constant(:transition), counter()}),
      tuple({constant(:finalize), counter(), counter()}),
      constant(nil)
    ])
  end

  @spec send_delayed() :: StreamData.t(SendDelayed.t())
  def send_delayed do
    fixed_map(%{
      event: string(:alphanumeric, min_length: 1, max_length: 8),
      target: constant(nil),
      type: constant(nil),
      data: one_of([constant(nil), string(:alphanumeric, max_length: 8), integer(0..100)]),
      send_id: send_id(),
      delay_ms: integer(0..86_400_000),
      c_index: one_of([counter(), constant(nil)]),
      owner: owner(),
      macrostep: counter(),
      microstep: counter(),
      round: counter(),
      ordinal: ordinal(),
      id_from_author?: boolean()
    })
    |> map(&struct!(SendDelayed, &1))
  end

  @spec cancel() :: StreamData.t(Cancel.t())
  def cancel do
    fixed_map(%{
      send_id: send_id(),
      c_index: one_of([counter(), constant(nil)]),
      owner: owner(),
      macrostep: counter(),
      microstep: counter(),
      round: counter(),
      ordinal: ordinal()
    })
    |> map(&struct!(Cancel, &1))
  end
end
