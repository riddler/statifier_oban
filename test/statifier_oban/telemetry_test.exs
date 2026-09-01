defmodule StatifierOban.TelemetryTest do
  # Not async: shares the one SQLite repo and oban_jobs table (ADR-0002
  # harness) and the globally named Statifier.Supervisor.
  use ExUnit.Case, async: false

  alias Statifier.Effect.{Cancel, Invoke, SendDelayed}
  alias StatifierOban.{Config, Telemetry, TestInvokeHandler, TestRepo, Timer}
  alias StatifierOban.Invoke.Handler
  alias StatifierOban.Invoke.JobArgs, as: InvokeJobArgs
  alias StatifierOban.Invoke.Worker, as: InvokeWorker

  # `TestInvokeHandler.config/0` is a pure read of a fixed instance name
  # and queue, so the invoke half of this module runs against that name.
  # The timer half shares the same instance under its own queue.
  @oban_name StatifierOban.InvokeTestOban
  @invoke_queue "invoke_test"

  @live_chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
    <state id="a">
      <transition event="reminder" target="b"/>
    </state>
    <state id="b"/>
  </scxml>
  """

  defmodule RecordingInvokeDelivery do
    @moduledoc false
    @behaviour StatifierOban.Invoke.Delivery

    @impl StatifierOban.Invoke.Delivery
    def deliver(_scope, _invoke_id, _donedata), do: :delivered

    @impl StatifierOban.Invoke.Delivery
    def deliver_failure(_scope, _invoke_id, _failure), do: :delivered
  end

  defmodule FailingRunHandler do
    @moduledoc false
    use StatifierOban.Invoke.Handler

    @impl StatifierOban.Invoke.Handler
    def config, do: StatifierOban.TestInvokeHandler.config()

    @impl StatifierOban.Invoke.Handler
    def run(%Invoke{}), do: {:error, :gateway_down}
  end

  defmodule NoQueueHandler do
    @moduledoc false
    use StatifierOban.Invoke.Handler

    @impl StatifierOban.Invoke.Handler
    def config do
      {:ok, config} =
        StatifierOban.Config.new(
          oban: StatifierOban.InvokeTestOban,
          timers_queue: "timers_unused"
        )

      config
    end

    @impl StatifierOban.Invoke.Handler
    def run(%Invoke{}), do: {:ok, %{}}
  end

  setup context do
    start_supervised!(Statifier.Supervisor)

    start_supervised!(
      {Oban, name: @oban_name, repo: TestRepo, engine: Oban.Engines.Lite, testing: :manual}
    )

    attach_all()

    # Per-test queues: the module shares one SQLite oban_jobs table with
    # every other test file, and `Handler.perform_start/3` always enqueues
    # into `TestInvokeHandler`'s fixed queue, so a drain of that queue
    # would pick up rows other tests left behind.
    %{
      timers_queue: "telemetry_timers_#{context.line}",
      queue: "telemetry_invoke_#{context.line}",
      scope: "sess_tel_#{context.line}"
    }
  end

  # -- the surface itself -------------------------------------------------

  # sabotage: dropped `:discarded` from `@invoke_kinds` - went red here
  # (10 names, the invoke discard name missing) and, as a side effect, on
  # the invoke :discarded test, whose event stopped being attachable at
  # all; reverted.
  test "events/0 enumerates all eleven names, and every one is emitted by this module" do
    assert Telemetry.events() == [
             [:statifier_oban, :timer, :scheduled],
             [:statifier_oban, :timer, :schedule_rejected],
             [:statifier_oban, :timer, :cancelled],
             [:statifier_oban, :timer, :fired],
             [:statifier_oban, :timer, :discarded],
             [:statifier_oban, :invoke, :enqueued],
             [:statifier_oban, :invoke, :enqueue_rejected],
             [:statifier_oban, :invoke, :cancelled],
             [:statifier_oban, :invoke, :delivered],
             [:statifier_oban, :invoke, :discarded],
             [:statifier_oban, :invoke, :failed]
           ]

    assert length(Telemetry.events()) == 11
  end

  # -- timer scheduling seam ----------------------------------------------

  # sabotage: `Telemetry.timer_scheduled/3` passed `job.id` as the
  # `conflict?` metadatum - went red on the metadata comparison (the job
  # id arrived where `false` belongs), reverted.
  test "a successful schedule emits :scheduled, and the replay reports conflict?",
       %{timers_queue: queue, scope: scope} do
    {:ok, config} = Config.new(oban: @oban_name, timers_queue: queue)
    effect = send_delayed_fixture(delay_ms: 60_000, caller_context: %{"traceparent" => "00-ab"})

    assert {:ok, %Oban.Job{id: id, scheduled_at: scheduled_at}} =
             Timer.schedule(config, scope, effect)

    assert_received {:event, [:statifier_oban, :timer, :scheduled], measurements, metadata}

    assert %{system_time: system_time, delay_ms: 60_000} = measurements
    assert is_integer(system_time)

    assert metadata == %{
             scope: scope,
             send_id: "send_1",
             ordinal: 1,
             macrostep: 1,
             microstep: 0,
             round: 1,
             scheduled_at: scheduled_at,
             queue: queue,
             conflict?: false,
             job_id: id,
             caller_context: %{"traceparent" => "00-ab"}
           }

    assert {:ok, %Oban.Job{}} = Timer.schedule(config, scope, effect)
    assert_received {:event, [:statifier_oban, :timer, :scheduled], _m, %{conflict?: true}}
  end

  # sabotage: the `%SendDelayed{target: target}` schedule clause returned
  # its typed error without emitting - went red (no event arrived),
  # reverted.
  test "the st-ADR-0055 bailout emits :schedule_rejected with the typed reason",
       %{timers_queue: queue, scope: scope} do
    {:ok, config} = Config.new(oban: @oban_name, timers_queue: queue)
    effect = send_delayed_fixture(target: "#_parent")

    assert {:error, {:non_self_target, "#_parent"}} = Timer.schedule(config, scope, effect)

    assert_received {:event, [:statifier_oban, :timer, :schedule_rejected], measurements,
                     metadata}

    assert %{system_time: system_time} = measurements
    assert is_integer(system_time)
    assert Map.keys(measurements) == [:system_time]

    assert metadata == %{
             scope: scope,
             send_id: "send_1",
             ordinal: 1,
             reason: {:non_self_target, "#_parent"}
           }
  end

  # sabotage: `report_schedule/3`'s error clause emitted :scheduled
  # instead - went red (no :schedule_rejected event arrived), reverted.
  test "a key error also emits :schedule_rejected, and nothing is stored",
       %{timers_queue: queue} do
    {:ok, config} = Config.new(oban: @oban_name, timers_queue: queue)

    assert {:error, :invalid_scope} = Timer.schedule(config, "", send_delayed_fixture())

    assert_received {:event, [:statifier_oban, :timer, :schedule_rejected], _m, metadata}
    assert metadata.reason == :invalid_scope
    assert metadata.scope == ""
  end

  # sabotage: `cancel/3` emitted a hardcoded `1` rather than the sweep's
  # own return - went red here (`2` came back as `1`) and on the
  # matched-nothing case below, reverted.
  test "a cancel emits :cancelled carrying the sweep's own count",
       %{timers_queue: queue, scope: scope} do
    {:ok, config} = Config.new(oban: @oban_name, timers_queue: queue)

    assert {:ok, %Oban.Job{}} = Timer.schedule(config, scope, send_delayed_fixture())

    assert {:ok, %Oban.Job{}} =
             Timer.schedule(config, scope, send_delayed_fixture(ordinal: 2))

    assert {:ok, 2} = Timer.cancel(config, scope, cancel_fixture())

    assert_received {:event, [:statifier_oban, :timer, :cancelled], measurements, metadata}

    assert %{system_time: system_time, count: 2} = measurements
    assert is_integer(system_time)

    assert metadata == %{
             scope: scope,
             send_id: "send_1",
             ordinal: 5,
             caller_context: nil
           }
  end

  # sabotage: covered by the hardcoded-`1` mutation above - went red here
  # too, reverted. A `0` is data: spec 6.3's cancel of a sendid nothing
  # is pending under is a no-op, not an error.
  test "a cancel matching nothing still emits, with count 0",
       %{timers_queue: queue, scope: scope} do
    {:ok, config} = Config.new(oban: @oban_name, timers_queue: queue)

    assert {:ok, 0} = Timer.cancel(config, scope, cancel_fixture())

    assert_received {:event, [:statifier_oban, :timer, :cancelled], %{count: 0}, _metadata}
  end

  # sabotage: `cancel/3` emitted before the `Key.cancellation_key/2`
  # check rather than after the sweep - went red (an event arrived for a
  # call that never reached the store), reverted.
  test "a cancel that never reaches the sweep emits nothing", %{timers_queue: queue} do
    {:ok, config} = Config.new(oban: @oban_name, timers_queue: queue)

    assert {:error, :invalid_scope} = Timer.cancel(config, "", cancel_fixture())

    refute_received {:event, [:statifier_oban, :timer, :cancelled], _m, _md}
  end

  # -- timer delivery seam ------------------------------------------------

  # sabotage: `Timer.Worker.perform/1`'s `:delivered` arm emitted the
  # :discarded event instead - went red (no :fired event arrived),
  # reverted.
  test "a fired job delivering into a live run emits :fired",
       %{timers_queue: queue, scope: scope} do
    {:ok, config} = Config.new(oban: @oban_name, timers_queue: queue)
    start_session!(@live_chart, scope)

    effect = send_delayed_fixture(delay_ms: 0, caller_context: {:trace, 7})
    assert {:ok, %Oban.Job{id: id}} = Timer.schedule(config, scope, effect)

    assert %{success: 1, cancelled: 0, failure: 0} = drain(queue)

    assert_received {:event, [:statifier_oban, :timer, :fired], measurements, metadata}

    assert %{system_time: system_time, attempt: 1} = measurements
    assert is_integer(system_time)

    assert metadata == %{
             scope: scope,
             send_id: "send_1",
             ordinal: 1,
             delivery: StatifierOban.Timer.Delivery.Session,
             job_id: id,
             caller_context: {:trace, 7}
           }
  end

  # sabotage: `Timer.Worker`'s `{:discarded, reason}` arm passed a
  # hardcoded `:delivered` where the seam's own verdict belongs - went
  # red (`:terminated` was expected), reverted. This is the spec 6.2 drop
  # as data, the thing Oban buries inside `:result`.
  test "a fired job against a dead run emits :discarded with the seam's reason",
       %{timers_queue: queue, scope: scope} do
    {:ok, config} = Config.new(oban: @oban_name, timers_queue: queue)

    assert {:ok, %Oban.Job{id: id}} =
             Timer.schedule(config, scope, send_delayed_fixture(delay_ms: 0))

    assert %{cancelled: 1, failure: 0, success: 0} = drain(queue)

    assert_received {:event, [:statifier_oban, :timer, :discarded], measurements, metadata}

    assert %{system_time: _, attempt: 1} = measurements

    assert metadata == %{
             scope: scope,
             send_id: "send_1",
             ordinal: 1,
             delivery: StatifierOban.Timer.Delivery.Session,
             reason: :terminated,
             job_id: id,
             caller_context: nil
           }
  end

  # -- invoke scheduling seam ---------------------------------------------

  # sabotage: `enqueue/4` emitted ahead of `Oban.insert/2`, off a bare
  # `%Oban.Job{}` - went red (a nil job id and `conflict?: nil` where the
  # stored row's values belong), reverted.
  test "a successful enqueue emits :enqueued, and the replay reports conflict?",
       %{scope: scope} do
    invoke = invoke_fixture("inv_tel_enq")

    assert :ok = Handler.perform_start(TestInvokeHandler, invoke, %{session_id: scope})

    assert_received {:event, [:statifier_oban, :invoke, :enqueued], measurements, metadata}

    assert %{system_time: system_time} = measurements
    assert is_integer(system_time)
    assert Map.keys(measurements) == [:system_time]

    assert %{
             scope: ^scope,
             invoke_id: "inv_tel_enq",
             macrostep: 1,
             handler: TestInvokeHandler,
             queue: @invoke_queue,
             conflict?: false,
             job_id: job_id
           } = metadata

    assert is_integer(job_id)

    assert :ok = Handler.perform_start(TestInvokeHandler, invoke, %{session_id: scope})
    assert_received {:event, [:statifier_oban, :invoke, :enqueued], _m, %{conflict?: true}}

    # `perform_start/3` enqueues into `TestInvokeHandler`'s fixed queue,
    # which other test files drain and count. Leave nothing runnable
    # behind for them to pick up.
    assert :ok = Handler.perform_cancel(TestInvokeHandler, "inv_tel_enq", %{session_id: scope})
  end

  # sabotage: `perform_start/3`'s invalid-scope arm passed `ctx` through
  # as the `scope` metadatum - went red (the raw ctx map arrived where
  # `nil` was expected), reverted. ADR-0006 decision 9: unvalidated host
  # state never rides an event.
  test "an invalid scope emits :enqueue_rejected with a nil scope" do
    invoke = invoke_fixture("inv_tel_noscope")

    assert {:error, {:invalid_scope, %{}}} =
             Handler.perform_start(TestInvokeHandler, invoke, %{})

    assert_received {:event, [:statifier_oban, :invoke, :enqueue_rejected], measurements,
                     metadata}

    assert %{system_time: system_time} = measurements
    assert is_integer(system_time)
    assert Map.keys(measurements) == [:system_time]

    assert metadata == %{
             scope: nil,
             invoke_id: "inv_tel_noscope",
             handler: TestInvokeHandler,
             reason: {:invalid_scope, %{}}
           }
  end

  # sabotage: `enqueue/4`'s `else` arm returned `{:error, reason}` without
  # emitting - went red (no event for the missing-queue rejection),
  # reverted.
  test "a missing :invoke_queue emits :enqueue_rejected with the validated scope",
       %{scope: scope} do
    invoke = invoke_fixture("inv_tel_noqueue")

    assert {:error, {:missing_option, :invoke_queue}} =
             Handler.perform_start(NoQueueHandler, invoke, %{session_id: scope})

    assert_received {:event, [:statifier_oban, :invoke, :enqueue_rejected], _m, metadata}

    assert metadata == %{
             scope: scope,
             invoke_id: "inv_tel_noqueue",
             handler: NoQueueHandler,
             reason: {:missing_option, :invoke_queue}
           }
  end

  # sabotage: `perform_cancel/3` emitted a hardcoded `0` rather than the
  # sweep's own return - went red on the `count: 1` assertion, reverted.
  test "an invoke cancel emits :cancelled carrying the sweep's own count", %{scope: scope} do
    invoke = invoke_fixture("inv_tel_cancel")
    assert :ok = Handler.perform_start(TestInvokeHandler, invoke, %{session_id: scope})

    assert :ok =
             Handler.perform_cancel(TestInvokeHandler, "inv_tel_cancel", %{session_id: scope})

    assert_received {:event, [:statifier_oban, :invoke, :cancelled], measurements, metadata}

    assert %{system_time: _, count: 1} = measurements

    assert metadata == %{
             scope: scope,
             invoke_id: "inv_tel_cancel",
             handler: TestInvokeHandler
           }
  end

  # -- invoke delivery seam -----------------------------------------------

  # sabotage: `execute/5`'s `:delivered` arm emitted the :discarded event
  # instead - went red (no :delivered event arrived), reverted.
  test "a completed invocation delivered into a live run emits :delivered",
       %{queue: queue, scope: scope} do
    job =
      insert_invoke!(queue, scope, "inv_tel_delivered", TestInvokeHandler,
        meta: %{"delivery" => Atom.to_string(RecordingInvokeDelivery)}
      )

    assert %{success: 1, cancelled: 0, failure: 0} = drain(queue)

    assert_received {:event, [:statifier_oban, :invoke, :delivered], measurements, metadata}

    assert %{system_time: _, attempt: 1} = measurements

    assert metadata == %{
             scope: scope,
             invoke_id: "inv_tel_delivered",
             macrostep: 1,
             handler: TestInvokeHandler,
             delivery: RecordingInvokeDelivery,
             job_id: job.id
           }
  end

  # sabotage: `execute/5`'s `{:discarded, reason}` arm passed `nil` where
  # the seam's own verdict belongs - went red (`:terminated` was
  # expected), reverted.
  test "a completed invocation against a dead run emits :discarded",
       %{queue: queue, scope: scope} do
    job = insert_invoke!(queue, scope, "inv_tel_discarded", TestInvokeHandler)

    assert %{cancelled: 1, failure: 0, success: 0} = drain(queue)

    assert_received {:event, [:statifier_oban, :invoke, :discarded], measurements, metadata}

    assert %{system_time: _, attempt: 1} = measurements

    assert metadata == %{
             scope: scope,
             invoke_id: "inv_tel_discarded",
             macrostep: 1,
             handler: TestInvokeHandler,
             delivery: StatifierOban.Invoke.Delivery.Session,
             reason: :terminated,
             job_id: job.id
           }
  end

  # sabotage: `maybe_fail/7` emitted a hardcoded `"run_crashed"` class
  # rather than the caller's - went red here, reverted.
  test "the terminal attempt of a failing run emits :failed with ADR-0005's class",
       %{queue: queue, scope: scope} do
    # `max_attempts: 1` makes the first attempt the terminal one, which is
    # what the emission gate keys on; Oban reports that as a discard.
    job =
      insert_invoke!(queue, scope, "inv_tel_failed", FailingRunHandler,
        max_attempts: 1,
        meta: %{"delivery" => Atom.to_string(RecordingInvokeDelivery)}
      )

    assert %{discard: 1, success: 0, cancelled: 0} = drain(queue)

    assert_received {:event, [:statifier_oban, :invoke, :failed], measurements, metadata}

    assert %{system_time: _, attempts: 1} = measurements

    assert metadata == %{
             scope: scope,
             invoke_id: "inv_tel_failed",
             reason: "run_failed",
             detail: inspect(:gateway_down),
             handler: FailingRunHandler,
             job_id: job.id
           }
  end

  # sabotage: `maybe_fail/7`'s `attempt >= max_attempts` guard was
  # relaxed to `attempt >= 0` - went red here on the `refute_received`
  # (the non-terminal attempt emitted), reverted. A retry that will be
  # tried again is already `[:oban, :job, :exception]`.
  test "a non-terminal failing attempt emits nothing", %{queue: queue, scope: scope} do
    insert_invoke!(queue, scope, "inv_tel_retry", FailingRunHandler,
      max_attempts: 5,
      meta: %{"delivery" => Atom.to_string(RecordingInvokeDelivery)}
    )

    assert %{failure: 1, discard: 0} = drain(queue)

    refute_received {:event, [:statifier_oban, :invoke, :failed], _m, _md}
  end

  # sabotage: `fail_undecodable/2` emitted `args["handler"]`, the raw
  # stored string, as the `handler` metadatum - went red (a binary
  # arrived where `nil` was expected), reverted. The decode that would
  # have named the module is the thing that failed.
  test "an undecodable row emits :failed with a nil handler", %{queue: queue, scope: scope} do
    {:ok, args} =
      InvokeJobArgs.from_invoke(scope, TestInvokeHandler, invoke_fixture("inv_tel_bad"))

    job =
      insert_args!(queue, Map.put(args, "macrostep", "not-an-integer"),
        meta: %{"delivery" => Atom.to_string(RecordingInvokeDelivery)}
      )

    assert %{cancelled: 1, failure: 0, success: 0} = drain(queue)

    assert_received {:event, [:statifier_oban, :invoke, :failed], measurements, metadata}

    assert %{system_time: _, attempts: 1} = measurements

    assert %{
             scope: ^scope,
             invoke_id: "inv_tel_bad",
             reason: "undecodable",
             handler: nil,
             job_id: job_id,
             detail: detail
           } = metadata

    assert job_id == job.id
    assert detail =~ "invalid_field"
  end

  # -- helpers ------------------------------------------------------------

  # Attached as a module function rather than a closure: `:telemetry`
  # logs a performance warning for a local capture, and the whole
  # surface is attached on every test in this module.
  @doc false
  def relay(event, measurements, metadata, listener) do
    send(listener, {:event, event, measurements, metadata})
  end

  defp attach_all do
    handler_id = "telemetry-test-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(handler_id, Telemetry.events(), &__MODULE__.relay/4, self())

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp drain(queue) do
    Oban.drain_queue(@oban_name, queue: queue, with_scheduled: true)
  end

  defp start_session!(xml, scope) do
    {:ok, machine} = Statifier.compile(xml)
    {:ok, pid} = Statifier.start_session(machine, session_id: scope)
    pid
  end

  defp insert_invoke!(queue, scope, invoke_id, handler, opts \\ []) do
    {:ok, args} = InvokeJobArgs.from_invoke(scope, handler, invoke_fixture(invoke_id))
    insert_args!(queue, args, opts)
  end

  defp insert_args!(queue, args, opts) do
    {:ok, job} = Oban.insert(@oban_name, InvokeWorker.new(args, [queue: queue] ++ opts))
    job
  end

  defp invoke_fixture(invoke_id) do
    %Invoke{
      invoke_id: invoke_id,
      type: "myapp:authorize",
      src: nil,
      params: %{},
      content: nil,
      autoforward: false,
      state_index: 0,
      invoke_index: 0,
      macrostep: 1,
      microstep: 1,
      round: 1
    }
  end

  defp send_delayed_fixture(overrides \\ []) do
    struct!(
      %SendDelayed{
        event: "reminder",
        target: nil,
        type: nil,
        data: nil,
        send_id: "send_1",
        delay_ms: 60_000,
        c_index: 0,
        owner: {:onentry, 0, 0},
        macrostep: 1,
        microstep: 0,
        round: 1,
        ordinal: 1,
        id_from_author?: false,
        caller_context: nil
      },
      overrides
    )
  end

  defp cancel_fixture do
    %Cancel{
      send_id: "send_1",
      c_index: 1,
      owner: {:onexit, 0, 0},
      macrostep: 2,
      microstep: 0,
      round: 1,
      ordinal: 5,
      caller_context: nil
    }
  end
end
