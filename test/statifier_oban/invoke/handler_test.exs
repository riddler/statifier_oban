defmodule StatifierOban.Invoke.HandlerTest do
  # Not async: shares the one SQLite repo and oban_jobs table (ADR-0002
  # harness) and the globally named Statifier.Supervisor.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [where: 3]

  alias Statifier.Effect.Invoke
  alias StatifierOban.{Config, TestInvokeHandler, TestRepo}
  alias StatifierOban.Invoke.{Handler, Worker}

  @type_string "myapp:enrich"

  # The acceptance chart: "calling" invokes the handler under test;
  # `namelist="result"` plus the empty `<finalize/>` auto-assigns the
  # returned donedata, and the cond proves it ran before the done.invoke
  # transition was selected. Document order gives the specific
  # done.invoke.inv_e2e transition priority over the bare prefix match.
  @chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="calling" datamodel="predicator">
      <datamodel>
          <data id="result"/>
      </datamodel>
      <state id="calling">
          <invoke id="inv_e2e" type="myapp:enrich" namelist="result">
              <finalize/>
          </invoke>
          <transition event="done.invoke.inv_e2e" cond="result == 'enriched'" target="finished"/>
          <transition event="done.invoke" target="wrong"/>
          <transition event="abort" target="aborted"/>
      </state>
      <state id="finished"/>
      <state id="wrong"/>
      <state id="aborted"/>
  </scxml>
  """

  defmodule NoQueueHandler do
    @moduledoc false
    use StatifierOban.Invoke.Handler

    @impl StatifierOban.Invoke.Handler
    def config do
      {:ok, config} =
        Config.new(oban: StatifierOban.TestInvokeHandler.oban_name(), timers_queue: "t")

      config
    end

    @impl StatifierOban.Invoke.Handler
    def run(%Invoke{}), do: {:ok, nil}
  end

  setup do
    start_supervised!(Statifier.Supervisor)

    start_supervised!(
      {Oban,
       name: TestInvokeHandler.oban_name(),
       repo: TestRepo,
       engine: Oban.Engines.Lite,
       testing: :manual}
    )

    :ok
  end

  # sabotage: `Handler.perform_start/3` returned :ok without inserting -
  # went red (no stored job ever appeared, wait_until timed out), reverted.
  test "acceptance: the work runs in an Oban job and completion reaches the session as done.invoke with finalize" do
    {:ok, session} =
      Statifier.Session.start_link(machine(),
        invoke_handlers: %{@type_string => TestInvokeHandler}
      )

    scope = Statifier.Session.session_id(session)

    # The session's executor performed the base's start instruction: one
    # stored job, keyed on this run's scope and the author-written id.
    wait_until(fn -> match?([_job], stored_jobs(scope, "inv_e2e")) end)
    assert [%Oban.Job{state: "available"}] = stored_jobs(scope, "inv_e2e")

    # Running the job runs TestInvokeHandler.run/1 and delivers the
    # completion through the default Session delivery seam. The queue is
    # shared across this module's tests, so the evidence is this job's
    # own terminal state, not the drain counts.
    drain()
    assert [%Oban.Job{state: "completed"}] = stored_jobs(scope, "inv_e2e")

    # done.invoke.inv_e2e arrived, and the cond only passes because the
    # empty <finalize/> auto-assigned donedata's "result" first.
    wait_until(fn ->
      Statifier.Session.status(session).configuration == MapSet.new(["finished"])
    end)
  end

  # sabotage: the base's injected `cancel/2` planned `{:ok, []}` instead
  # of the cancel instruction - went red (the stored job stayed
  # "available" after the exit), reverted.
  test "exiting the invoking state cancels the stored job through the same handler" do
    {:ok, session} =
      Statifier.Session.start_link(machine(),
        invoke_handlers: %{@type_string => TestInvokeHandler}
      )

    scope = Statifier.Session.session_id(session)
    wait_until(fn -> match?([_job], stored_jobs(scope, "inv_e2e")) end)

    Statifier.Session.send_event(session, "abort")

    wait_until(fn ->
      Statifier.Session.status(session).configuration == MapSet.new(["aborted"])
    end)

    wait_until(fn ->
      match?([%Oban.Job{state: "cancelled"}], stored_jobs(scope, "inv_e2e"))
    end)
  end

  # sabotage: `StatifierOban.Invoke.Worker`'s `{:discarded, reason}` arm
  # returned :ok - went red (the job completed instead of cancelling),
  # reverted.
  test "a completed invoke against a dead run is discarded the same way a fired timer is" do
    ctx = ctx_for("sess_invoke_gone")

    assert :ok = Handler.perform(TestInvokeHandler, {:start, invoke_fixture("inv_dead")}, ctx)
    drain()

    assert [%Oban.Job{state: "cancelled", errors: [%{"error" => error}]}] =
             stored_jobs("sess_invoke_gone", "inv_dead")

    assert error =~ "discarded"
    assert error =~ "terminated"
  end

  # sabotage: `Handler.perform_start/3`'s duplicate insert grew a second
  # row when Worker's unique keys were dropped - went red (two stored
  # jobs), reverted. Pins the {scope, invoke_id, macrostep} uniqueness the base's
  # idempotency claim rests on.
  test "performing the same start instruction again conflicts instead of inserting a second job" do
    ctx = ctx_for("sess_invoke_replay")
    payload = {:start, invoke_fixture("inv_replay")}

    assert :ok = Handler.perform(TestInvokeHandler, payload, ctx)
    assert :ok = Handler.perform(TestInvokeHandler, payload, ctx)

    assert [%Oban.Job{}] = stored_jobs("sess_invoke_replay", "inv_replay")
  end

  # sabotage: "macrostep" removed from Worker's unique keys - went red
  # (the second entry's insert conflicted with the first and only one
  # job was stored), reverted. Pins the re-entry half of the key: an
  # authored invoke id is byte-identical on every re-entry of its state,
  # and only the macrostep tells a fresh scheduling decision apart from
  # a crash replay of the old one.
  test "re-entering the state inserts a fresh job: same authored invoke_id, later macrostep" do
    ctx = ctx_for("sess_invoke_reentry")

    assert :ok =
             Handler.perform(
               TestInvokeHandler,
               {:start, invoke_fixture("resolve", macrostep: 1)},
               ctx
             )

    assert :ok =
             Handler.perform(
               TestInvokeHandler,
               {:start, invoke_fixture("resolve", macrostep: 2)},
               ctx
             )

    assert [%Oban.Job{}, %Oban.Job{}] = stored_jobs("sess_invoke_reentry", "resolve")
  end

  # sabotage: `invoke_jobs/2` additionally filtered on a macrostep the
  # cancel does not carry - went red (the older generation's job stayed
  # "available"), reverted. Pins that cancellation still addresses
  # {scope, invoke_id} across every generation, exactly as spec 6.3's
  # sendid cancellation matches every timer under a send_id.
  test "a cancel matches every generation stored under {scope, invoke_id}" do
    ctx = ctx_for("sess_invoke_gens")

    assert :ok =
             Handler.perform(
               TestInvokeHandler,
               {:start, invoke_fixture("gen", macrostep: 1)},
               ctx
             )

    assert :ok =
             Handler.perform(
               TestInvokeHandler,
               {:start, invoke_fixture("gen", macrostep: 2)},
               ctx
             )

    assert :ok = Handler.perform(TestInvokeHandler, {:cancel, "gen"}, ctx)

    assert [%Oban.Job{state: "cancelled"}, %Oban.Job{state: "cancelled"}] =
             stored_jobs("sess_invoke_gens", "gen")
  end

  # sabotage: `Handler.perform_cancel/3` was pointed at a query matching
  # nothing - this test stayed green (a cancel matching nothing is the
  # documented no-op) while the exit-cancels test above went red, which
  # is the pair of observations the note records.
  test "a cancel for an invoke_id the store never saw is a no-op, not an error" do
    ctx = ctx_for("sess_invoke_unknown")

    assert :ok = Handler.perform(TestInvokeHandler, {:cancel, "inv_never_started"}, ctx)
  end

  # sabotage: `invoke_queue/1`'s nil arm returned {:ok, :default} - went
  # red (the insert succeeded into :default), reverted. A host without
  # :invoke_queue must fail loudly, never fall back into a host queue.
  test "a config without :invoke_queue fails the perform with a typed error" do
    ctx = ctx_for("sess_invoke_noqueue")

    assert {:error, {:missing_option, :invoke_queue}} =
             Handler.perform(NoQueueHandler, {:start, invoke_fixture("inv_noq")}, ctx)

    assert [] = stored_jobs("sess_invoke_noqueue", "inv_noq")
  end

  # sabotage: `validated_scope/1` accepted any ctx - went red ({:ok, _}
  # came back for the scopeless ctx), reverted.
  test "a ctx without a usable session_id is a typed error, not a bare-key crash" do
    assert {:error, {:invalid_scope, _ctx}} =
             Handler.perform(TestInvokeHandler, {:start, invoke_fixture("inv_bad")}, %{
               session_id: nil,
               invoke_types: nil,
               invoke_handlers: %{}
             })
  end

  # -- helpers ------------------------------------------------------------

  defp machine do
    {:ok, machine} = Statifier.compile(@chart)
    machine
  end

  defp ctx_for(scope) do
    %{session_id: scope, invoke_types: nil, invoke_handlers: %{@type_string => TestInvokeHandler}}
  end

  defp invoke_fixture(invoke_id, overrides \\ []) do
    %Invoke{
      invoke_id: invoke_id,
      type: @type_string,
      src: nil,
      params: %{},
      content: nil,
      autoforward: false,
      state_index: 0,
      invoke_index: 0,
      macrostep: Keyword.get(overrides, :macrostep, 1),
      microstep: 1,
      round: 1
    }
  end

  defp drain do
    Oban.drain_queue(TestInvokeHandler.oban_name(), queue: TestInvokeHandler.queue())
  end

  defp stored_jobs(scope, invoke_id) do
    worker = Oban.Worker.to_string(Worker)

    Oban.Job
    |> where([j], j.worker == ^worker)
    |> where([j], j.args["scope"] == ^scope and j.args["invoke_id"] == ^invoke_id)
    |> TestRepo.all()
  end

  defp wait_until(check, attempts \\ 200)

  defp wait_until(check, 0) do
    flunk("condition never became true: #{inspect(check)}")
  end

  defp wait_until(check, attempts) do
    if check.() do
      :ok
    else
      Process.sleep(5)
      wait_until(check, attempts - 1)
    end
  end
end
