defmodule StatifierOban.Timer do
  @moduledoc """
  Consumes `{:send_delayed, %Statifier.Effect.SendDelayed{}}` into a
  uniquely-keyed job on the host's Oban instance.

  This is the scheduling and cancellation half of the durable-timer recipe
  in statifier-ex's `docs/durable-timers.md`: the host reads the effect off
  a live session's subscriber stream (or a direct interpreter drive) and
  hands it here with the session scope and its `StatifierOban.Config`.
  Delivery of the fired event, behind the mandatory run-liveness check, is
  sob-2hx.5.

  Two contract rules from statifier-ex are enforced at this door:

  - **Only a `nil` target is schedulable** (st-ADR-0055): any other
    target's route is resolved inside the session and does not travel on
    the effect, so a non-`nil` target is a typed error here - the caller
    should not have offered it. The effect stream is observational;
    leaving such a send to the library costs nothing.
  - **`delay_ms` is relative**, milliseconds from the moment the send was
    scheduled, so the fire time is computed at insert
    (`DateTime.utc_now/0` plus the delay), never re-derived later.
  """

  import Ecto.Query, only: [where: 3]

  alias Statifier.Effect.{Cancel, SendDelayed}
  alias StatifierOban.Config
  alias StatifierOban.Timer.{CancellationKey, JobArgs, Key, Worker}

  @typedoc "Why a SendDelayed effect could not be scheduled."
  @type schedule_error ::
          {:non_self_target, String.t()}
          | Key.error()
          | Ecto.Changeset.t()

  @doc """
  Schedules one `%SendDelayed{}` as one Oban job, unique per dedup key.

  `scope` follows `StatifierOban.Timer.Key`: `ctx.session_id` for a live
  session, or the host's own durable run id for a process-less host -
  always the caller's to supply, never derived.

  Inserting the same scope and effect again returns `{:ok, job}` with
  `job.conflict?` set and leaves exactly one stored job: the at-least-once
  no-op the dedup key exists for. The job is inserted into the host's
  `:timers_queue`, scheduled at now plus `delay_ms`.
  """
  @spec schedule(Config.t(), Key.scope(), SendDelayed.t()) ::
          {:ok, Oban.Job.t()} | {:error, schedule_error()}
  def schedule(%Config{} = config, scope, %SendDelayed{target: nil} = effect) do
    with {:ok, _dedup_key} <- Key.dedup_key(scope, effect) do
      scheduled_at = DateTime.add(DateTime.utc_now(), effect.delay_ms, :millisecond)

      changeset =
        scope
        |> JobArgs.from_effect(effect)
        |> Worker.new(queue: config.timers_queue, scheduled_at: scheduled_at)

      Oban.insert(config.oban, changeset)
    end
  end

  def schedule(%Config{}, _scope, %SendDelayed{target: target}) do
    {:error, {:non_self_target, target}}
  end

  @doc """
  Consumes one `%Cancel{}` into cancellation of every matching timer job.

  Consumes the effect vocabulary's `{:cancel, %Cancel{}}`, never the
  instruction vocabulary's `{:cancel_timers, ...}` (st-ADR-0054). The match
  is the cancellation key `{scope, send_id}` from
  `StatifierOban.Timer.Key`, read off each stored job's args, and it may
  legitimately hit several jobs: spec 6.3 cancels every delayed send under
  a sendid, and an author-written `id` executed twice stores two jobs
  under one `send_id`. Returns `{:ok, count}` with the number of jobs
  cancelled; a cancel matching nothing is `{:ok, 0}`, a no-op rather than
  an error - the same shape as `Timers.take/2`'s `{[], timers}` in
  statifier-ex.

  A cancel racing job execution resolves to whichever transition commits
  first, and stays resolved: `Oban.cancel_all_jobs/2` cancels any matched
  job still in a non-terminal state - an `executing` one is killed - while
  a job that already reached a terminal state keeps its outcome and is not
  counted. That is spec-faithful: a real-time `<cancel>` can lose to a
  timer that already fired, and sob-2hx.5's run-liveness check at delivery
  is the guard on that side, not this one.

  The match ignores the queue, exactly as the dedup key's uniqueness does:
  a host that moved its timers queue can still cancel jobs stored under
  the old name.
  """
  @spec cancel(Config.t(), Key.scope(), Cancel.t()) ::
          {:ok, non_neg_integer()} | {:error, Key.error()}
  def cancel(%Config{} = config, scope, %Cancel{} = effect) do
    with {:ok, key} <- Key.cancellation_key(scope, effect) do
      Oban.cancel_all_jobs(config.oban, timer_jobs(key))
    end
  end

  @spec timer_jobs(CancellationKey.t()) :: Ecto.Query.t()
  defp timer_jobs(%CancellationKey{scope: scope, send_id: send_id}) do
    worker = Oban.Worker.to_string(Worker)

    Oban.Job
    |> where([j], j.worker == ^worker)
    |> where([j], j.args["scope"] == ^scope and j.args["send_id"] == ^send_id)
  end
end
