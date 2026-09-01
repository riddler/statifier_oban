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
    `:erlang.term_to_binary/1` payloads (`StatifierOban.OpaqueTerm`) and come back
    byte-identical. `caller_context` stays row data, never a key component
    (st-ADR-0063 decision 6). Decoding uses `:safe`, so a payload naming
    an atom the reading node has never seen decodes to a typed error
    rather than minting atoms. `from_effect/3`'s optional codec runs over
    both fields' bytes and tags the payload with its module name
    (`StatifierOban.OpaqueTerm.Codec`); `to_effect/1` reads whatever tag
    the stored row carries, regardless of what the reading caller passed.

  `to_effect/1` is the exact inverse of `from_effect/3` for every
  `%SendDelayed{}` the scheduler accepts: what the fired job carries is
  enough to rebuild the event and its position, per ADR-0054's
  correlation rule - position is read off the stored effect, never
  recomputed at delivery.

  ## What a host may durably put in `caller_context`

  Byte-identical is not the same as meaningful. The row outlives the node
  that wrote it - that is the whole point of the package - so two rules
  bind what a host stamps into the slot, and this module enforces neither
  because it never reads the term:

  - **Nothing node-local.** A pid, a port, a reference, an ETS table id,
    or a monitor ref comes back as a term that decodes fine and refers to
    nothing. There is no error to raise; the value is simply a lie by the
    time it is read.
  - **Nothing whose atoms the reading node may not have seen.** Decoding
    is `:safe`, so a payload naming an unknown atom is a typed decode
    error rather than a minted atom, and an undecodable row is cancelled
    (`{:undecodable, _}`) rather than retried. A term carrying a library's
    internal atoms therefore couples delivery to that library being
    loaded on whichever node happens to run the job.

  For the tracing case both rules point the same way, and this is the
  shape the family expects: serialize at schedule time to the **W3C Trace
  Context text form** - `%{"traceparent" => "00-<trace-id>-<span-id>-01"}`
  plus `"tracestate"` where the host propagates one - rather than storing
  a live span context or an OTel context map. Strings and string keys
  carry no atoms and nothing node-local, the encoding is fixed by a
  published spec instead of a library version, and the value stays
  readable in the row during an incident. Restoring it is
  `opentelemetry_statifier`'s: this package hands the term back exactly as
  given (`StatifierOban.Timer.Delivery.fired_event/2`) and reads nothing
  out of it (ADR-0006 decision 7).
  """

  alias Statifier.Effect.SendDelayed
  alias StatifierOban.OpaqueTerm

  @typedoc "String-keyed args map as Oban stores and redelivers it."
  @type args :: %{optional(String.t()) => term()}

  @type decode_error ::
          {:missing_field, String.t()}
          | {:invalid_field, String.t(), term()}
          | OpaqueTerm.decode_error()

  @typedoc "Why `from_effect/3` could not build an args map."
  @type encode_error :: {:codec_failed, String.t(), OpaqueTerm.encode_error()}

  @doc """
  Builds the args map for a timer job from the scope and the effect.

  The caller has already validated the scope and ordinal via
  `StatifierOban.Timer.Key.dedup_key/2`; this function only lays fields
  out on the wire. `data` and `caller_context` are encoded through a
  `with`, so the first codec failure short-circuits and no
  partially-encoded args map is ever returned.
  """
  @spec from_effect(String.t(), SendDelayed.t(), module() | nil) ::
          {:ok, args()} | {:error, encode_error()}
  def from_effect(scope, %SendDelayed{} = effect, codec \\ nil) when is_binary(scope) do
    with {:ok, data} <- encode_term("data", effect.data, codec),
         {:ok, caller_context} <- encode_term("caller_context", effect.caller_context, codec) do
      {:ok,
       %{
         "scope" => scope,
         "ordinal" => effect.ordinal,
         "event" => effect.event,
         "target" => effect.target,
         "type" => effect.type,
         "data" => data,
         "send_id" => effect.send_id,
         "delay_ms" => effect.delay_ms,
         "c_index" => effect.c_index,
         "owner" => encode_owner(effect.owner),
         "macrostep" => effect.macrostep,
         "microstep" => effect.microstep,
         "round" => effect.round,
         "id_from_author" => effect.id_from_author?,
         "caller_context" => caller_context
       }}
    end
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

  # The encoding itself lives in `StatifierOban.OpaqueTerm`, shared with
  # `StatifierOban.Invoke.JobArgs` so both job kinds' rows stay mutually
  # readable during an incident.

  @spec encode_term(String.t(), term(), module() | nil) ::
          {:ok, nil | %{String.t() => String.t()}} | {:error, encode_error()}
  defp encode_term(field, term, codec) do
    case OpaqueTerm.encode(term, codec) do
      {:ok, payload} -> {:ok, payload}
      {:error, reason} -> {:error, {:codec_failed, field, reason}}
    end
  end

  @spec decode_term_field(args(), String.t()) :: {:ok, term()} | {:error, decode_error()}
  defp decode_term_field(args, field), do: OpaqueTerm.decode_field(args, field)

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
