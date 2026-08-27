defmodule StatifierOban.Timer.WorkerTest do
  # Not async: shares the one SQLite repo and oban_jobs table (ADR-0002
  # harness) and the globally named Statifier.Supervisor.
  use ExUnit.Case, async: false

  alias Statifier.Effect.SendDelayed
  alias StatifierOban.{Config, TestRepo, Timer}
  alias StatifierOban.Timer.{JobArgs, Worker}

  @oban_name StatifierOban.Timer.WorkerTestOban

  @live_chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
    <state id="a">
      <transition event="reminder" target="b"/>
    </state>
    <state id="b"/>
  </scxml>
  """

  defmodule RecordingDelivery do
    @moduledoc false
    @behaviour StatifierOban.Timer.Delivery

    @impl StatifierOban.Timer.Delivery
    def deliver(scope, %SendDelayed{} = effect) do
      send(:worker_test_listener, {:delivered_via_seam, scope, effect})
      :delivered
    end
  end

  setup context do
    start_supervised!(Statifier.Supervisor)

    start_supervised!(
      {Oban, name: @oban_name, repo: TestRepo, engine: Oban.Engines.Lite, testing: :manual}
    )

    queue = "worker_test_#{context.line}"
    {:ok, config} = Config.new(oban: @oban_name, timers_queue: queue)

    %{config: config, queue: queue, scope: "sess_wt_#{context.line}"}
  end

  # sabotage: perform's :delivered clause returned {:cancel, :nope} - went
  # red (success: 0, cancelled: 1, and the session never left "a"),
  # reverted.
  test "a fired job delivers into the live run and the job completes",
       %{config: config, queue: queue, scope: scope} do
    pid = start_session!(@live_chart, scope)
    assert {:ok, %Oban.Job{id: id}} = Timer.schedule(config, scope, fired_fixture())

    assert %{success: 1, cancelled: 0, failure: 0} = drain(queue)

    assert %Oban.Job{state: "completed"} = TestRepo.get!(Oban.Job, id)
    assert %{configuration: configuration} = Statifier.Session.status(pid)
    assert MapSet.member?(configuration, "b")
  end

  # sabotage: perform's {:discarded, reason} clause returned :ok - went
  # red (the job completed instead of cancelling), reverted.
  test "a fired job against a dead run discards: cancelled, not crashed",
       %{config: config, queue: queue, scope: scope} do
    assert {:ok, %Oban.Job{id: id}} = Timer.schedule(config, scope, fired_fixture())

    assert %{cancelled: 1, failure: 0, success: 0} = drain(queue)

    # The spec 6.2 discard is data on the row - sob-2hx.6 asserts against
    # exactly this shape after its simulated restart.
    assert %Oban.Job{state: "cancelled", errors: [%{"error" => error}]} =
             TestRepo.get!(Oban.Job, id)

    assert error =~ "discarded"
    assert error =~ "terminated"
  end

  # sabotage: delivery_module/1 ignored the meta and always returned the
  # default - went red (the seam module never ran), reverted.
  test "the config's delivery module is the seam the fired job goes through",
       %{queue: queue, scope: scope} do
    Process.register(self(), :worker_test_listener)

    {:ok, config} =
      Config.new(oban: @oban_name, timers_queue: queue, delivery: RecordingDelivery)

    effect = fired_fixture()
    assert {:ok, _job} = Timer.schedule(config, scope, effect)

    assert %{success: 1} = drain(queue)
    assert_received {:delivered_via_seam, ^scope, ^effect}
  end

  # sabotage: resolve_delivery's ensure-loaded check was dropped for a
  # bare {:ok, module} - went red (failure: 0), reverted.
  test "a delivery module missing from the deployed code retries, not discards",
       %{queue: queue, scope: scope} do
    {:ok, config} =
      Config.new(oban: @oban_name, timers_queue: queue, delivery: StatifierOban.NoSuchDelivery)

    assert {:ok, %Oban.Job{id: id}} = Timer.schedule(config, scope, fired_fixture())

    assert %{failure: 1, cancelled: 0} = drain(queue)

    # The typed error, not a crash out of a bare module call: the row
    # stays retryable across the host deploying the missing module.
    assert %Oban.Job{state: "retryable", errors: [%{"error" => error}]} =
             TestRepo.get!(Oban.Job, id)

    assert error =~ "invalid_delivery"
  end

  # sabotage: resolve_delivery's rescue clause re-raised - went red (the
  # drain crashed instead of counting a failure), reverted.
  test "a delivery module this node has never seen is the same retryable fact",
       %{queue: queue, scope: scope} do
    never_seen = "Elixir.StatifierOban.NeverCompiled#{:erlang.unique_integer([:positive])}"
    %Oban.Job{id: id} = insert_with_meta(queue, scope, %{"delivery" => never_seen})

    assert %{failure: 1, cancelled: 0} = drain(queue)

    # Returned as the typed error, not the ArgumentError crashing through.
    assert %Oban.Job{state: "retryable", errors: [%{"error" => error}]} =
             TestRepo.get!(Oban.Job, id)

    assert error =~ "invalid_delivery"
  end

  # sabotage: delivery_module's nil clause returned the RecordingDelivery
  # module - went red (the job completed against a dead run), reverted.
  test "a job stored without delivery meta falls back to the Session default",
       %{queue: queue, scope: scope} do
    insert_with_meta(queue, scope, %{})

    assert %{cancelled: 1, failure: 0} = drain(queue)
  end

  # sabotage: delivery_module's non-binary clause was widened to fall back
  # to the default - went red (cancelled instead of failed), reverted.
  test "a non-string delivery meta value is retryable, never guessed around",
       %{queue: queue, scope: scope} do
    insert_with_meta(queue, scope, %{"delivery" => 42})

    assert %{failure: 1, cancelled: 0} = drain(queue)
  end

  defp drain(queue) do
    Oban.drain_queue(@oban_name, queue: queue, with_scheduled: true)
  end

  defp insert_with_meta(queue, scope, meta) do
    {:ok, args} = JobArgs.from_effect(scope, fired_fixture())
    changeset = Worker.new(args, queue: queue, meta: meta)

    {:ok, job} = Oban.insert(@oban_name, changeset)
    job
  end

  defp start_session!(xml, scope) do
    {:ok, machine} = Statifier.compile(xml)
    {:ok, pid} = Statifier.start_session(machine, session_id: scope)
    pid
  end

  defp fired_fixture do
    %SendDelayed{
      event: "reminder",
      target: nil,
      type: nil,
      data: nil,
      send_id: "send_1",
      delay_ms: 0,
      c_index: 0,
      owner: {:onentry, 0, 0},
      macrostep: 1,
      microstep: 0,
      round: 1,
      ordinal: 1,
      id_from_author?: false,
      caller_context: nil
    }
  end
end
