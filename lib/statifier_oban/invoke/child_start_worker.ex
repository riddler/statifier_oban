defmodule StatifierOban.Invoke.ChildStartWorker do
  @moduledoc """
  The Oban worker that creates one child of a fan-out.

  `StatifierOban.Invoke.FanOut` enqueues N of these up front, one per
  item, and each one calls the host-wired
  `StatifierOban.Invoke.ChildStarter` seam for its own index, with the
  fan-out's aggregation policy. Creating the run is the seam's;
  scheduling the call is this module's, which is the whole of the
  division ADR-0007 draws between this package and the one that owns
  durable runs.

  ## The key

  Jobs are unique on the four-component
  `{scope, invoke_id, macrostep, index}` (ADR-0007 decision 4), read off
  the args at the top level, over every state and an infinite period.
  The first three are `StatifierOban.Invoke.Worker`'s triple (ADR-0003)
  and are shared by every child of one fan-out - they are one
  invocation, planned in one macrostep - so `index` is what keeps a
  replayed start from conflicting with its own sibling instead of with
  itself. Re-enqueueing a fan-out therefore starts exactly the children
  that are missing, which is the property decision 3's non-atomic slice
  is safe because of.

  ## The outcomes

  - the seam returns `:ok` -> the job completes;
  - the seam returns `{:error, reason}` -> the job retries with
    `{:start_failed, reason}` recorded. A run store that is down or
    contended is an environment fact, and `c:StatifierOban.Invoke.ChildStarter.start_child/5`
    is idempotent on the index by contract, so retrying is what
    at-least-once means here;
  - the config names no `:child_starter`, or one this node cannot
    resolve -> `{:error, {:invalid_child_starter, _}}` and a retry, the
    same deploy-shaped environment error an unresolvable delivery module
    is;
  - the row will not decode, or does not carry a usable
    `{index, count}` or a readable `"policy"` -> the job cancels with
    `{:undecodable, reason}`, because no number of retries makes a
    corrupt row decodable.

  Nothing here delivers into the run. A child start is not an answer:
  the invocation is answered once, by the settlement side, when every
  child has settled. A start that can never succeed exhausts its retries
  and is visible on the job row, leaving its index without a run record -
  the partially-started fan-out ADR-0007 decision 2 and `sb-ADR-0009`
  decision 8 both specify behaviour for, and which the settlement side
  is the one positioned to notice.
  """

  use Oban.Worker,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:scope, :invoke_id, :macrostep, :index],
      states: Oban.Job.states()
    ]

  alias StatifierOban.Invoke.{ChildStarter, JobArgs}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, meta: meta}) do
    with {:ok, scope, _handler, invoke} <- decode(args),
         {:ok, index, count} <- position(args),
         {:ok, opts} <- seam_opts(args),
         {:ok, starter} <- starter_module(meta) do
      start(starter, scope, invoke, index, count, opts)
    end
  end

  @spec start(
          module(),
          String.t(),
          Statifier.Effect.Invoke.t(),
          non_neg_integer(),
          pos_integer(),
          ChildStarter.opts()
        ) :: :ok | {:error, term()}
  defp start(starter, scope, invoke, index, count, opts) do
    case starter.start_child(scope, invoke, index, count, opts) do
      :ok -> :ok
      {:error, reason} -> {:error, {:start_failed, reason}}
    end
  end

  # The decode split is `StatifierOban.Invoke.Worker`'s, for its reasons:
  # a codec this node cannot use is an environment fact and retries,
  # while everything else is a fact about the row and cancels. There is
  # no failure delivery on the way past here - a start job names an
  # index of an invocation, and telling the run that one index is
  # undecodable is not this side's message to send.
  @spec decode(JobArgs.args()) ::
          {:ok, String.t(), String.t(), Statifier.Effect.Invoke.t()}
          | {:error, term()}
          | {:cancel, term()}
  defp decode(args) do
    case JobArgs.to_invoke(args) do
      {:ok, scope, handler, invoke} -> {:ok, scope, handler, invoke}
      {:error, {:invalid_codec, _field, _name} = reason} -> {:error, reason}
      {:error, {:codec_failed, _field, _codec, _reason} = reason} -> {:error, reason}
      {:error, reason} -> {:cancel, {:undecodable, reason}}
    end
  end

  @spec position(JobArgs.args()) ::
          {:ok, non_neg_integer(), pos_integer()} | {:cancel, term()}
  defp position(args) do
    case JobArgs.child_position(args) do
      {:ok, index, count} -> {:ok, index, count}
      {:error, reason} -> {:cancel, {:undecodable, reason}}
    end
  end

  # `position/1`'s rule, applied to the seam's option list: an
  # unreadable `"policy"` is a fact about the row and no retry mends it.
  # An absent one is not an error - `JobArgs.child_opts/1` reads it as
  # `:all`, the aggregation an invocation that named none asked for.
  @spec seam_opts(JobArgs.args()) :: {:ok, ChildStarter.opts()} | {:cancel, term()}
  defp seam_opts(args) do
    case JobArgs.child_opts(args) do
      {:ok, opts} -> {:ok, opts}
      {:error, reason} -> {:cancel, {:undecodable, reason}}
    end
  end

  # The starter rides in the job's meta, written from a validated
  # `StatifierOban.Config` at enqueue time, exactly as the delivery
  # module does on an invoke job: meta is not part of the unique fields,
  # so a replay under a reconfigured seam still conflicts with the
  # stored job. Resolution failures are deploy-shaped - the module was
  # renamed or removed after the job was stored - so they retry rather
  # than cancel.
  @spec starter_module(map()) :: {:ok, module()} | {:error, {:invalid_child_starter, term()}}
  defp starter_module(meta) do
    case Map.get(meta, "child_starter") do
      name when is_binary(name) -> resolve(name)
      other -> {:error, {:invalid_child_starter, other}}
    end
  end

  @spec resolve(String.t()) :: {:ok, module()} | {:error, {:invalid_child_starter, term()}}
  defp resolve(name) do
    module = String.to_existing_atom(name)

    if Code.ensure_loaded?(module) and function_exported?(module, :start_child, 5) do
      {:ok, module}
    else
      {:error, {:invalid_child_starter, name}}
    end
  rescue
    ArgumentError -> {:error, {:invalid_child_starter, name}}
  end
end
