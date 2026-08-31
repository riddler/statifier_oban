defmodule StatifierOban.Invoke.CancellableStatesTest do
  # Not async: shares the one SQLite repo and oban_jobs table (ADR-0002
  # harness). Unlike SelfCancelTest this one runs no queue at all - it
  # forces job rows into each state directly, because the question here
  # is only which states `perform_cancel/3`'s query reaches.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2, where: 3]

  alias Statifier.Effect.Invoke
  alias StatifierOban.Invoke.{Handler, Worker}
  alias StatifierOban.{TestInvokeHandler, TestRepo}

  @type_string "myapp:authorize"

  # Everything an invoke job can be in before it has run. `executing` is
  # the one non-terminal state left out, and sob-84c is why.
  @pending_states ~w(suspended scheduled available retryable)

  @terminal_states ~w(completed discarded cancelled)

  setup do
    start_supervised!(
      {Oban,
       name: TestInvokeHandler.oban_name(),
       repo: TestRepo,
       engine: Oban.Engines.Lite,
       testing: :manual}
    )

    :ok
  end

  for state <- @pending_states do
    # Sabotage: dropped `suspended` from @cancellable_states in
    # handler.ex - went red on the suspended row (it survived its own
    # cancel). Also narrowed the attribute to ~w(available), which took
    # the scheduled and retryable rows red too. Both reverted.
    test "a #{state} invoke job is cancelled", context do
      scope = scope_for(context)
      id = stored_job_id(scope, "inv_states")
      force_state(id, unquote(state))

      assert :ok = Handler.perform(TestInvokeHandler, {:cancel, "inv_states"}, ctx_for(scope))
      assert %Oban.Job{state: "cancelled"} = TestRepo.get!(Oban.Job, id)
    end
  end

  # Sabotage: added `executing` to @cancellable_states - went red here
  # (the executing row came back "cancelled"). Reverted. SelfCancelTest
  # proves the same rule against a live process; this pins the query
  # itself, which is the part a host can reason about.
  test "an executing invoke job is not cancelled: it is already doing the work", context do
    scope = scope_for(context)
    id = stored_job_id(scope, "inv_states")
    force_state(id, "executing")

    assert :ok = Handler.perform(TestInvokeHandler, {:cancel, "inv_states"}, ctx_for(scope))
    assert %Oban.Job{state: "executing"} = TestRepo.get!(Oban.Job, id)
  end

  # Sabotage: not applicable - this asserts about Oban's own state
  # vocabulary, not about `lib/`, so there is nothing in this repo to
  # mutate. (Adding a fictional state to the local list does take it red,
  # which only re-proves the assertion, not any behavior of ours.)
  # It is the review point the literal @cancellable_states list in
  # handler.ex names - a new Oban state lands here as a failure rather
  # than as an invocation that silently stops being cancellable.
  test "the pending set plus executing plus the terminal set is all of Oban's states" do
    known = Enum.map(@pending_states ++ ["executing"] ++ @terminal_states, &String.to_atom/1)

    assert Enum.sort(Oban.Job.states()) == Enum.sort(known)
  end

  defp scope_for(%{line: line}), do: "invoke_states_#{line}"

  defp ctx_for(scope) do
    %{session_id: scope, invoke_types: nil, invoke_handlers: %{@type_string => TestInvokeHandler}}
  end

  defp stored_job_id(scope, invoke_id) do
    assert :ok =
             Handler.perform(
               TestInvokeHandler,
               {:start, invoke_fixture(invoke_id)},
               ctx_for(scope)
             )

    worker = Oban.Worker.to_string(Worker)

    [%Oban.Job{id: id}] =
      Oban.Job
      |> where([j], j.worker == ^worker)
      |> where([j], j.args["scope"] == ^scope and j.args["invoke_id"] == ^invoke_id)
      |> TestRepo.all()

    id
  end

  defp force_state(id, state) do
    {1, _} = TestRepo.update_all(from(j in Oban.Job, where: j.id == ^id), set: [state: state])
    :ok
  end

  defp invoke_fixture(invoke_id) do
    %Invoke{
      invoke_id: invoke_id,
      type: @type_string,
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
end
