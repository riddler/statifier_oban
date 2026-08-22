defmodule StatifierOban.Timer.Delivery.SessionTest do
  # Not async: Statifier.Supervisor is a globally named singleton
  # (Statifier.Registry / Statifier.SessionSupervisor are fixed names).
  use ExUnit.Case, async: false

  alias Statifier.Effect.SendDelayed
  alias StatifierOban.Timer.Delivery

  @live_chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
    <state id="a">
      <transition event="reminder" target="b"/>
    </state>
    <state id="b"/>
  </scxml>
  """

  @halting_chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="f">
    <final id="f"/>
  </scxml>
  """

  setup context do
    start_supervised!(Statifier.Supervisor)
    %{scope: "sess_#{context.line}"}
  end

  # sabotage: the empty-lookup clause returned :delivered - went red
  # (the discard became a claimed delivery), reverted.
  test "step 1: an unregistered scope discards as :terminated", %{scope: scope} do
    assert {:discarded, :terminated} = Delivery.Session.deliver(scope, fired_fixture())
  end

  # sabotage: deliver_if_running's :running clause skipped send_event -
  # went red (configuration stayed on "a"), reverted.
  test "a live session gets the event through the session's own door", %{scope: scope} do
    pid = start_session!(@live_chart, scope)

    assert :delivered = Delivery.Session.deliver(scope, fired_fixture())

    # send_event/2 is a cast from this process and status/1 a call from
    # this process, so ordered delivery guarantees the event is processed
    # before the status reply.
    assert %{status: :running, configuration: configuration, queued_events: 0} =
             Statifier.Session.status(pid)

    assert MapSet.member?(configuration, "b")
  end

  # sabotage: the halted clause fell through to send_event + :delivered -
  # went red (queued_events became 1 and the result claimed delivery),
  # reverted.
  test "step 2: a halted-but-alive session discards rather than queueing", %{scope: scope} do
    pid = start_session!(@halting_chart, scope)

    assert %{status: :done} = Statifier.Session.status(pid)
    assert {:discarded, :done} = Delivery.Session.deliver(scope, fired_fixture())

    # The process is alive - "live" is stricter than "not terminated" -
    # and nothing sat down on its queue.
    assert Process.alive?(pid)
    assert %{status: :done, queued_events: 0} = Statifier.Session.status(pid)
  end

  # sabotage: the catch clause was removed - went red (the exit crashed
  # the test process instead of returning the discard), reverted.
  test "a session dying under the status call is the same :terminated fact", %{scope: scope} do
    # A registered process whose :status call stops without replying is
    # the deterministic stand-in for the lookup-then-death race: the
    # caller of status/1 exits, and deliver/2 must report the discard
    # rather than crash the worker.
    start_supervised!({StatifierOban.StoppingSessionStub, scope})

    assert {:discarded, :terminated} = Delivery.Session.deliver(scope, fired_fixture())
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
