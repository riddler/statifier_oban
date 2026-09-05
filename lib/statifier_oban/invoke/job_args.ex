defmodule StatifierOban.Invoke.JobArgs do
  @moduledoc """
  The wire shape between a `%Statifier.Effect.Invoke{}` and the args map
  an invoke-handler Oban job stores.

  Oban args live as JSON, so this module owns the (de)serialization of
  the one effect an invoke job carries, plus the scope it was enqueued
  under and the handler module whose `run/1` the worker calls back into.
  The rules are `StatifierOban.Timer.JobArgs`'s, applied to the invoke
  effect:

  - Every deterministic field rides as an explicit JSON value: the dedup
    triple (`scope`, `invoke_id`, `macrostep` - ADR-0003) at the top
    level - Oban's uniqueness `keys` read args at the top level - and
    the effect's remaining position row data (`state_index`,
    `invoke_index`, `microstep`, `round`) beside it, self-describing in
    the store during an incident. `invoke_id` is the authored id used
    verbatim, or the deterministic `%MachineState{}` counter,
    st-ADR-0008 (as amended) blesses as the idempotency key; scoping is
    mandatory because that counter restarts per chart run, and
    `macrostep` is what tells a state re-entry's fresh invocation apart
    from a crash replay of the old one.
  - The three host-opaque fields, `params`, `content` and
    `caller_context`, are arbitrary terms with no JSON shape, so they
    ride as tagged
    `:erlang.term_to_binary/1` payloads (`StatifierOban.OpaqueTerm`) and
    come back byte-identical. `from_invoke/4`'s optional codec runs over
    both fields' bytes and tags the payload with its module name
    (`StatifierOban.OpaqueTerm.Codec`); `to_invoke/1` reads whatever tag
    the stored row carries, regardless of what the reading caller passed.
    `caller_context` is `st-ADR-0063`'s opaque host slot, stamped by the
    macrostep that executed the `<invoke>`; it is stored so the answer
    event can inherit it days later on another node, and the two
    durability rules `StatifierOban.Timer.JobArgs` states for the timer
    half bind a host's choice of term here identically. A row written
    before this field existed carries no `"caller_context"` key and
    decodes to `nil`, which is `st-ADR-0063`'s own "no context
    attached" - so the field is additive over stored rows, not a
    migration.
  - `handler` is the module name of the `StatifierOban.Invoke.Handler`
    implementation, written from a validated module at enqueue time and
    resolved back by the worker - a resolution failure there is
    deploy-shaped (the module was renamed or removed after the job was
    stored) and retries, exactly like the timer worker's delivery module.

  A **fan-out child start** job stores the same map with two fields
  added, `for_child_start/3`'s `"index"` and `"child_count"` (ADR-0007
  decision 4). The base map is unchanged by that widening, so a start
  job's row decodes through `to_invoke/1` exactly as an ordinary invoke
  job's does and the two kinds stay mutually readable during an
  incident.

  `to_invoke/1` is the exact inverse of `from_invoke/4` for every
  `%Statifier.Effect.Invoke{}` the base handler enqueues: what the job
  carries is enough to hand the handler's `run/1` the same effect the
  planning callback saw.
  """

  alias Statifier.Effect.Invoke
  alias StatifierOban.OpaqueTerm

  @typedoc "String-keyed args map as Oban stores and redelivers it."
  @type args :: %{optional(String.t()) => term()}

  @type decode_error ::
          {:missing_field, String.t()}
          | {:invalid_field, String.t(), term()}
          | OpaqueTerm.decode_error()

  @typedoc "Why `from_invoke/4` could not build an args map."
  @type encode_error :: {:codec_failed, String.t(), OpaqueTerm.encode_error()}

  @doc """
  Builds the args map for an invoke job from the scope, the handler
  module, and the effect.

  The caller (`StatifierOban.Invoke.Handler.perform_start/3`) has already
  validated the scope; this function only lays fields out on the wire.
  `params` and `content` are encoded through a `with`, so the first codec
  failure short-circuits and no partially-encoded args map is ever
  returned.
  """
  @spec from_invoke(String.t(), module(), Invoke.t(), module() | nil) ::
          {:ok, args()} | {:error, encode_error()}
  def from_invoke(scope, handler, %Invoke{} = invoke, codec \\ nil)
      when is_binary(scope) and is_atom(handler) do
    with {:ok, params} <- encode_term("params", invoke.params, codec),
         {:ok, content} <- encode_term("content", invoke.content, codec),
         {:ok, caller_context} <-
           encode_term("caller_context", invoke.caller_context, codec) do
      {:ok,
       %{
         "scope" => scope,
         "invoke_id" => invoke.invoke_id,
         "handler" => Atom.to_string(handler),
         "type" => invoke.type,
         "src" => invoke.src,
         "params" => params,
         "content" => content,
         "caller_context" => caller_context,
         "autoforward" => invoke.autoforward,
         "state_index" => invoke.state_index,
         "invoke_index" => invoke.invoke_index,
         "macrostep" => invoke.macrostep,
         "microstep" => invoke.microstep,
         "round" => invoke.round
       }}
    end
  end

  @doc """
  Rebuilds the scope, the handler module name, and the
  `%Statifier.Effect.Invoke{}` from a job's args.

  The handler comes back as the stored string, not a resolved module:
  resolution is the worker's call, because an unresolvable name is a
  retryable environment fact where every error here is a fact about the
  row. Returns a typed error rather than raising: an undecodable job is
  a fact about the row, and the worker decides what to do with it.
  """
  @spec to_invoke(args()) ::
          {:ok, String.t(), String.t(), Invoke.t()} | {:error, decode_error()}
  def to_invoke(args) when is_map(args) do
    with {:ok, scope} <- fetch_binary(args, "scope"),
         {:ok, invoke_id} <- fetch_binary(args, "invoke_id"),
         {:ok, handler} <- fetch_binary(args, "handler"),
         {:ok, state_index} <- fetch_non_neg_integer(args, "state_index"),
         {:ok, invoke_index} <- fetch_non_neg_integer(args, "invoke_index"),
         {:ok, macrostep} <- fetch_non_neg_integer(args, "macrostep"),
         {:ok, microstep} <- fetch_non_neg_integer(args, "microstep"),
         {:ok, round} <- fetch_non_neg_integer(args, "round"),
         {:ok, params} <- OpaqueTerm.decode_field(args, "params"),
         {:ok, content} <- OpaqueTerm.decode_field(args, "content"),
         {:ok, caller_context} <- OpaqueTerm.decode_field(args, "caller_context") do
      {:ok, scope, handler,
       %Invoke{
         invoke_id: invoke_id,
         type: Map.get(args, "type"),
         src: Map.get(args, "src"),
         params: params,
         content: content,
         caller_context: caller_context,
         autoforward: Map.get(args, "autoforward"),
         state_index: state_index,
         invoke_index: invoke_index,
         macrostep: macrostep,
         microstep: microstep,
         round: round
       }}
    end
  end

  @doc """
  Widens an invoke job's args into a fan-out child start job's args.

  A child start job carries the whole invocation - the same fields
  `from_invoke/4` laid out, opaque payloads and codec tag included, so
  the starter seam is handed the effect the planning callback saw - plus
  the two values that distinguish one child from its siblings:

  - `"index"` is the item's zero-based position in the fanned-out list.
    It rides at the top level because it is a **key component**:
    `StatifierOban.Invoke.ChildStartWorker` is unique on the
    four-component `{scope, invoke_id, macrostep, index}` (ADR-0007
    decision 4), and Oban's uniqueness `keys` read args at the top
    level.
  - `"child_count"` is the list's length, and is row data rather than a
    key component - two starts of the same index under the same
    invocation are the same scheduling decision whatever the count says.
    It travels because the seam's callback takes it: a starter that
    records the child's slot needs to know how many slots there are, and
    re-deriving it later would mean re-reading the parent.
  """
  @spec for_child_start(args(), non_neg_integer(), pos_integer()) :: args()
  def for_child_start(args, index, count)
      when is_map(args) and is_integer(index) and index >= 0 and
             is_integer(count) and count > 0 and index < count do
    Map.merge(args, %{"index" => index, "child_count" => count})
  end

  @doc """
  Reads a child start job's `{index, count}` back off its args.

  The rules are `to_invoke/1`'s: a missing or malformed field is a typed
  error about the row rather than a raise, and the worker decides what
  to do with it. A `"child_count"` of zero, or an `"index"` that is not
  inside it, is `{:invalid_field, _, _}` for the same reason a negative
  index would be - the row cannot be a child of any invocation.
  """
  @spec child_position(args()) ::
          {:ok, non_neg_integer(), pos_integer()} | {:error, decode_error()}
  def child_position(args) when is_map(args) do
    with {:ok, index} <- fetch_non_neg_integer(args, "index"),
         {:ok, count} <- fetch_non_neg_integer(args, "child_count") do
      if index < count do
        {:ok, index, count}
      else
        {:error, {:invalid_field, "index", index}}
      end
    end
  end

  @doc """
  Rebuilds just the identity pair - the scope and the invoke id - from a
  job's args.

  `to_invoke/1` fails the whole row when any field is undecodable,
  including the two host-opaque payloads, which is the common way a row
  goes bad. This reads only the two plain-string fields that *name* the
  invocation, so a caller holding an otherwise undecodable row can still
  tell the run which invocation it is about
  (`StatifierOban.Invoke.Worker` delivers `error.communication` that
  way before cancelling). The rules are `to_invoke/1`'s own, because
  this is the same `fetch_binary/2`: a missing, empty, or non-string
  field is a typed error, and then the row names nothing and there is
  nobody to tell.
  """
  @spec identity(args()) :: {:ok, String.t(), String.t()} | {:error, decode_error()}
  def identity(args) when is_map(args) do
    with {:ok, scope} <- fetch_binary(args, "scope"),
         {:ok, invoke_id} <- fetch_binary(args, "invoke_id") do
      {:ok, scope, invoke_id}
    end
  end

  # -- opaque terms: tagged term_to_binary payloads, shared with
  # `StatifierOban.Timer.JobArgs` so both job kinds' rows stay mutually
  # readable during an incident.

  @spec encode_term(String.t(), term(), module() | nil) ::
          {:ok, nil | %{String.t() => String.t()}} | {:error, encode_error()}
  defp encode_term(field, term, codec) do
    case OpaqueTerm.encode(term, codec) do
      {:ok, payload} -> {:ok, payload}
      {:error, reason} -> {:error, {:codec_failed, field, reason}}
    end
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
