defmodule StatifierOban.RestartRoundTripTest do
  # The sob-2hx epic's acceptance clause, as a test: schedule -> restart ->
  # fire/cancel, against the one durable store (the suite's SQLite repo).
  #
  # "Restart" here is full process death, as far as the harness allows: the
  # Oban instance and the whole Statifier runtime (registry, session
  # supervisor, every session) are stopped, and a brand-new Oban instance
  # under a different name is started over the same durable store - the
  # host-supplied shape from ADR-0002, where the store is what survives and
  # every process is disposable.
  #
  # Not async: shares the one SQLite repo and oban_jobs table (ADR-0002
  # harness) and the globally named Statifier.Supervisor.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Statifier.Effect.{Cancel, SendDelayed}
  alias StatifierOban.{Config, TestRepo, Timer}

  @oban_before StatifierOban.RoundTripObanBefore
  @oban_after StatifierOban.RoundTripObanAfter

  # Two hops on the same event: a duplicate delivery is observable as the
  # session reaching "c" instead of resting in "b".
  @chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
    <state id="a">
      <transition event="reminder" target="b"/>
    </state>
    <state id="b">
      <transition event="reminder" target="c"/>
    </state>
    <state id="c"/>
  </scxml>
  """

  setup context do
    queue = "round_trip_#{context.line}"
    scope = "run_rt_#{context.line}"

    boot(@oban_before, :oban_before)
    {:ok, config_before} = Config.new(oban: @oban_before, timers_queue: queue)
    {:ok, config_after} = Config.new(oban: @oban_after, timers_queue: queue)

    %{queue: queue, scope: scope, before: config_before, after: config_after}
  end

  # sabotage: narrowed Worker's unique window to
  # `states: [:scheduled, :available, :executing, :retryable]` - went red
  # here (the post-completion replay inserted a second job: conflict?
  # false, job_count 2, and the second drain delivered again, driving the
  # session to "c") - reverted.
  test "schedule -> restart -> fire: the event delivers exactly once",
       %{queue: queue, scope: scope, before: config_before, after: config_after} do
    start_session!(scope)
    effect = send_delayed_fixture()

    assert {:ok, %Oban.Job{id: id, conflict?: false}} =
             Timer.schedule(config_before, scope, effect)

    restart()

    # The job outlived every process; nothing has touched it yet.
    assert %Oban.Job{state: "scheduled"} = TestRepo.get!(Oban.Job, id)

    # The host resumes the run under the same scope, and re-executing the
    # drive after the crash rebuilds the byte-identical effect: dedup makes
    # that replay a no-op against the stored job.
    pid = start_session!(scope)

    assert {:ok, %Oban.Job{id: ^id, conflict?: true}} =
             Timer.schedule(config_after, scope, effect)

    assert job_count(queue) == 1

    assert %{success: 1, cancelled: 0, failure: 0} = drain(@oban_after, queue)

    # Exactly once, the headline: one attempt on the one completed row, a
    # replay after completion still conflicts, a second drain finds
    # nothing, and the session rests in "b" - a duplicate delivery would
    # have driven it on to "c".
    assert %Oban.Job{state: "completed", attempt: 1} = TestRepo.get!(Oban.Job, id)

    assert {:ok, %Oban.Job{id: ^id, conflict?: true}} =
             Timer.schedule(config_after, scope, effect)

    assert job_count(queue) == 1
    assert %{success: 0, cancelled: 0, failure: 0} = drain(@oban_after, queue)

    assert %{status: :running, configuration: configuration, queued_events: 0} =
             Statifier.Session.status(pid)

    assert MapSet.member?(configuration, "b")
    refute MapSet.member?(configuration, "c")
  end

  # sabotage: covered by the unique-window mutation above - the replay
  # resurrected the cancelled timer as a fresh job and the drain delivered
  # it (success: 1, session left "a") - went red, reverted.
  test "schedule -> cancel -> restart: the cancellation holds",
       %{queue: queue, scope: scope, before: config_before, after: config_after} do
    start_session!(scope)
    effect = send_delayed_fixture()

    assert {:ok, %Oban.Job{id: id}} = Timer.schedule(config_before, scope, effect)
    assert {:ok, 1} = Timer.cancel(config_before, scope, cancel_fixture())

    restart()

    # The cancelled row survived as cancelled.
    assert %Oban.Job{state: "cancelled"} = TestRepo.get!(Oban.Job, id)

    # Resumed run, replayed drive: the replay is the same scheduling
    # decision, so it conflicts with the cancelled row rather than
    # resurrecting the timer - and nothing fires.
    pid = start_session!(scope)

    assert {:ok, %Oban.Job{id: ^id, conflict?: true}} =
             Timer.schedule(config_after, scope, effect)

    assert job_count(queue) == 1

    assert %{success: 0, cancelled: 0, failure: 0} = drain(@oban_after, queue)

    assert %Oban.Job{state: "cancelled"} = TestRepo.get!(Oban.Job, id)

    assert %{status: :running, configuration: configuration, queued_events: 0} =
             Statifier.Session.status(pid)

    assert MapSet.member?(configuration, "a")
  end

  # sabotage: Delivery.Session's empty-lookup clause returned :delivered -
  # went red here (the drain completed the job instead of cancelling it,
  # and the row carried no discard) - reverted.
  test "schedule -> restart without resuming the run: discarded, as data on the row",
       %{queue: queue, scope: scope, before: config_before} do
    start_session!(scope)

    assert {:ok, %Oban.Job{id: id}} = Timer.schedule(config_before, scope, send_delayed_fixture())

    restart()

    # Nobody resumes the run: the fired timer must be discarded per spec
    # 6.2, not delivered and not retried, with the reason readable on the
    # cancelled row.
    assert %{cancelled: 1, success: 0, failure: 0} = drain(@oban_after, queue)

    assert %Oban.Job{state: "cancelled", errors: [%{"error" => error}]} =
             TestRepo.get!(Oban.Job, id)

    assert error =~ "discarded"
    assert error =~ "terminated"
  end

  # The simulated node death: every process goes down - sessions, the
  # registry, the Oban instance - and a new Oban instance under a new name
  # comes up over the same durable store.
  defp restart do
    stop_supervised!(:oban_before)
    stop_supervised!(Statifier.Supervisor)
    boot(@oban_after, :oban_after)
  end

  defp boot(oban_name, child_id) do
    start_supervised!(Statifier.Supervisor)

    start_supervised!(
      Supervisor.child_spec(
        {Oban, name: oban_name, repo: TestRepo, engine: Oban.Engines.Lite, testing: :manual},
        id: child_id
      )
    )
  end

  defp drain(oban_name, queue) do
    Oban.drain_queue(oban_name, queue: queue, with_scheduled: true)
  end

  defp start_session!(scope) do
    {:ok, machine} = Statifier.compile(@chart)
    {:ok, pid} = Statifier.start_session(machine, session_id: scope)
    pid
  end

  defp job_count(queue) do
    TestRepo.aggregate(from(j in Oban.Job, where: j.queue == ^queue), :count)
  end

  defp send_delayed_fixture do
    # A day-long delay: the proof is that the fire time is data in the
    # store, not process state - the drain fires it deliberately.
    %SendDelayed{
      event: "reminder",
      target: nil,
      type: nil,
      data: nil,
      send_id: "send_1",
      delay_ms: 86_400_000,
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

  defp cancel_fixture do
    %Cancel{
      send_id: "send_1",
      c_index: 1,
      owner: {:onexit, 0, 0},
      macrostep: 2,
      microstep: 0,
      round: 1,
      ordinal: 2,
      caller_context: nil
    }
  end
end
