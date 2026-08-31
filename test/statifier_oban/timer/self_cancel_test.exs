defmodule StatifierOban.Timer.SelfCancelTest do
  # Not async: shares the one SQLite repo (ADR-0002 harness), and unlike
  # every other timer test this one runs a *real* Oban queue rather than
  # draining inline. That is the whole point - `testing: :manual` runs the
  # job in the test process, where `Oban.cancel_all_jobs/2` has no
  # separate executing process to signal, so an inline drain cannot see
  # sob-uon at all.
  use ExUnit.Case, async: false

  alias Statifier.Effect.SendDelayed
  alias StatifierOban.{Config, SelfCancellingDelivery, TestRepo, Timer}

  @oban_name StatifierOban.SelfCancelTestOban
  @queue :sob_uon_self_cancel

  setup context do
    start_supervised!(
      {Oban, name: @oban_name, repo: TestRepo, engine: Oban.Engines.Lite, queues: [{@queue, 1}]}
    )

    {:ok, config} =
      Config.new(
        oban: @oban_name,
        timers_queue: @queue,
        delivery: SelfCancellingDelivery
      )

    scope = "self_cancel_#{context.line}"
    :ok = SelfCancellingDelivery.register(scope, config, self())
    on_exit(fn -> SelfCancellingDelivery.unregister(scope) end)

    %{config: config, scope: scope}
  end

  # sabotage: dropped the `j.state in @cancellable_states` clause from
  # timer_jobs/1 (main's shape) - went red exactly as reported downstream:
  # the self-cancel came back {:ok, 1}, no :delivery_survived message ever
  # arrived, and the row landed "cancelled" carrying
  # `{:cancel, :shutdown}` instead of "completed". Reverted.
  test "a delivery that cancels its own send_id is not killed by it",
       %{config: config, scope: scope} do
    effect = %{send_delayed_fixture() | delay_ms: 0}

    assert {:ok, %Oban.Job{id: id}} = Timer.schedule(config, scope, effect)

    assert_receive {:delivery_started, ^scope}, 10_000

    # The executing job is its own cancel's only candidate, and it is not
    # swept: the cancel matches nothing.
    assert_receive {:self_cancel_returned, {:ok, 0}}, 5_000

    # A :pkill would have landed inside this window if the query had swept
    # the executing row.
    assert_receive {:delivery_survived, ^scope}, 5_000

    assert await_terminal_state(id) == "completed"
  end

  # sabotage: narrowed @cancellable_states to ~w(available) - went red
  # (the pending twin sat in "scheduled", so the self-cancel returned
  # {:ok, 0} and the twin survived). Reverted.
  test "the same self-cancel still cancels the pending twins under its send_id",
       %{config: config, scope: scope} do
    effect = %{send_delayed_fixture() | delay_ms: 0}
    twin = %{send_delayed_fixture() | ordinal: effect.ordinal + 10}

    assert {:ok, %Oban.Job{id: id}} = Timer.schedule(config, scope, effect)
    assert {:ok, %Oban.Job{id: twin_id}} = Timer.schedule(config, scope, twin)

    assert_receive {:delivery_started, ^scope}, 10_000
    assert_receive {:self_cancel_returned, {:ok, 1}}, 5_000
    assert_receive {:delivery_survived, ^scope}, 5_000

    assert %Oban.Job{state: "cancelled"} = TestRepo.get!(Oban.Job, twin_id)
    assert await_terminal_state(id) == "completed"
  end

  # The worker finishes shortly after `:delivered`; poll the row rather
  # than sleep a guessed interval.
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

  defp send_delayed_fixture do
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
    }
  end
end
