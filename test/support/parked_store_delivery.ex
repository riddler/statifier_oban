defmodule StatifierOban.ParkedStoreDelivery do
  @moduledoc """
  A `StatifierOban.Timer.Delivery` over a stand-in execution store whose
  executions can be parked by a chart migration, shaped on the README's
  "Delivering timers to a durable execution" module.

  The store is an `Agent` holding each scope's status. `step/2` answers
  with the shapes `statifier_persistence`'s `step/5` answers: an active
  execution steps and answers `{:ok, execution, machine_state}` (the
  machine state a stand-in map), a finished one is
  `{:discarded, %{status: status}}`, an unknown one is
  `{:error, :execution_not_found}`, and a parked one is
  `{:error, {:needs_migration, execution}}`. `deliver/2` maps them with
  the README module's arms, so the needs_migration arm raises.

  Test-only. A delivered event is reported to the pid `start_link/1` was
  handed, because the delivery behaviour hands an implementation only
  the scope and the effect.
  """

  @behaviour StatifierOban.Timer.Delivery

  use Agent

  alias Statifier.Effect.SendDelayed
  alias StatifierOban.Timer.Delivery

  @typedoc "A stored execution's status, in `statifier_persistence`'s words."
  @type status :: :active | :needs_migration | :completed

  @doc "Starts the store, reporting deliveries to `test_pid`."
  @spec start_link(pid()) :: Agent.on_start()
  def start_link(test_pid) when is_pid(test_pid) do
    Agent.start_link(fn -> %{test_pid: test_pid, executions: %{}} end, name: __MODULE__)
  end

  @doc "Stores `scope` with `status`."
  @spec put(String.t(), status()) :: :ok
  def put(scope, status) do
    Agent.update(__MODULE__, &put_in(&1, [:executions, scope], status))
  end

  @doc """
  Puts a parked execution back to `:active`, as `statifier_persistence`'s
  `unpark/3` does for a parked one.

  Only a parked scope is accepted: any other scope fails a match inside
  the store, and the call exits, failing the calling test. `unpark/3` instead answers an `:active`
  execution unchanged and a terminal one `{:discarded, execution}`; the
  stand-in is stricter so a test that unparks the wrong scope fails.
  """
  @spec unpark(String.t()) :: :ok
  def unpark(scope) do
    Agent.update(__MODULE__, fn state ->
      :needs_migration = get_in(state, [:executions, scope])
      put_in(state, [:executions, scope], :active)
    end)
  end

  @impl StatifierOban.Timer.Delivery
  def deliver(execution_id, %SendDelayed{} = effect) do
    event = Delivery.fired_event(execution_id, effect)

    case step(execution_id, event) do
      {:ok, _execution, _machine_state} ->
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

  @spec step(String.t(), Statifier.Event.t()) ::
          {:ok, map(), map()} | {:discarded, map()} | {:error, term()}
  defp step(execution_id, event) do
    %{test_pid: test_pid, executions: executions} = Agent.get(__MODULE__, & &1)

    case Map.fetch(executions, execution_id) do
      {:ok, :active} ->
        send(test_pid, {:parked_store_delivered, execution_id, event})
        {:ok, %{execution_id: execution_id, status: :active}, %{}}

      {:ok, :needs_migration} ->
        {:error, {:needs_migration, %{execution_id: execution_id, status: :needs_migration}}}

      {:ok, status} ->
        {:discarded, %{execution_id: execution_id, status: status}}

      :error ->
        {:error, :execution_not_found}
    end
  end
end
