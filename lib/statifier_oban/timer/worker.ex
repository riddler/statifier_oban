defmodule StatifierOban.Timer.Worker do
  @moduledoc """
  The Oban worker a `%Statifier.Effect.SendDelayed{}` becomes.

  Uniqueness is the whole point of this module: jobs are unique on the
  `{scope, ordinal}` dedup pair (`StatifierOban.Timer.DedupKey`), read off
  the args at the top level. Re-executing the same drive after a crash
  rebuilds a byte-identical pair - both components are pure fold state
  (st-ADR-0059) - so the duplicate insert conflicts with the stored job
  and becomes a no-op. That conflict, not any check in host code, is what
  makes at-least-once redelivery safe.

  The unique window is every state over an infinite period: a timer that
  already completed, was cancelled (sob-2hx.4's path), or was discarded
  must still swallow a replayed insert, because the replay is the same
  scheduling decision, not a new one. The unique fields exclude `:queue`
  on purpose - a host moving its timers queue must not turn a replay into
  a second job - and exclude the meta the delivery module rides on, so a
  host reconfiguring its delivery does not turn a replay into a second
  job either.

  `perform/1` decodes the stored effect and hands it to the job's
  `StatifierOban.Timer.Delivery` module (from the meta written at
  schedule time; absent meta falls back to the documented default,
  `StatifierOban.Timer.Delivery.Session`), which owes the run-liveness
  check st-ADR-0054 decision 4 requires before any fired event is fed
  back. The outcomes map onto Oban states so each is observable on the
  job row:

  - delivered -> the job completes (`:ok`);
  - the run is not live -> the job cancels with
    `{:discarded, reason}` recorded, the spec 6.2 discard as data;
  - an undecodable row cancels with `{:undecodable, reason}` - no number
    of retries makes a corrupt row decodable;
  - a codec named on the row that this node cannot resolve, or one that
    cannot decode the row right now, returns `{:error, {:invalid_codec,
    _}}` or `{:error, {:codec_failed, _}}` and retries - an environment
    fact, fixable by a deploy or by making the key available, not a fact
    about the row;
  - a delivery module that cannot be resolved returns
    `{:error, {:invalid_delivery, _}}` and retries - an environment fact
    about the host's code, fixable by a deploy, unlike the row facts
    above. A raise or exit out of the delivery module retries the same
    way, per the behaviour's contract.
  """

  use Oban.Worker,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:scope, :ordinal],
      states: Oban.Job.states()
    ]

  alias StatifierOban.Timer.JobArgs

  @default_delivery StatifierOban.Timer.Delivery.Session

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, meta: meta}) do
    with {:ok, scope, effect} <- decode(args),
         {:ok, delivery} <- delivery_module(meta) do
      case delivery.deliver(scope, effect) do
        :delivered -> :ok
        {:discarded, reason} -> {:cancel, {:discarded, reason}}
      end
    end
  end

  @spec decode(JobArgs.args()) ::
          {:ok, String.t(), Statifier.Effect.SendDelayed.t()}
          | {:error, term()}
          | {:cancel, term()}
  defp decode(args) do
    case JobArgs.to_effect(args) do
      {:ok, scope, effect} -> {:ok, scope, effect}
      {:error, {:invalid_codec, _field, _name} = reason} -> {:error, reason}
      {:error, {:codec_failed, _field, _codec, _reason} = reason} -> {:error, reason}
      {:error, reason} -> {:cancel, {:undecodable, reason}}
    end
  end

  # The meta value is a module name written by `Timer.schedule/3` from a
  # validated `Config`, so resolution failures are deploy-shaped: the
  # module was renamed or removed after the job was stored. `:error` (not
  # `:cancel`) keeps the timer alive across the host fixing that.
  @spec delivery_module(map()) :: {:ok, module()} | {:error, {:invalid_delivery, term()}}
  defp delivery_module(meta) do
    case Map.get(meta, "delivery") do
      nil -> {:ok, @default_delivery}
      name when is_binary(name) -> resolve_delivery(name)
      other -> {:error, {:invalid_delivery, other}}
    end
  end

  @spec resolve_delivery(String.t()) :: {:ok, module()} | {:error, {:invalid_delivery, term()}}
  defp resolve_delivery(name) do
    module = String.to_existing_atom(name)

    if Code.ensure_loaded?(module) and function_exported?(module, :deliver, 2) do
      {:ok, module}
    else
      {:error, {:invalid_delivery, name}}
    end
  rescue
    # `String.to_existing_atom/1` on a module this node has never seen -
    # a fact about the deployed code, returned as data at this boundary
    # so Oban retries it as the environment error it is.
    ArgumentError -> {:error, {:invalid_delivery, name}}
  end
end
