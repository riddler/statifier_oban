defmodule StatifierOban.Timer.CancellableStatesTest do
  # Not async: shares the one SQLite repo (ADR-0002 harness). Unlike
  # SelfCancelTest this one runs no queue at all - it forces job rows into
  # each state directly, because the question here is only which states
  # `cancel/3`'s query reaches.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Statifier.Effect.{Cancel, SendDelayed}
  alias StatifierOban.{Config, TestRepo, Timer}

  @oban_name StatifierOban.CancellableStatesTestOban

  # Everything a timer can be in before it has fired. `executing` is the
  # one non-terminal state left out, and sob-uon is why.
  @pending_states ~w(suspended scheduled available retryable)

  @terminal_states ~w(completed discarded cancelled)

  setup context do
    start_supervised!(
      {Oban, name: @oban_name, repo: TestRepo, engine: Oban.Engines.Lite, testing: :manual}
    )

    queue = "cancellable_states_#{context.line}"
    {:ok, config} = Config.new(oban: @oban_name, timers_queue: queue)

    %{config: config, scope: "run_#{context.line}"}
  end

  for state <- @pending_states do
    # sabotage: dropped `suspended` from @intended in
    # StatifierOban.CancellableStates (re-run for sob-axb, when the list
    # moved there) - went red on the suspended row (it survived its own
    # cancel), which is the defect this generated test exists to catch.
    # Earlier, on the literal list in timer.ex, narrowing it to
    # ~w(available) took the scheduled and retryable rows red too. All
    # reverted.
    test "a #{state} timer is cancelled", %{config: config, scope: scope} do
      id = scheduled_job_id(config, scope)
      force_state(id, unquote(state))

      assert {:ok, 1} = Timer.cancel(config, scope, cancel_fixture())
      assert %Oban.Job{state: "cancelled"} = TestRepo.get!(Oban.Job, id)
    end
  end

  # sabotage: added `executing` to @intended in
  # StatifierOban.CancellableStates (re-run for sob-axb) - went red here
  # (the executing row came back "cancelled" and the count was 1).
  # Reverted. SelfCancelTest proves the same rule against a live process;
  # this pins the query itself, which is the part a host can reason about.
  test "an executing timer is not cancelled: it has already fired",
       %{config: config, scope: scope} do
    id = scheduled_job_id(config, scope)
    force_state(id, "executing")

    assert {:ok, 0} = Timer.cancel(config, scope, cancel_fixture())
    assert %Oban.Job{state: "executing"} = TestRepo.get!(Oban.Job, id)
  end

  # sabotage: not applicable - this asserts about Oban's own state
  # vocabulary, not about `lib/`, so there is nothing in this repo to
  # mutate. (Adding a fictional state to the local list does take it red,
  # which only re-proves the assertion, not any behavior of ours.)
  # It is the review point `StatifierOban.CancellableStates` names - a
  # new Oban state lands here as a failure rather than as a job that
  # silently stops being cancellable.
  test "the pending set plus executing plus the terminal set is all of Oban's states" do
    known = Enum.map(@pending_states ++ ["executing"] ++ @terminal_states, &String.to_atom/1)

    assert Enum.sort(Oban.Job.states()) == Enum.sort(known)
  end

  defp scheduled_job_id(config, scope) do
    assert {:ok, %Oban.Job{id: id}} = Timer.schedule(config, scope, send_delayed_fixture())
    id
  end

  defp force_state(id, state) do
    {1, _} = TestRepo.update_all(from(j in Oban.Job, where: j.id == ^id), set: [state: state])
    :ok
  end

  defp cancel_fixture do
    %Cancel{
      send_id: "send_1",
      c_index: 1,
      owner: {:onexit, 0, 0},
      macrostep: 2,
      microstep: 0,
      round: 1,
      ordinal: 5
    }
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
