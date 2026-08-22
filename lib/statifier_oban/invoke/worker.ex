defmodule StatifierOban.Invoke.Worker do
  @moduledoc """
  The Oban worker a base-handler invocation becomes.

  Uniqueness is the whole point of this module, exactly as it is for
  `StatifierOban.Timer.Worker`: jobs are unique on the
  `{scope, invoke_id}` pair, read off the args at the top level.
  Re-executing the same drive after a crash rebuilds a byte-identical
  pair - `invoke_id` is a deterministic `%MachineState{}` counter
  (st-ADR-0008 as amended) - so the duplicate insert conflicts with the
  stored job and becomes a no-op. That conflict, not any check in host
  code, is what makes the at-least-once `perform/2` contract
  (st-ADR-0051 decision 4) safe for the enqueue itself.

  The unique window is every state over an infinite period: an invoke
  whose job already completed, was cancelled, or was discarded must
  still swallow a replayed insert, because the replay is the same
  scheduling decision, not a new one. The unique fields exclude `:queue`
  and the meta the delivery module rides on, for the same reasons the
  timer worker's do.

  `perform/1` decodes the stored effect, resolves the handler module the
  args carry, calls its `run/1` - the host's actual work, at least once,
  idempotent on `invoke_id` by that module's own contract - and hands
  the result to the job's `StatifierOban.Invoke.Delivery` module (from
  the meta written at enqueue time; absent meta falls back to the
  documented default, `StatifierOban.Invoke.Delivery.Session`), which
  owes the run-liveness check before any completion is fed back. The
  outcomes map onto Oban states so each is observable on the job row:

  - work done and delivered -> the job completes (`:ok`);
  - the run is not live -> the job cancels with `{:discarded, reason}`
    recorded - a completed invoke against a dead or halted run is
    discarded the same way a fired timer is;
  - `run/1` returns `{:error, reason}` -> the job retries with
    `{:run_failed, reason}` recorded - the work is idempotent on
    `invoke_id` by contract, so retrying is what at-least-once means; a
    raise or exit out of `run/1` (or the delivery module) retries the
    same way;
  - an undecodable row cancels with `{:undecodable, reason}` - no number
    of retries makes a corrupt row decodable;
  - a handler or delivery module that cannot be resolved returns
    `{:error, {:invalid_handler, _}}` / `{:error, {:invalid_delivery, _}}`
    and retries - environment facts about the host's code, fixable by a
    deploy, unlike the row facts above.
  """

  use Oban.Worker,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:scope, :invoke_id],
      states: Oban.Job.states()
    ]

  alias StatifierOban.Invoke.JobArgs

  @default_delivery StatifierOban.Invoke.Delivery.Session

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, meta: meta}) do
    with {:ok, scope, handler_name, invoke} <- decode(args),
         {:ok, handler} <- resolve_module(handler_name, :run, 1, :invalid_handler),
         {:ok, delivery} <- delivery_module(meta),
         {:ok, donedata} <- run(handler, invoke) do
      case delivery.deliver(scope, invoke.invoke_id, donedata) do
        :delivered -> :ok
        {:discarded, reason} -> {:cancel, {:discarded, reason}}
      end
    end
  end

  @spec decode(JobArgs.args()) ::
          {:ok, String.t(), String.t(), Statifier.Effect.Invoke.t()} | {:cancel, term()}
  defp decode(args) do
    case JobArgs.to_invoke(args) do
      {:ok, scope, handler_name, invoke} -> {:ok, scope, handler_name, invoke}
      {:error, reason} -> {:cancel, {:undecodable, reason}}
    end
  end

  @spec run(module(), Statifier.Effect.Invoke.t()) ::
          {:ok, term()} | {:error, {:run_failed, term()}}
  defp run(handler, invoke) do
    case handler.run(invoke) do
      {:ok, donedata} -> {:ok, donedata}
      {:error, reason} -> {:error, {:run_failed, reason}}
    end
  end

  # The meta value is a module name written by the base handler from a
  # validated `Config`, so resolution failures are deploy-shaped: the
  # module was renamed or removed after the job was stored. `:error` (not
  # `:cancel`) keeps the invoke alive across the host fixing that. The
  # handler name in the args resolves through the same rule.
  @spec delivery_module(map()) :: {:ok, module()} | {:error, {:invalid_delivery, term()}}
  defp delivery_module(meta) do
    case Map.get(meta, "delivery") do
      nil -> {:ok, @default_delivery}
      name when is_binary(name) -> resolve_module(name, :deliver, 3, :invalid_delivery)
      other -> {:error, {:invalid_delivery, other}}
    end
  end

  @spec resolve_module(
          String.t(),
          atom(),
          non_neg_integer(),
          :invalid_handler | :invalid_delivery
        ) ::
          {:ok, module()} | {:error, {:invalid_handler | :invalid_delivery, term()}}
  defp resolve_module(name, function, arity, error_tag) do
    module = String.to_existing_atom(name)

    if Code.ensure_loaded?(module) and function_exported?(module, function, arity) do
      {:ok, module}
    else
      {:error, {error_tag, name}}
    end
  rescue
    # `String.to_existing_atom/1` on a module this node has never seen -
    # a fact about the deployed code, returned as data at this boundary
    # so Oban retries it as the environment error it is.
    ArgumentError -> {:error, {error_tag, name}}
  end
end
