defmodule StatifierOban.Timer do
  @moduledoc """
  Consumes `{:send_delayed, %Statifier.Effect.SendDelayed{}}` into a
  uniquely-keyed job on the host's Oban instance.

  This is the scheduling and cancellation half of the durable-timer recipe
  in statifier-ex's `docs/durable-timers.md`: the host reads the effect off
  a live session's subscriber stream (or a direct interpreter drive) and
  hands it here with the session scope and its `StatifierOban.Config`.
  When the job fires, `StatifierOban.Timer.Worker` feeds the event back
  through the config's `StatifierOban.Timer.Delivery` module, behind the
  mandatory run-liveness check (st-ADR-0054 decision 4) - the delivery
  module travels on the job's meta, so it is fixed at schedule time.

  Two contract rules from statifier-ex are enforced at this door:

  - **Only a `nil` target is schedulable** (st-ADR-0055): any other
    target's route is resolved inside the session and does not travel on
    the effect, so a non-`nil` target is a typed error here - the caller
    should not have offered it. The effect stream is observational;
    leaving such a send to the library costs nothing.
  - **`delay_ms` is relative**, milliseconds from the moment the send was
    scheduled, so the fire time is computed at insert
    (`DateTime.utc_now/0` plus the delay), never re-derived later.

  The config's `:opaque_codec` is fixed at schedule time: `schedule/3`
  reads it once, from the `Config` the caller hands it, and encodes the
  effect's host-opaque fields through it before the job is ever stored.
  The module name travels on the row alongside the encoded bytes
  (`StatifierOban.OpaqueTerm`'s `"codec"` tag), so the worker that later
  decodes the fired job needs no configuration of its own - it reads
  whatever tag the row carries.
  """

  import Ecto.Query, only: [where: 3]

  alias Statifier.Effect.{Cancel, SendDelayed}
  alias StatifierOban.{Config, Telemetry}
  alias StatifierOban.Timer.{CancellationKey, JobArgs, Key, Worker}

  @typedoc "Why a SendDelayed effect could not be scheduled."
  @type schedule_error ::
          {:non_self_target, String.t()}
          | Key.error()
          | JobArgs.encode_error()
          | Ecto.Changeset.t()

  @doc """
  Schedules one `%SendDelayed{}` as one Oban job, unique per dedup key.

  `scope` follows `StatifierOban.Timer.Key`: `ctx.session_id` for a live
  session, or the host's own durable run id for a process-less host -
  always the caller's to supply, never derived.

  Inserting the same scope and effect again returns `{:ok, job}` with
  `job.conflict?` set and leaves exactly one stored job: the at-least-once
  no-op the dedup key exists for. The job is inserted into the host's
  `:timers_queue`, scheduled at now plus `delay_ms`, carrying the
  config's delivery module in its meta - meta is not part of the unique
  fields, so a replay under a reconfigured delivery still conflicts with
  the stored job (same scheduling decision) rather than inserting a
  second one.
  """
  @spec schedule(Config.t(), Key.scope(), SendDelayed.t()) ::
          {:ok, Oban.Job.t()} | {:error, schedule_error()}
  def schedule(%Config{} = config, scope, %SendDelayed{target: nil} = effect) do
    result =
      with {:ok, _dedup_key} <- Key.dedup_key(scope, effect),
           {:ok, args} <- JobArgs.from_effect(scope, effect, config.opaque_codec) do
        scheduled_at = DateTime.add(DateTime.utc_now(), effect.delay_ms, :millisecond)

        changeset =
          Worker.new(args,
            queue: config.timers_queue,
            scheduled_at: scheduled_at,
            meta: %{"delivery" => Atom.to_string(config.delivery)}
          )

        Oban.insert(config.oban, changeset)
      end

    report_schedule(scope, effect, result)
  end

  def schedule(%Config{}, scope, %SendDelayed{target: target} = effect) do
    reason = {:non_self_target, target}
    Telemetry.timer_schedule_rejected(scope, effect, reason)
    {:error, reason}
  end

  # ADR-0006's scheduling seam: exactly one event per call, on whichever
  # way the call went out. The `conflict?` flag on a successful insert is
  # the only place a replayed drive's no-op is observable at all - the
  # stored row is the same single row either way.
  @spec report_schedule(Key.scope(), SendDelayed.t(), {:ok, Oban.Job.t()} | {:error, term()}) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  defp report_schedule(scope, effect, {:ok, %Oban.Job{} = job} = result) do
    Telemetry.timer_scheduled(scope, effect, job)
    result
  end

  defp report_schedule(scope, effect, {:error, reason} = result) do
    Telemetry.timer_schedule_rejected(scope, effect, reason)
    result
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

  **A cancel only ever reaches a timer that has not fired.** The match is
  restricted to the states a pending timer can be in - `suspended`,
  `scheduled`, `available`, `retryable` - so a job that is `executing`
  right now is never swept, and neither is one that already reached a
  terminal state. Both stay out for the same reason: the timer has fired,
  and a cancel that arrives after the fire loses the race. That is
  spec-faithful - a real-time `<cancel>` can lose to a timer that already
  fired - and the run-liveness check the delivery seam owes (st-ADR-0054
  decision 4) is the guard on that side, not this one.

  Leaving `executing` out is what makes the common self-cancel safe.
  A fired timer's delivery routinely drives the chart out of the state
  that armed it, which runs that state's `onexit` `<cancel>` for the very
  `send_id` being delivered - so the cancel and the delivery are the same
  job. Sweeping `executing` here would have `Oban.cancel_all_jobs/2`
  signal a `:pkill` at the delivery's own process and kill the step
  mid-flight, leaving the row `cancelled` with `{:cancel, :shutdown}` and
  the run's progress unpersisted (sob-uon, found downstream on the Lite
  engine). A cancel raised from inside a job's own delivery must not kill
  that delivery.

  Cancelling a genuinely in-flight delivery from outside is therefore not
  offered. A host that needs it holds the job id and can call
  `Oban.cancel_job/2` itself; this package will not do it blind, because
  from the query's side the self-cancel and the outside cancel are
  indistinguishable.

  The match ignores the queue, exactly as the dedup key's uniqueness does:
  a host that moved its timers queue can still cancel jobs stored under
  the old name.
  """
  @spec cancel(Config.t(), Key.scope(), Cancel.t()) ::
          {:ok, non_neg_integer()} | {:error, Key.error()}
  def cancel(%Config{} = config, scope, %Cancel{} = effect) do
    with {:ok, key} <- Key.cancellation_key(scope, effect),
         {:ok, count} <- Oban.cancel_all_jobs(config.oban, timer_jobs(key)) do
      Telemetry.timer_cancelled(scope, effect, count)
      {:ok, count}
    end
  end

  # Every non-terminal state except `executing` - the states a timer that
  # has not fired can be in. `executing` is deliberately absent: see
  # `cancel/3`'s docs - a delivery that cancels its own send_id would
  # otherwise pkill itself (sob-uon). The terminal states are excluded by
  # `Oban.cancel_all_jobs/2` anyway; naming the set positively here keeps
  # the whole rule readable in one place, and `suspended` earns its place
  # because a held job has not fired and would fire on resume.
  #
  # The list is literal rather than derived from `Oban.Job.states/1` so
  # the package keeps compiling across the whole `~> 2.19` range. A new
  # Oban state is therefore a review point here, which
  # `StatifierOban.Timer.CancellableStatesTest` pins.
  @cancellable_states ~w(suspended scheduled available retryable)

  @spec timer_jobs(CancellationKey.t()) :: Ecto.Query.t()
  defp timer_jobs(%CancellationKey{scope: scope, send_id: send_id}) do
    worker = Oban.Worker.to_string(Worker)

    Oban.Job
    |> where([j], j.worker == ^worker)
    |> where([j], j.state in @cancellable_states)
    |> where([j], j.args["scope"] == ^scope and j.args["send_id"] == ^send_id)
  end
end
