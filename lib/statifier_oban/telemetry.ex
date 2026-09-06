defmodule StatifierOban.Telemetry do
  @moduledoc """
  The `:telemetry` surface for this package's durable seams (ADR-0006) -
  the single definition site for every `[:statifier_oban, ...]` event name,
  and the one module that calls `:telemetry.execute/3`.

  `docs/telemetry.md` is the full contract: what each event answers, what
  it deliberately leaves to Oban and to statifier-ex, and what
  `opentelemetry_statifier` does with it. This moduledoc is the reference
  table; that note is the reasoning.

  `events/0` returns every name below, built from the same literal-atom
  lists the emitters use, so the bridge can attach one handler per event
  name without hand-copying the list (ADR-0006 decision 4,
  `ots-ADR-0003`).

  ## What these events are for

  Two other surfaces already report on this package's work. Oban
  instruments the *job* (`[:oban, :job, :start | :stop | :exception]`,
  `[:oban, :engine, ...]`), and statifier-ex instruments the *effect*
  (`[:statifier, :session, :effect, :send_delayed | :cancel | :invoke]`).
  What neither can see is the durable step between them, and that is the
  whole of what this module emits: whether the effect became a row and
  whether the insert was new (`conflict?`), which statechart identity an
  opaque job row belongs to, and the spec-level verdicts that are
  successes for Oban and non-events for the chart (the 6.2 discard, the
  6.3/6.4.3 sweeps, a permanently failed invocation).

  Duration, attempts, retries, snoozes, queue latency and exceptions are
  Oban's and are not re-emitted; in particular there is no lateness
  measurement here, because `:queue_time` on `[:oban, :job, :stop]` is the
  same subtraction against the same two timestamps.

  ## Structural rules (ADR-0006 decisions 3, 4, 5, 8)

  - **The prefix is `[:statifier_oban, ...]`, fixed and not configurable.**
    Upstream reserves its own second segment (`:session`) for the logical
    SCXML session, and nothing here is scoped to one.
  - **Measurements are numbers; metadata is everything else**, integer
    indexes included - `ordinal`, `macrostep`, `microstep` and `round` are
    metadata here, because an opaque index has no numeric meaning to
    average.
  - **Every event is a single point-in-time event.** There are no
    `:start`/`:stop` pairs: this package owns no interval Oban does not
    already own, so every event measures `system_time` plus whatever
    numbers are genuinely its own.
  - **Emission is unconditional.** There is no config knob and no sampling
    knob: `:telemetry.execute/3` on an event with no handlers is a lookup
    and a return.
  - **Amendment discipline.** Adding a measurement or a metadata key to an
    existing event is an amendment and is fine; renaming or removing one,
    or renaming an event, is breaking and needs a new ADR.

  ## Scheduling seam

  Emitted synchronously on the process that drove the macrostep, before
  any Oban job exists.

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:statifier_oban, :timer, :scheduled]` | `system_time`, `delay_ms` | `scope`, `send_id`, `ordinal`, `macrostep`, `microstep`, `round`, `scheduled_at`, `queue`, `conflict?`, `job_id`, `caller_context` |
  | `[:statifier_oban, :timer, :schedule_rejected]` | `system_time` | `scope`, `send_id`, `ordinal`, `reason` |
  | `[:statifier_oban, :timer, :cancelled]` | `system_time`, `count` | `scope`, `send_id`, `ordinal`, `caller_context` |
  | `[:statifier_oban, :invoke, :enqueued]` | `system_time` | `scope`, `invoke_id`, `macrostep`, `handler`, `queue`, `conflict?`, `job_id` |
  | `[:statifier_oban, :invoke, :enqueue_rejected]` | `system_time` | `scope`, `invoke_id`, `handler`, `reason` |
  | `[:statifier_oban, :invoke, :cancelled]` | `system_time`, `count` | `scope`, `invoke_id`, `handler` |

  `conflict?` is what answers "did that replay do anything": `true` means
  the dedup key held and no second job was stored.

  `count` on the two cancellation events is the sweep's own return, and
  `0` is data rather than an error - spec 6.3 cancels every timer under a
  `send_id`, and a cancel that matches nothing is a no-op.

  `reason` on the two `*_rejected` events is the typed error the call
  returned, unchanged. `scope` is `nil` on
  `[:statifier_oban, :invoke, :enqueue_rejected]` when the rejection is
  `{:invalid_scope, ctx}` itself: there is no validated scope to report,
  and reporting the raw `ctx` would put unvalidated host state on the
  event.

  ## Delivery seam

  Emitted on the Oban worker process, inside the job.

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:statifier_oban, :timer, :fired]` | `system_time`, `attempt` | `scope`, `send_id`, `ordinal`, `delivery`, `job_id`, `caller_context` |
  | `[:statifier_oban, :timer, :discarded]` | `system_time`, `attempt` | `scope`, `send_id`, `ordinal`, `delivery`, `reason`, `job_id`, `caller_context` |
  | `[:statifier_oban, :invoke, :delivered]` | `system_time`, `attempt` | `scope`, `invoke_id`, `macrostep`, `handler`, `delivery`, `job_id` |
  | `[:statifier_oban, :invoke, :discarded]` | `system_time`, `attempt` | `scope`, `invoke_id`, `macrostep`, `handler`, `delivery`, `reason`, `job_id` |
  | `[:statifier_oban, :invoke, :failed]` | `system_time`, `attempts` | `scope`, `invoke_id`, `reason`, `detail`, `handler`, `job_id` |

  `reason` on the two `:discarded` events is the delivery seam's
  `t:StatifierOban.Timer.Delivery.discard_reason/0` - the spec 6.2 verdict
  as data, which Oban buries inside `:result`.

  `[:statifier_oban, :invoke, :failed]` mirrors
  `c:StatifierOban.Invoke.Delivery.deliver_failure/3` exactly, including
  ADR-0005's three-class `reason` vocabulary (`"run_failed"`,
  `"run_crashed"`, `"undecodable"`) and its `attempts` semantics. Its
  `handler` is `nil` on the `"undecodable"` class alone: that row never
  reached handler resolution, because the decode that would have named the
  module is the thing that failed.

  Where the seam delivers nothing, this emits nothing: the environment
  errors `:invalid_handler`, `:invalid_delivery`, `:invalid_codec` and
  `:codec_failed` say the deploy is wrong rather than anything about the
  invocation, and they ride Oban's exception event.

  ## Fan-out seam

  Emitted around ADR-0007's fan-out, and recorded by ADR-0006's
  2026-09-06 amendment. None of the three is an answer: the fan-out job
  completes without delivering, a child start creates a run and delivers
  nothing, and the settlement side answers the invocation once on behalf
  of all N.

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:statifier_oban, :invoke, :fan_out]` | `system_time`, `count` | `scope`, `invoke_id`, `handler`, `policy`, `queue`, `job_id`, `caller_context` |
  | `[:statifier_oban, :invoke, :child_started]` | `system_time`, `attempt` | `scope`, `invoke_id`, `index`, `count`, `job_id`, `caller_context` |
  | `[:statifier_oban, :invoke, :unstarted_cancelled]` | `system_time`, `count` | `scope`, `invoke_id` |

  `count` is the fan-out's width on all three. It is a measurement on
  `:fan_out` and `:unstarted_cancelled`, where it is the number the call
  itself produced - the status it already has on the two `:cancelled`
  events, `0` included - and metadata on `:child_started`, where `index`
  and `count` together are the child's position rather than a quantity.

  `:unstarted_cancelled`'s count is half of `sb-ADR-0009` decision 6's
  `first_error` cancel: the indices whose start job never ran. The
  siblings that already have a child run are the settlement side's to
  cancel and are not counted here.

  `handler` is on `:fan_out` alone - `ChildStartWorker` never resolves the
  handler name to a module and `cancel_unstarted/3` is given no handler at
  all, and a string where every other event carries a module would be
  worse than the absence.

  ## Cardinality

  Every metadata key above is bounded by the chart rather than by traffic,
  except `job_id`, which is a correlation id for a span or a log line and
  never a metric dimension, and `caller_context`, which is an opaque host
  term present for the bridge alone.

  **Nothing from the chart's datamodel is ever on an event.** The effect's
  `data`, `params` and `content` are host-opaque terms
  (`StatifierOban.OpaqueTerm`), possibly encrypted through a host codec,
  and they are never emitted - not truncated, not hashed, not "just the
  keys".
  """

  alias Statifier.Effect.{Cancel, Invoke, SendDelayed}

  @typedoc "One `:telemetry` event name this module can emit."
  @type event_name :: [atom(), ...]

  @typedoc "The identity a job row is keyed under - see `StatifierOban.Timer.Key`."
  @type scope :: String.t()

  @timer_kinds [:scheduled, :schedule_rejected, :cancelled, :fired, :discarded]
  @invoke_kinds [
    :enqueued,
    :enqueue_rejected,
    :cancelled,
    :fan_out,
    :child_started,
    :unstarted_cancelled,
    :delivered,
    :discarded,
    :failed
  ]

  @doc """
  Every event name this module can ever emit - the 5
  `[:statifier_oban, :timer, kind]` names and the 9
  `[:statifier_oban, :invoke, kind]` names, built from `@timer_kinds` and
  `@invoke_kinds`, this module's single definition site for the
  vocabulary.

  The list is what `opentelemetry_statifier` attaches to, one handler per
  name (`ots-ADR-0003`), so it is as public as a function signature.
  """
  @spec events() :: [event_name()]
  def events do
    Enum.map(@timer_kinds, &[:statifier_oban, :timer, &1]) ++
      Enum.map(@invoke_kinds, &[:statifier_oban, :invoke, &1])
  end

  # -- scheduling seam

  @doc """
  Emits `[:statifier_oban, :timer, :scheduled]` - the durable write for one
  `%Statifier.Effect.SendDelayed{}` happened, and `conflict?` says whether
  it was new.
  """
  @spec timer_scheduled(scope(), SendDelayed.t(), Oban.Job.t()) :: :ok
  def timer_scheduled(scope, %SendDelayed{} = effect, %Oban.Job{} = job) do
    :telemetry.execute(
      [:statifier_oban, :timer, :scheduled],
      %{system_time: System.system_time(), delay_ms: effect.delay_ms},
      %{
        scope: scope,
        send_id: effect.send_id,
        ordinal: effect.ordinal,
        macrostep: effect.macrostep,
        microstep: effect.microstep,
        round: effect.round,
        scheduled_at: job.scheduled_at,
        queue: job.queue,
        conflict?: job.conflict?,
        job_id: job.id,
        caller_context: effect.caller_context
      }
    )
  end

  @doc """
  Emits `[:statifier_oban, :timer, :schedule_rejected]` - no row was
  stored. `reason` is `t:StatifierOban.Timer.schedule_error/0`, and the
  commonest value, `{:non_self_target, target}`, is the `st-ADR-0055`
  bailout rather than a fault.
  """
  @spec timer_schedule_rejected(scope(), SendDelayed.t(), term()) :: :ok
  def timer_schedule_rejected(scope, %SendDelayed{} = effect, reason) do
    :telemetry.execute(
      [:statifier_oban, :timer, :schedule_rejected],
      %{system_time: System.system_time()},
      %{scope: scope, send_id: effect.send_id, ordinal: effect.ordinal, reason: reason}
    )
  end

  @doc """
  Emits `[:statifier_oban, :timer, :cancelled]` - the spec 6.3 sweep ran
  and cancelled `count` stored jobs. `count: 0` is a no-op, not an error.
  """
  @spec timer_cancelled(scope(), Cancel.t(), non_neg_integer()) :: :ok
  def timer_cancelled(scope, %Cancel{} = effect, count) do
    :telemetry.execute(
      [:statifier_oban, :timer, :cancelled],
      %{system_time: System.system_time(), count: count},
      %{
        scope: scope,
        send_id: effect.send_id,
        ordinal: effect.ordinal,
        caller_context: effect.caller_context
      }
    )
  end

  @doc """
  Emits `[:statifier_oban, :invoke, :enqueued]` - the durable write for one
  `%Statifier.Effect.Invoke{}` happened, and `conflict?` says whether it
  was new.
  """
  @spec invoke_enqueued(scope(), module(), Invoke.t(), Oban.Job.t()) :: :ok
  def invoke_enqueued(scope, handler, %Invoke{} = invoke, %Oban.Job{} = job) do
    :telemetry.execute(
      [:statifier_oban, :invoke, :enqueued],
      %{system_time: System.system_time()},
      %{
        scope: scope,
        invoke_id: invoke.invoke_id,
        macrostep: invoke.macrostep,
        handler: handler,
        queue: job.queue,
        conflict?: job.conflict?,
        job_id: job.id
      }
    )
  end

  @doc """
  Emits `[:statifier_oban, :invoke, :enqueue_rejected]` - no row was
  stored. `scope` is `nil` when the rejection is the scope validation
  itself.
  """
  @spec invoke_enqueue_rejected(scope() | nil, module(), Invoke.t(), term()) :: :ok
  def invoke_enqueue_rejected(scope, handler, %Invoke{} = invoke, reason) do
    :telemetry.execute(
      [:statifier_oban, :invoke, :enqueue_rejected],
      %{system_time: System.system_time()},
      %{scope: scope, invoke_id: invoke.invoke_id, handler: handler, reason: reason}
    )
  end

  @doc """
  Emits `[:statifier_oban, :invoke, :cancelled]` - the spec 6.4.3 sweep ran
  and cancelled `count` stored jobs across every generation. `count: 0` is
  a no-op, not an error.
  """
  @spec invoke_cancelled(scope(), module(), String.t(), non_neg_integer()) :: :ok
  def invoke_cancelled(scope, handler, invoke_id, count) do
    :telemetry.execute(
      [:statifier_oban, :invoke, :cancelled],
      %{system_time: System.system_time(), count: count},
      %{scope: scope, invoke_id: invoke_id, handler: handler}
    )
  end

  # -- fan-out seam

  @doc """
  Emits `[:statifier_oban, :invoke, :fan_out]` - one invocation became
  `count` durable child starts rather than an answer, and every start is
  stored.

  `policy` and `queue` are `StatifierOban.Invoke.FanOut.start/5`'s own -
  the aggregation the children were actually enqueued under, and the queue
  they went to - rather than a second reading of the invocation.
  """
  @spec invoke_fan_out(
          scope(),
          module(),
          Invoke.t(),
          non_neg_integer(),
          atom(),
          atom() | String.t(),
          Oban.Job.t()
        ) :: :ok
  def invoke_fan_out(scope, handler, %Invoke{} = invoke, count, policy, queue, %Oban.Job{} = job) do
    :telemetry.execute(
      [:statifier_oban, :invoke, :fan_out],
      %{system_time: System.system_time(), count: count},
      %{
        scope: scope,
        invoke_id: invoke.invoke_id,
        handler: handler,
        policy: policy,
        queue: queue,
        job_id: job.id,
        caller_context: invoke.caller_context
      }
    )
  end

  @doc """
  Emits `[:statifier_oban, :invoke, :child_started]` - the host's
  `c:StatifierOban.Invoke.ChildStarter.start_child/5` seam created the
  child at `index` of `count`.

  A child start is not an answer (ADR-0007): nothing was delivered into
  the run. `index` and `count` are the child's position and ride as
  metadata; `attempt` is the start job's own, so a child created on a
  retry is distinguishable from one created first time.
  """
  @spec invoke_child_started(
          scope(),
          Invoke.t(),
          non_neg_integer(),
          pos_integer(),
          Oban.Job.t()
        ) :: :ok
  def invoke_child_started(scope, %Invoke{} = invoke, index, count, %Oban.Job{} = job) do
    :telemetry.execute(
      [:statifier_oban, :invoke, :child_started],
      %{system_time: System.system_time(), attempt: job.attempt},
      %{
        scope: scope,
        invoke_id: invoke.invoke_id,
        index: index,
        count: count,
        job_id: job.id,
        caller_context: invoke.caller_context
      }
    )
  end

  @doc """
  Emits `[:statifier_oban, :invoke, :unstarted_cancelled]` - the unstarted
  half of `sb-ADR-0009` decision 6's `first_error` cancel ran and
  cancelled `count` start jobs. `count: 0` is a no-op, not an error, and
  the siblings that already have a child run are cancelled by the
  settlement side and are not counted here.
  """
  @spec invoke_unstarted_cancelled(scope(), String.t(), non_neg_integer()) :: :ok
  def invoke_unstarted_cancelled(scope, invoke_id, count) do
    :telemetry.execute(
      [:statifier_oban, :invoke, :unstarted_cancelled],
      %{system_time: System.system_time(), count: count},
      %{scope: scope, invoke_id: invoke_id}
    )
  end

  # -- delivery seam

  @doc """
  Emits `[:statifier_oban, :timer, :fired]` - the delivery seam fed the
  event back into a live run.
  """
  @spec timer_fired(scope(), SendDelayed.t(), module(), Oban.Job.t()) :: :ok
  def timer_fired(scope, %SendDelayed{} = effect, delivery, %Oban.Job{} = job) do
    :telemetry.execute(
      [:statifier_oban, :timer, :fired],
      %{system_time: System.system_time(), attempt: job.attempt},
      %{
        scope: scope,
        send_id: effect.send_id,
        ordinal: effect.ordinal,
        delivery: delivery,
        job_id: job.id,
        caller_context: effect.caller_context
      }
    )
  end

  @doc """
  Emits `[:statifier_oban, :timer, :discarded]` - the spec 6.2 drop, as
  data. `reason` is the delivery seam's own
  `t:StatifierOban.Timer.Delivery.discard_reason/0`.
  """
  @spec timer_discarded(scope(), SendDelayed.t(), module(), term(), Oban.Job.t()) :: :ok
  def timer_discarded(scope, %SendDelayed{} = effect, delivery, reason, %Oban.Job{} = job) do
    :telemetry.execute(
      [:statifier_oban, :timer, :discarded],
      %{system_time: System.system_time(), attempt: job.attempt},
      %{
        scope: scope,
        send_id: effect.send_id,
        ordinal: effect.ordinal,
        delivery: delivery,
        reason: reason,
        job_id: job.id,
        caller_context: effect.caller_context
      }
    )
  end

  @doc """
  Emits `[:statifier_oban, :invoke, :delivered]` - `run/1` (or `run/2`)
  completed and the seam fed `done.invoke.<invoke_id>` into a live run.
  """
  @spec invoke_delivered(scope(), module(), Invoke.t(), module(), Oban.Job.t()) :: :ok
  def invoke_delivered(scope, handler, %Invoke{} = invoke, delivery, %Oban.Job{} = job) do
    :telemetry.execute(
      [:statifier_oban, :invoke, :delivered],
      %{system_time: System.system_time(), attempt: job.attempt},
      %{
        scope: scope,
        invoke_id: invoke.invoke_id,
        macrostep: invoke.macrostep,
        handler: handler,
        delivery: delivery,
        job_id: job.id
      }
    )
  end

  @doc """
  Emits `[:statifier_oban, :invoke, :discarded]` - a completed invocation
  landed on a run that is no longer live, dropped the same way a fired
  timer is.
  """
  @spec invoke_discarded(scope(), module(), Invoke.t(), module(), term(), Oban.Job.t()) :: :ok
  def invoke_discarded(scope, handler, %Invoke{} = invoke, delivery, reason, %Oban.Job{} = job) do
    :telemetry.execute(
      [:statifier_oban, :invoke, :discarded],
      %{system_time: System.system_time(), attempt: job.attempt},
      %{
        scope: scope,
        invoke_id: invoke.invoke_id,
        macrostep: invoke.macrostep,
        handler: handler,
        delivery: delivery,
        reason: reason,
        job_id: job.id
      }
    )
  end

  @doc """
  Emits `[:statifier_oban, :invoke, :failed]` - the terminal attempt gave
  up and `error.communication.invoke.<invoke_id>` went into the run.

  Mirrors `c:StatifierOban.Invoke.Delivery.deliver_failure/3`: `reason` is
  ADR-0005's three-class vocabulary and `attempts` follows its semantics -
  `max_attempts` for the two `run/1` classes, the cancelling attempt's own
  number for `"undecodable"`. `handler` is `nil` for `"undecodable"`,
  where the row never reached handler resolution.
  """
  @spec invoke_failed(
          scope(),
          module() | nil,
          String.t(),
          String.t(),
          String.t(),
          pos_integer(),
          term()
        ) :: :ok
  def invoke_failed(scope, handler, invoke_id, reason, detail, attempts, job_id) do
    :telemetry.execute(
      [:statifier_oban, :invoke, :failed],
      %{system_time: System.system_time(), attempts: attempts},
      %{
        scope: scope,
        invoke_id: invoke_id,
        reason: reason,
        detail: detail,
        handler: handler,
        job_id: job_id
      }
    )
  end
end
