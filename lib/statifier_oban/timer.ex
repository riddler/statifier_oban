defmodule StatifierOban.Timer do
  @moduledoc """
  Consumes `{:send_delayed, %Statifier.Effect.SendDelayed{}}` into a
  uniquely-keyed job on the host's Oban instance.

  This is the scheduling half of the durable-timer recipe in statifier-ex's
  `docs/durable-timers.md`: the host reads the effect off a live session's
  subscriber stream (or a direct interpreter drive) and hands it here with
  the session scope and its `StatifierOban.Config`. Cancellation is
  sob-2hx.4; delivery of the fired event, behind the mandatory run-liveness
  check, is sob-2hx.5.

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

  alias Statifier.Effect.SendDelayed
  alias StatifierOban.Config
  alias StatifierOban.Timer.{JobArgs, Key, Worker}

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
end
