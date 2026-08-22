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
  a second job.

  `perform/1` decodes the stored effect and stops there, cancelling with
  `:delivery_not_implemented`: delivery is sob-2hx.5's scope, which owes
  the run-liveness check st-ADR-0054 decision 4 requires before any fired
  event is fed back. It bolts on here, replacing that one return with the
  checked delivery; the decode half stays as it is. An undecodable row
  cancels rather than retries - no number of retries makes a corrupt row
  decodable.
  """

  use Oban.Worker,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:scope, :ordinal],
      states: Oban.Job.states()
    ]

  alias StatifierOban.Timer.JobArgs

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case JobArgs.to_effect(args) do
      {:ok, _scope, _effect} -> {:cancel, :delivery_not_implemented}
      {:error, reason} -> {:cancel, {:undecodable, reason}}
    end
  end
end
