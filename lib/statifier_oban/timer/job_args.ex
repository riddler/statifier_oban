defmodule StatifierOban.Timer.JobArgs do
  @moduledoc """
  The wire shape between a `%Statifier.Effect.SendDelayed{}` and the args
  map an Oban job stores.

  Oban args live as JSON, so this module owns the (de)serialization of the
  one effect a timer job carries, plus the scope it was scheduled under.
  Two rules shape it:

  - Every deterministic field rides as an explicit JSON value: the dedup
    pair (`scope`, `ordinal`) at the top level - Oban's uniqueness `keys`
    read args at the top level - and the row data ADR-0059 (statifier-ex)
    keeps beside the key (`send_id`, `macrostep`, `microstep`, `round`,
    `c_index`, `owner`), self-describing in the store during an incident.
  - The two host-opaque fields, `data` and `caller_context`, are arbitrary
    terms with no JSON shape, so they ride as tagged
    `:erlang.term_to_binary/1` payloads (Base64) and come back
    byte-identical. `caller_context` stays row data, never a key component
    (st-ADR-0063 decision 6). Decoding uses `:safe`, so a payload naming
    an atom the reading node has never seen decodes to a typed error
    rather than minting atoms.

  `to_effect/1` is the exact inverse of `from_effect/2` for every
  `%SendDelayed{}` the scheduler accepts: what the fired job carries is
  enough to rebuild the event and its position, per ADR-0054's
  correlation rule - position is read off the stored effect, never
  recomputed at delivery.
  """

  alias Statifier.Effect.SendDelayed

  @term_tag "t2b64"

  @typedoc "String-keyed args map as Oban stores and redelivers it."
  @type args :: %{optional(String.t()) => term()}

  @type decode_error ::
          {:missing_field, String.t()}
          | {:invalid_field, String.t(), term()}

  @doc """
  Builds the args map for a timer job from the scope and the effect.

  The caller has already validated the scope and ordinal via
  `StatifierOban.Timer.Key.dedup_key/2`; this function only lays fields
  out on the wire.
  """
  @spec from_effect(String.t(), SendDelayed.t()) :: args()
  def from_effect(scope, %SendDelayed{} = effect) when is_binary(scope) do
    %{
      "scope" => scope,
      "ordinal" => effect.ordinal,
      "event" => effect.event,
      "target" => effect.target,
      "type" => effect.type,
      "data" => encode_term(effect.data),
      "send_id" => effect.send_id,
      "delay_ms" => effect.delay_ms,
      "c_index" => effect.c_index,
      "owner" => encode_owner(effect.owner),
      "macrostep" => effect.macrostep,
      "microstep" => effect.microstep,
      "round" => effect.round,
      "id_from_author" => effect.id_from_author?,
      "caller_context" => encode_term(effect.caller_context)
    }
  end

  @doc """
  Rebuilds the scope and the `%SendDelayed{}` from a job's args.

  Returns a typed error rather than raising: an undecodable job is a
  fact about the row, and the worker decides what to do with it.
  """
  @spec to_effect(args()) :: {:ok, String.t(), SendDelayed.t()} | {:error, decode_error()}
  def to_effect(args) when is_map(args) do
    with {:ok, scope} <- fetch_binary(args, "scope"),
         {:ok, ordinal} <- fetch_pos_integer(args, "ordinal"),
         {:ok, event} <- fetch_binary(args, "event"),
         {:ok, delay_ms} <- fetch_non_neg_integer(args, "delay_ms"),
         {:ok, macrostep} <- fetch_non_neg_integer(args, "macrostep"),
         {:ok, microstep} <- fetch_non_neg_integer(args, "microstep"),
         {:ok, round} <- fetch_non_neg_integer(args, "round"),
         {:ok, data} <- decode_term_field(args, "data"),
         {:ok, caller_context} <- decode_term_field(args, "caller_context"),
         {:ok, owner} <- decode_owner_field(args, "owner") do
      {:ok, scope,
       %SendDelayed{
         event: event,
         target: Map.get(args, "target"),
         type: Map.get(args, "type"),
         data: data,
         send_id: Map.get(args, "send_id"),
         delay_ms: delay_ms,
         c_index: Map.get(args, "c_index"),
         owner: owner,
         macrostep: macrostep,
         microstep: microstep,
         round: round,
         ordinal: ordinal,
         id_from_author?: Map.get(args, "id_from_author", false),
         caller_context: caller_context
       }}
    end
  end

  # -- owner: a small closed union (Statifier.Machine.Content.owner/0), so
  # it rides as a plain JSON list with the tag as a string.

  @spec encode_owner(SendDelayed.owner() | nil) :: [String.t() | non_neg_integer()] | nil
  defp encode_owner(nil), do: nil
  defp encode_owner({:onentry, a, b}), do: ["onentry", a, b]
  defp encode_owner({:onexit, a, b}), do: ["onexit", a, b]
  defp encode_owner({:finalize, a, b}), do: ["finalize", a, b]
  defp encode_owner({:transition, t_index}), do: ["transition", t_index]

  @spec decode_owner_field(args(), String.t()) ::
          {:ok, SendDelayed.owner() | nil} | {:error, decode_error()}
  defp decode_owner_field(args, field) do
    case Map.get(args, field) do
      nil -> {:ok, nil}
      value -> decode_owner(field, value)
    end
  end

  @owner_block_tags %{"onentry" => :onentry, "onexit" => :onexit, "finalize" => :finalize}

  @spec decode_owner(String.t(), term()) ::
          {:ok, SendDelayed.owner()} | {:error, decode_error()}
  defp decode_owner(_field, [tag, a, b])
       when is_map_key(@owner_block_tags, tag) and is_integer(a) and is_integer(b) do
    {:ok, {Map.fetch!(@owner_block_tags, tag), a, b}}
  end

  defp decode_owner(_field, ["transition", t]) when is_integer(t), do: {:ok, {:transition, t}}
  defp decode_owner(field, other), do: {:error, {:invalid_field, field, other}}

  # -- opaque terms: tagged term_to_binary payloads. nil stays nil, so the
  # common case costs nothing and stays readable in the row.

  @spec encode_term(term()) :: nil | %{String.t() => String.t()}
  defp encode_term(nil), do: nil

  defp encode_term(term),
    do: %{@term_tag => Base.encode64(:erlang.term_to_binary(term))}

  @spec decode_term_field(args(), String.t()) :: {:ok, term()} | {:error, decode_error()}
  defp decode_term_field(args, field) do
    case Map.get(args, field) do
      nil -> {:ok, nil}
      %{@term_tag => encoded} when is_binary(encoded) -> decode_term(field, encoded)
      other -> {:error, {:invalid_field, field, other}}
    end
  end

  @spec decode_term(String.t(), String.t()) :: {:ok, term()} | {:error, decode_error()}
  defp decode_term(field, encoded) do
    case Base.decode64(encoded) do
      {:ok, binary} -> safe_binary_to_term(field, binary)
      :error -> {:error, {:invalid_field, field, encoded}}
    end
  end

  @spec safe_binary_to_term(String.t(), binary()) :: {:ok, term()} | {:error, decode_error()}
  defp safe_binary_to_term(field, binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    # :safe rejects a payload naming atoms this node has never seen, and a
    # corrupt binary raises too - both are facts about the row, returned
    # as data rather than crashed on (this is the boundary, not a leaf).
    ArgumentError -> {:error, {:invalid_field, field, binary}}
  end

  # -- required scalar fields

  @spec fetch_binary(args(), String.t()) :: {:ok, String.t()} | {:error, decode_error()}
  defp fetch_binary(args, field) do
    case Map.get(args, field) do
      value when is_binary(value) and value != "" -> {:ok, value}
      nil -> {:error, {:missing_field, field}}
      other -> {:error, {:invalid_field, field, other}}
    end
  end

  @spec fetch_pos_integer(args(), String.t()) ::
          {:ok, pos_integer()} | {:error, decode_error()}
  defp fetch_pos_integer(args, field) do
    case Map.get(args, field) do
      value when is_integer(value) and value >= 1 -> {:ok, value}
      nil -> {:error, {:missing_field, field}}
      other -> {:error, {:invalid_field, field, other}}
    end
  end

  @spec fetch_non_neg_integer(args(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, decode_error()}
  defp fetch_non_neg_integer(args, field) do
    case Map.get(args, field) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      nil -> {:error, {:missing_field, field}}
      other -> {:error, {:invalid_field, field, other}}
    end
  end
end
