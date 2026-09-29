defmodule StatifierOban.Timer.ParkedPersistedExecutionTest do
  # A timer firing into an execution parked in statifier_persistence's own
  # store, delivered through the README's durable module with the raise a
  # delivery that does not snooze puts in its needs_migration arm: the
  # refusal from `StatifierPersistence.Executions.step/5` raises, the job
  # stays retryable, and the attempt after `unpark/3` delivers. The stand-in test
  # beside this one (parked_execution_test.exs) carries the same
  # assertions against a store double.
  #
  # Not async: shares the one SQLite repo and oban_jobs table (ADR-0002
  # harness) and the named delivery state.
  use ExUnit.Case, async: false

  alias Statifier.Effect.SendDelayed
  alias StatifierOban.{Config, TestRepo, Timer}
  alias StatifierPersistence.{Execution, Executions, Storage}

  @oban_name StatifierOban.Timer.ParkedPersistedExecutionTestOban

  # A library loan: the due-date reminder moves an on-loan item to
  # reminded.
  @loan_chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="on_loan">
    <state id="on_loan">
      <transition event="reminder" target="reminded"/>
    </state>
    <state id="reminded"/>
  </scxml>
  """

  defmodule PersistedDelivery do
    @moduledoc false
    # The README's "Delivering timers to a durable execution" module, over
    # a `StatifierPersistence.Storage.InMemory` store the test hands it,
    # with the raise in its needs_migration arm where the README snoozes.
    # A delivered event is reported to the test pid, with the machine
    # state `step/5` answered.
    @behaviour StatifierOban.Timer.Delivery

    use Agent

    alias Statifier.Effect.SendDelayed
    alias StatifierOban.Timer.Delivery
    alias StatifierPersistence.Executions

    def start_link(%{store: _, machine: _, test_pid: _} = state) do
      Agent.start_link(fn -> state end, name: __MODULE__)
    end

    @impl StatifierOban.Timer.Delivery
    def deliver(execution_id, %SendDelayed{} = effect) do
      %{store: store, machine: machine, test_pid: test_pid} = Agent.get(__MODULE__, & &1)
      event = Delivery.fired_event(execution_id, effect)

      case Executions.step(store, execution_id, machine, event, executor: &execute/2) do
        {:ok, _execution, machine_state} ->
          send(test_pid, {:persisted_delivered, execution_id, machine_state})
          :delivered

        {:discarded, %{status: status}} ->
          {:discarded, status}

        {:error, :execution_not_found} ->
          {:discarded, :terminated}

        {:error, {:needs_migration, _execution}} ->
          raise "#{execution_id} is parked; retrying the timer"

        {:error, reason} ->
          raise "stepping #{execution_id} failed: #{inspect(reason)}"
      end
    end

    defp execute(_effect, _context), do: :ok
  end

  setup context do
    start_supervised!(
      {Oban, name: @oban_name, repo: TestRepo, engine: Oban.Engines.Lite, testing: :manual}
    )

    {:ok, machine} = Statifier.compile(@loan_chart)
    {:ok, store} = Storage.new(Storage.InMemory, [])

    start_supervised!({PersistedDelivery, %{store: store, machine: machine, test_pid: self()}})

    queue = "parked_persisted_test_#{context.line}"

    {:ok, config} =
      Config.new(oban: @oban_name, timers_queue: queue, delivery: PersistedDelivery)

    %{
      config: config,
      queue: queue,
      store: store,
      machine: machine,
      scope: "loan_parked_#{context.line}"
    }
  end

  # sabotage: the needs_migration arm of PersistedDelivery.deliver/2
  # answered {:discarded, :needs_migration} instead of raising - went red
  # (the first drain reported cancelled: 1, not failure: 1). Reverted.
  # sabotage: perform/1 in StatifierOban.Timer.Worker rescued a raise out
  # of deliver/2 as {:discarded, :needs_migration} - went red the same
  # way. Reverted.
  test "a timer firing into a parked execution is retried, then delivered after the unpark",
       %{config: config, queue: queue, store: store, machine: machine, scope: scope} do
    assert {:ok, %Execution{status: :active}, _machine_state} =
             Executions.create(store, scope, machine, executor: fn _effect, _context -> :ok end)

    # Parked as a chart migration parks it: the status alone, written
    # through the status-only writer.
    assert :ok = Storage.update_execution_status(store, scope, :needs_migration, failure: nil)

    assert {:ok, %Oban.Job{id: id}} = Timer.schedule(config, scope, fired_fixture())

    assert %{failure: 1, cancelled: 0, discard: 0, success: 0} = drain(queue)

    assert %Oban.Job{state: "retryable", attempt: 1, errors: [%{"error" => error}]} =
             TestRepo.get!(Oban.Job, id)

    assert error =~ "parked"
    refute_received {:persisted_delivered, _, _}
    assert {:ok, %{status: :needs_migration}} = Storage.fetch_execution(store, scope)

    # Still a pending timer for the scope while it waits out the park.
    assert %{^scope => 1} = Timer.pending_for(config, [scope])

    assert {:ok, %Execution{status: :active}} = Executions.unpark(store, scope)

    assert %{success: 1, failure: 0, cancelled: 0} = drain(queue)
    assert %Oban.Job{state: "completed", attempt: 2} = TestRepo.get!(Oban.Job, id)
    assert_received {:persisted_delivered, ^scope, machine_state}
    assert MapSet.equal?(Statifier.active_leaf_states(machine_state), MapSet.new(["reminded"]))
    assert {:ok, %{status: :active}} = Storage.fetch_execution(store, scope)
  end

  defp drain(queue) do
    Oban.drain_queue(@oban_name, queue: queue, with_scheduled: true)
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
