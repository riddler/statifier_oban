defmodule StatifierOban.Invoke.ChildStartWorkerTest do
  # Not async: shares the one SQLite repo and oban_jobs table (ADR-0002
  # harness).
  use ExUnit.Case, async: false

  import Ecto.Query, only: [where: 3]

  alias Statifier.Effect.Invoke
  alias StatifierOban.Invoke.{ChildStartWorker, JobArgs}
  alias StatifierOban.{TestInvokeHandler, TestRepo}

  @oban_name StatifierOban.Invoke.ChildStartWorkerTestOban
  @queue "invoke_child_start_test"

  defmodule OkStarter do
    @moduledoc false
    @behaviour StatifierOban.Invoke.ChildStarter

    @impl StatifierOban.Invoke.ChildStarter
    def start_child(parent_run_id, invoke, index, count, opts) do
      send(:child_start_listener, {:started, parent_run_id, invoke, index, count, opts})
      :ok
    end
  end

  defmodule FailingStarter do
    @moduledoc false
    @behaviour StatifierOban.Invoke.ChildStarter

    @impl StatifierOban.Invoke.ChildStarter
    def start_child(_parent_run_id, _invoke, _index, _count, _opts),
      do: {:error, :run_store_down}
  end

  setup do
    start_supervised!(
      {Oban, name: @oban_name, repo: TestRepo, engine: Oban.Engines.Lite, testing: :manual}
    )

    Process.register(self(), :child_start_listener)

    # The ADR-0002 harness shares one SQLite `oban_jobs` table across the
    # whole suite and runs no sandbox, so the key tests below - which
    # insert without draining - would otherwise be drained by the next
    # test. This queue is this module's alone.
    TestRepo.delete_all(where(Oban.Job, [j], j.queue == @queue))

    :ok
  end

  # sabotage: `perform/1`'s `with` pattern bound the decoded handler name
  # to `scope` - went red (the recorded parent run id was the handler
  # module's string), reverted.
  test "the seam is handed the parent run id and the effect the planning callback saw" do
    insert!("sess_cs_ok", "inv_cs_ok", 1, 4, OkStarter)

    assert %{success: 1, failure: 0, cancelled: 0} = drain()

    assert_received {:started, "sess_cs_ok", %Invoke{} = invoke, 1, 4, [policy: :all]}
    assert invoke.invoke_id == "inv_cs_ok"
    assert invoke.macrostep == 1
    assert invoke.params == %{"item" => "b"}
  end

  # A run store that is down is an environment fact, and the seam is
  # idempotent on the index by contract, so the job retries.
  #
  # sabotage: `start/6`'s `{:error, reason}` arm returned `:ok` - went
  # red (the job succeeded instead of failing), reverted.
  test "a seam error makes the start job retry" do
    insert!("sess_cs_fail", "inv_cs_fail", 0, 1, FailingStarter)

    assert %{success: 0, failure: 1, cancelled: 0} = drain()
  end

  # sabotage: `starter_module/1`'s catch-all clause returned
  # `{:cancel, :no_starter}` - went red (the job cancelled rather than
  # failing, so a deploy that adds the seam could never pick it up),
  # reverted.
  test "a row whose meta names no starter is a retryable error, not a cancel" do
    args = args_for("sess_cs_nostarter", "inv_cs_nostarter", 0, 1)

    {:ok, _job} = Oban.insert(@oban_name, ChildStartWorker.new(args, queue: @queue, meta: %{}))

    assert %{success: 0, failure: 1, cancelled: 0} = drain()
  end

  # sabotage: `resolve/1`'s `rescue ArgumentError` arm was removed - went
  # red (the recorded error was the raised ArgumentError rather than the
  # typed `:invalid_child_starter`), reverted.
  test "a starter name this node has never seen fails as a named seam error" do
    job = insert_with_starter_name!("sess_cs_bad", "inv_cs_bad", "Elixir.StatifierOban.NoSuch")

    assert %{success: 0, failure: 1, cancelled: 0} = drain()

    assert recorded_error(job) =~ "invalid_child_starter"
  end

  # sabotage: `resolve/1` dropped the `function_exported?` check - went
  # red (the recorded error was an UndefinedFunctionError from inside the
  # call rather than the typed refusal before it), reverted.
  test "a module that does not export the callback is refused before it is called" do
    job =
      insert_with_starter_name!(
        "sess_cs_noexport",
        "inv_cs_noexport",
        "Elixir.StatifierOban.Config"
      )

    assert %{success: 0, failure: 1, cancelled: 0} = drain()

    assert recorded_error(job) =~ "invalid_child_starter"
  end

  # No number of retries makes a row without a position into a child of
  # anything, so it cancels rather than retrying.
  #
  # sabotage: `position/1`'s error arm returned `{:error, reason}` - went
  # red (the job failed and would retry forever instead of cancelling),
  # reverted.
  test "a row carrying no index cancels rather than retrying" do
    args = args_for("sess_cs_noindex", "inv_cs_noindex", 0, 1)

    {:ok, _job} =
      Oban.insert(
        @oban_name,
        ChildStartWorker.new(Map.delete(args, "index"),
          queue: @queue,
          meta: %{"child_starter" => Atom.to_string(OkStarter)}
        )
      )

    assert %{success: 0, failure: 0, cancelled: 1} = drain()
  end

  # -- the seam's option list (RQ-031-4, sob-64p) --------------------------

  # The row's stored policy, not a default, is what the seam is handed.
  #
  # sabotage: `perform/1` passed a literal `[policy: :all]` to `start/6`
  # instead of the decoded `opts` - went red (the recorded call came back
  # `[policy: :all]` for a row storing `first_error`), reverted.
  test "the seam is handed the policy the fan-out stored on the row" do
    args = args_for("sess_cs_pol", "inv_cs_pol", 0, 1, :first_error)

    {:ok, _job} =
      Oban.insert(
        @oban_name,
        ChildStartWorker.new(args,
          queue: @queue,
          meta: %{"child_starter" => Atom.to_string(OkStarter)}
        )
      )

    assert %{success: 1, failure: 0, cancelled: 0} = drain()

    assert_received {:started, "sess_cs_pol", %Invoke{}, 0, 1, [policy: :first_error]}
  end

  # No number of retries makes an unreadable policy readable, and
  # starting the child under a guessed aggregation is the thing the
  # widened seam exists to prevent.
  #
  # sabotage: `seam_opts/1`'s error arm returned `{:error, reason}` -
  # went red (the job failed and would retry forever instead of
  # cancelling), reverted.
  test "a row whose policy is neither word cancels rather than retrying" do
    args = Map.put(args_for("sess_cs_badpol", "inv_cs_badpol", 0, 1), "policy", "any_error")

    {:ok, _job} =
      Oban.insert(
        @oban_name,
        ChildStartWorker.new(args,
          queue: @queue,
          meta: %{"child_starter" => Atom.to_string(OkStarter)}
        )
      )

    assert %{success: 0, failure: 0, cancelled: 1} = drain()

    refute_received {:started, _scope, _invoke, _index, _count, _opts}
  end

  # -- the four-component key (ADR-0007 decision 4) ------------------------

  # sabotage: the unique `keys` list dropped `:index` - went red (the
  # second insert came back as the first job with `conflict?` set),
  # reverted.
  test "two indices of one invocation are two jobs" do
    first = insert!("sess_cs_key", "inv_cs_key", 0, 2, OkStarter)
    second = insert!("sess_cs_key", "inv_cs_key", 1, 2, OkStarter)

    refute second.id == first.id
    refute second.conflict?
  end

  # sabotage: `for_child_start/4` was made to stamp a unique index per
  # call - went red (the replay inserted a second job), reverted.
  test "the same index inserted twice is one job" do
    first = insert!("sess_cs_dedup", "inv_cs_dedup", 0, 2, OkStarter)
    second = insert!("sess_cs_dedup", "inv_cs_dedup", 0, 2, OkStarter)

    assert second.id == first.id
    assert second.conflict?
  end

  # -- helpers -------------------------------------------------------------

  defp insert!(scope, invoke_id, index, count, starter) do
    {:ok, job} =
      Oban.insert(
        @oban_name,
        ChildStartWorker.new(args_for(scope, invoke_id, index, count),
          queue: @queue,
          meta: %{"child_starter" => Atom.to_string(starter)}
        )
      )

    job
  end

  defp args_for(scope, invoke_id, index, count, policy \\ :all) do
    {:ok, args} =
      JobArgs.from_invoke(scope, TestInvokeHandler, %Invoke{
        invoke_id: invoke_id,
        type: "myapp:signup",
        src: "per_item_chart",
        params: %{"item" => Enum.at(~w(a b c d), index)},
        content: nil,
        autoforward: false,
        state_index: 0,
        invoke_index: 0,
        macrostep: 1,
        microstep: 1,
        round: 1,
        caller_context: nil
      })

    JobArgs.for_child_start(args, index, count, policy)
  end

  defp insert_with_starter_name!(scope, invoke_id, name) do
    {:ok, job} =
      Oban.insert(
        @oban_name,
        ChildStartWorker.new(args_for(scope, invoke_id, 0, 1),
          queue: @queue,
          meta: %{"child_starter" => name}
        )
      )

    job
  end

  defp recorded_error(%Oban.Job{id: id}) do
    Oban.Job |> TestRepo.get!(id) |> Map.fetch!(:errors) |> inspect()
  end

  defp drain, do: Oban.drain_queue(@oban_name, queue: @queue)
end
