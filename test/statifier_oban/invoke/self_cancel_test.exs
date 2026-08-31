defmodule StatifierOban.Invoke.SelfCancelTest do
  # Not async: shares the one SQLite repo (ADR-0002 harness), and unlike
  # every other invoke test this one runs a *real* Oban queue rather than
  # draining inline. That is the whole point - `testing: :manual` runs
  # the job in the test process, where `Oban.cancel_all_jobs/2` has no
  # separate executing process to signal, so an inline drain cannot see
  # sob-84c at all.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [where: 3]

  alias Statifier.Effect.Invoke
  alias StatifierOban.Config
  alias StatifierOban.Invoke.{Handler, Worker}
  alias StatifierOban.TestRepo

  @oban_name StatifierOban.InvokeSelfCancelTestOban
  @queue :sob_84c_invoke_self_cancel

  # No worker ever runs this queue, so a job inserted into it stays
  # `available` for the whole test. It is how the pending twin is held
  # still while its sibling executes - and it doubles as evidence that
  # the cancel match ignores the queue, exactly as the unique key does.
  @idle_queue :sob_84c_invoke_idle

  @type_string "myapp:authorize"

  # Long enough that a `:pkill` published on the notifier has landed by
  # the time the survival message is sent, so the survival message means
  # the execution was not killed rather than that the kill was still in
  # flight.
  @survival_window_ms 500

  defmodule Delivery do
    @moduledoc false
    # The run-liveness seam, stubbed: there is no live session here, and
    # the default `Delivery.Session` would discard every completion and
    # cancel the row we are asserting about.
    @behaviour StatifierOban.Invoke.Delivery

    @impl StatifierOban.Invoke.Delivery
    def deliver(_scope, _invoke_id, _donedata), do: :delivered

    @impl StatifierOban.Invoke.Delivery
    def deliver_failure(_scope, _invoke_id, _details), do: :delivered
  end

  defmodule SelfCancellingHandler do
    @moduledoc false
    # A handler that cancels its own `invoke_id` from inside `run/1`,
    # which is the shape sob-84c was found in: spec 6.4.3 cancels an
    # invocation when its invoking state is exited, and the commonest
    # way that state is exited is this very invocation completing - so
    # the cancel and the work are the same Oban job.
    #
    # The scope does not travel on `%Invoke{}`, so the test's scope and
    # pid ride `:persistent_term` under the `invoke_id`, the same way
    # `StatifierOban.SelfCancellingDelivery` carries them for timers.
    use StatifierOban.Invoke.Handler

    alias StatifierOban.Invoke.Handler
    alias StatifierOban.Invoke.SelfCancelTest

    @impl StatifierOban.Invoke.Handler
    def config, do: SelfCancelTest.config(SelfCancelTest.queue())

    @impl StatifierOban.Invoke.Handler
    def run(%Statifier.Effect.Invoke{invoke_id: invoke_id}) do
      {scope, test_pid} = :persistent_term.get({__MODULE__, invoke_id})

      send(test_pid, {:invoke_started, invoke_id})

      result = Handler.perform_cancel(__MODULE__, invoke_id, %{session_id: scope})

      send(test_pid, {:self_cancel_returned, result})

      Process.sleep(SelfCancelTest.survival_window_ms())

      send(test_pid, {:invoke_survived, invoke_id})

      {:ok, %{"result" => "authorized"}}
    end
  end

  defmodule IdleQueueHandler do
    @moduledoc false
    # Same instance, same worker, a queue nothing runs: this is only how
    # the pending twin gets stored.
    use StatifierOban.Invoke.Handler

    alias StatifierOban.Invoke.SelfCancelTest

    @impl StatifierOban.Invoke.Handler
    def config, do: SelfCancelTest.config(SelfCancelTest.idle_queue())

    @impl StatifierOban.Invoke.Handler
    def run(%Statifier.Effect.Invoke{}), do: {:ok, %{}}
  end

  @spec queue() :: atom()
  def queue, do: @queue

  @spec idle_queue() :: atom()
  def idle_queue, do: @idle_queue

  @spec survival_window_ms() :: pos_integer()
  def survival_window_ms, do: @survival_window_ms

  @spec config(atom()) :: Config.t()
  def config(queue) do
    {:ok, config} =
      Config.new(
        oban: @oban_name,
        timers_queue: "timers_unused",
        invoke_queue: queue,
        invoke_delivery: Delivery
      )

    config
  end

  setup context do
    start_supervised!(
      {Oban, name: @oban_name, repo: TestRepo, engine: Oban.Engines.Lite, queues: [{@queue, 1}]}
    )

    scope = "invoke_self_cancel_#{context.line}"
    invoke_id = "inv_self_cancel_#{context.line}"

    :persistent_term.put({SelfCancellingHandler, invoke_id}, {scope, self()})
    on_exit(fn -> :persistent_term.erase({SelfCancellingHandler, invoke_id}) end)

    %{scope: scope, invoke_id: invoke_id}
  end

  # Sabotage: dropped the `j.state in @cancellable_states` clause from
  # invoke_jobs/2 (main's shape) - went red exactly as the timer half
  # did: no :invoke_survived message ever arrived and the row landed
  # "cancelled" carrying `{:cancel, :shutdown}` instead of "completed".
  # Reverted.
  test "an invocation that cancels its own invoke_id is not killed by it",
       %{scope: scope, invoke_id: invoke_id} do
    ctx = ctx_for(scope, SelfCancellingHandler)

    assert :ok = Handler.perform(SelfCancellingHandler, {:start, invoke_fixture(invoke_id)}, ctx)

    assert_receive {:invoke_started, ^invoke_id}, 10_000
    assert_receive {:self_cancel_returned, :ok}, 5_000

    # A :pkill would have landed inside this window if the query had
    # swept the executing row.
    assert_receive {:invoke_survived, ^invoke_id}, 5_000

    assert [%Oban.Job{id: id}] = stored_jobs(scope, invoke_id)
    assert await_terminal_state(id) == "completed"
  end

  # Sabotage: narrowed @cancellable_states to ~w(scheduled) - went red
  # (the pending twin sat in "available", so it survived the self-cancel
  # and the assertion saw "available"). Reverted.
  test "the same self-cancel still cancels the pending twins under its invoke_id",
       %{scope: scope, invoke_id: invoke_id} do
    twin = invoke_fixture(invoke_id, macrostep: 2)

    assert :ok =
             Handler.perform(
               IdleQueueHandler,
               {:start, twin},
               ctx_for(scope, IdleQueueHandler)
             )

    assert :ok =
             Handler.perform(
               SelfCancellingHandler,
               {:start, invoke_fixture(invoke_id)},
               ctx_for(scope, SelfCancellingHandler)
             )

    assert_receive {:invoke_started, ^invoke_id}, 10_000
    assert_receive {:self_cancel_returned, :ok}, 5_000
    assert_receive {:invoke_survived, ^invoke_id}, 5_000

    assert [%Oban.Job{} = executing, %Oban.Job{} = pending] =
             Enum.sort_by(stored_jobs(scope, invoke_id), & &1.args["macrostep"])

    assert %Oban.Job{state: "cancelled"} = TestRepo.get!(Oban.Job, pending.id)
    assert await_terminal_state(executing.id) == "completed"
  end

  # The worker finishes shortly after `run/1` returns; poll the row
  # rather than sleep a guessed interval.
  @spec await_terminal_state(integer(), non_neg_integer()) :: String.t()
  defp await_terminal_state(id, attempts \\ 100)

  defp await_terminal_state(id, 0), do: TestRepo.get!(Oban.Job, id).state

  defp await_terminal_state(id, attempts) do
    case TestRepo.get!(Oban.Job, id) do
      %Oban.Job{state: state} when state in ["completed", "cancelled", "discarded"] ->
        state

      %Oban.Job{} ->
        Process.sleep(50)
        await_terminal_state(id, attempts - 1)
    end
  end

  defp ctx_for(scope, handler) do
    %{session_id: scope, invoke_types: nil, invoke_handlers: %{@type_string => handler}}
  end

  defp stored_jobs(scope, invoke_id) do
    worker = Oban.Worker.to_string(Worker)

    Oban.Job
    |> where([j], j.worker == ^worker)
    |> where([j], j.args["scope"] == ^scope and j.args["invoke_id"] == ^invoke_id)
    |> TestRepo.all()
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
end
