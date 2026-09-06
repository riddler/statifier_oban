defmodule StatifierOban.Invoke.FanOutTest do
  # Not async: shares the one SQLite repo and oban_jobs table (ADR-0002
  # harness).
  use ExUnit.Case, async: false

  import Ecto.Query, only: [where: 3]

  alias Statifier.Effect.Invoke
  alias StatifierOban.Config
  alias StatifierOban.Invoke.{ChildStartWorker, Delivery, FanOut, JobArgs, Worker}
  alias StatifierOban.TestRepo

  @oban_name StatifierOban.Invoke.FanOutTestOban
  @queue "invoke_fan_out_test"
  @cap 5

  defmodule RecordingStarter do
    @moduledoc false
    @behaviour StatifierOban.Invoke.ChildStarter

    @impl StatifierOban.Invoke.ChildStarter
    def start_child(parent_run_id, invoke, index, count, opts) do
      send(
        :invoke_fan_out_listener,
        {:started, parent_run_id, invoke.invoke_id, index, count, opts}
      )

      :ok
    end
  end

  defmodule RecordingDelivery do
    @moduledoc false
    @behaviour Delivery

    @impl Delivery
    def deliver(_scope, invoke_id, donedata) do
      send(:invoke_fan_out_listener, {:delivered, invoke_id, donedata})
      :delivered
    end

    @impl Delivery
    def deliver_failure(scope, invoke_id, failure) do
      send(:invoke_fan_out_listener, {:failed, scope, invoke_id, failure})
      :delivered
    end
  end

  # The fan-out shape: `run/1` returns the list rather than an answer.
  # The list is read off `params` because that is where `sb-ADR-0009`
  # decision 3 puts the evaluated `items`, and the hint rides beside it.
  defmodule FanOutHandler do
    @moduledoc false
    use StatifierOban.Invoke.Handler

    alias StatifierOban.Invoke.FanOutTest

    @impl StatifierOban.Invoke.Handler
    def config, do: FanOutTest.config()

    @impl StatifierOban.Invoke.Handler
    def run(%Invoke{params: params}) do
      case Map.get(params, "max_concurrency") do
        nil -> {:fan_out, Map.fetch!(params, "items")}
        hint -> {:fan_out, Map.fetch!(params, "items"), max_concurrency: hint}
      end
    end
  end

  defmodule NoStarterHandler do
    @moduledoc false
    use StatifierOban.Invoke.Handler

    alias StatifierOban.Invoke.FanOutTest

    @impl StatifierOban.Invoke.Handler
    def config, do: FanOutTest.config(child_starter: nil)

    @impl StatifierOban.Invoke.Handler
    def run(%Invoke{params: params}), do: {:fan_out, Map.fetch!(params, "items")}
  end

  @doc false
  @spec config(keyword()) :: Config.t()
  def config(overrides \\ []) do
    opts =
      Keyword.merge(
        [
          oban: @oban_name,
          timers_queue: "timers_unused",
          invoke_queue: @queue,
          invoke_delivery: RecordingDelivery,
          child_starter: RecordingStarter,
          max_fan_out: @cap
        ],
        overrides
      )

    {:ok, config} = Config.new(opts)
    config
  end

  setup do
    start_supervised!(
      {Oban, name: @oban_name, repo: TestRepo, engine: Oban.Engines.Lite, testing: :manual}
    )

    Process.register(self(), :invoke_fan_out_listener)

    # The ADR-0002 harness shares one SQLite `oban_jobs` table across the
    # whole suite and runs no sandbox, so a test that deliberately leaves
    # start jobs `available` would be drained by the next test's
    # `drain/0`. This queue is this module's alone, so clearing it is a
    # clean slate without touching another module's rows.
    TestRepo.delete_all(where(Oban.Job, [j], j.queue == @queue))

    :ok
  end

  # -- the start jobs (ADR-0007 decisions 4 and 5) -------------------------

  # sabotage: `enqueue_all/5` enqueued `0..(count - 2)` - went red (two
  # start jobs, indices [0, 1]), reverted.
  test "three items enqueue exactly three start jobs, one per index" do
    insert_fan_out!("sess_fo_three", "inv_three", ["a", "b", "c"])

    assert %{success: 1, cancelled: 0, failure: 0} = drain()

    assert [0, 1, 2] == start_indices("sess_fo_three", "inv_three")
  end

  # sabotage: `for_child_start/3` wrote the count into `"index"` - went
  # red (every start job carried index 2, and the second insert
  # conflicted so only one row existed), reverted.
  test "every start job carries the invocation's fields and its own index and count" do
    insert_fan_out!("sess_fo_args", "inv_args", ["a", "b"])

    assert %{success: 1} = drain()

    assert [first, second] = start_jobs("sess_fo_args", "inv_args")

    assert first.args["scope"] == "sess_fo_args"
    assert first.args["invoke_id"] == "inv_args"
    assert first.args["macrostep"] == 1
    assert first.args["index"] == 0
    assert first.args["child_count"] == 2
    assert second.args["index"] == 1
    assert second.args["child_count"] == 2
    assert first.meta["child_starter"] == Atom.to_string(RecordingStarter)
  end

  # The fan-out job itself answers nothing: the invocation stays open
  # until the settlement side answers it once, on behalf of all N.
  #
  # sabotage: `run/5`'s two-tuple `{:fan_out, items}` arm was turned into
  # an ordinary `{:ok, items}` answer - went red (a `:delivered` message
  # arrived and the invocation was answered by its own scheduling),
  # reverted.
  test "a fan-out job completes without delivering done.invoke" do
    insert_fan_out!("sess_fo_silent", "inv_silent", ["a"])

    assert %{success: 1, cancelled: 0, failure: 0} = drain()

    refute_received {:delivered, _invoke_id, _donedata}
    refute_received {:failed, _scope, _invoke_id, _failure}
  end

  # Decision 4's whole point: a replayed fan-out starts only what is
  # missing. Running the scheduling twice must leave three rows, not six.
  #
  # sabotage: `ChildStartWorker`'s unique `keys` dropped `:index` - went
  # red (the first replayed insert conflicted with index 0's stored job
  # and only one start job existed at all), reverted.
  test "re-running the fan-out enqueues no second copy of an index" do
    args = args_for("sess_fo_replay", "inv_replay", FanOutHandler)

    assert :ok = FanOut.start(config(), args, invoke_for("inv_replay"), ["a", "b", "c"], [])
    assert :ok = FanOut.start(config(), args, invoke_for("inv_replay"), ["a", "b", "c"], [])

    assert [0, 1, 2] == start_indices("sess_fo_replay", "inv_replay")
  end

  # sabotage: dropping one component of `Worker`'s unique `keys` stays
  # green - identical args still collide on the other two - so the
  # mutation used was `period: 0`, which went red (the second insert was
  # a fresh job with no conflict), reverted.
  test "a duplicate fan-out job is deduped by the ADR-0003 triple" do
    args = args_for("sess_fo_dedup", "inv_dedup", FanOutHandler)

    {:ok, first} = Oban.insert(@oban_name, Worker.new(args, queue: @queue))
    {:ok, second} = Oban.insert(@oban_name, Worker.new(args, queue: @queue))

    assert second.id == first.id
    assert second.conflict?
  end

  # -- the cap (ADR-0007 decision 8, R31-9) --------------------------------

  # sabotage: `counted/2` compared `count >= cap` - went red (a fan-out
  # of exactly the cap was refused too), reverted.
  test "a fan-out at the cap starts its children" do
    insert_fan_out!("sess_fo_atcap", "inv_atcap", Enum.to_list(1..@cap))

    assert %{success: 1, cancelled: 0} = drain()

    assert @cap == length(start_jobs("sess_fo_atcap", "inv_atcap"))
  end

  # sabotage: `counted/2`'s over-cap guard was made unreachable
  # (`count > cap * 1000`) - went red (six start jobs existed and no
  # failure was delivered). Separately, dropping the `deliver_failure/5`
  # call from `Worker`'s refusal arm also went red (the job cancelled in
  # silence and the chart heard nothing). Both reverted.
  test "a fan-out over the cap starts nothing and fails the invocation with N and the cap" do
    insert_fan_out!("sess_fo_overcap", "inv_overcap", Enum.to_list(1..(@cap + 1)))

    assert %{success: 0, cancelled: 1, failure: 0} = drain()

    assert [] == start_jobs("sess_fo_overcap", "inv_overcap")

    assert_received {:failed, "sess_fo_overcap", "inv_overcap", failure}
    assert failure[:reason] == "fan_out_refused"
    assert failure[:detail] =~ "cap_exceeded"
    assert failure[:detail] =~ "count: #{@cap + 1}"
    assert failure[:detail] =~ "cap: #{@cap}"
  end

  # The refusal detail is counts and constants: the fanned-out list is
  # the host's data and an error event is not where it belongs.
  #
  # sabotage: `counted/2`'s `:invalid_items` refusal was given the items
  # themselves in the map - went red (the detail carried "not_a_list"),
  # reverted.
  test "a non-list fan-out is refused without putting the value on the error route" do
    assert {:refused, refusal} =
             FanOut.start(
               config(),
               args_for("s", "i", FanOutHandler),
               invoke_for("i"),
               "not_a_list",
               []
             )

    assert refusal == %{reason: :invalid_items}
  end

  # `sb-ADR-0009` decision 8: an empty `items` list is a successful
  # fan-out over nothing. Nothing is enqueued and the accumulated list -
  # which for N = 0 is the whole of it - comes back for the caller to
  # answer with.
  #
  # sabotage: `enqueue_all/6`'s zero clause was removed so the count fell
  # through to the insert loop - went red (`JobArgs.for_child_start/4`'s
  # `index < count` guard raised on index 0, a start job for an item that
  # does not exist), reverted.
  test "an empty fan-out succeeds over nothing rather than being refused" do
    assert {:empty, []} =
             FanOut.start(config(), args_for("s", "i", FanOutHandler), invoke_for("i"), [], [])
  end

  # The runtime half of the same ruling, end to end: the conformance case
  # for N = 0. The job succeeds rather than cancelling, no start job
  # exists for the invocation, and the chart hears `done.invoke` carrying
  # the empty list - the same door and the same shape the settlement side
  # answers through for N > 0, where the payload is the dense
  # index-ordered list of N answers.
  #
  # sabotage: `Worker`'s `{:empty, collected}` arm was dropped - went red
  # (the fan-out arm's `case` matched nothing and the job failed instead
  # of succeeding, so the chart heard nothing at all). Separately,
  # delivering `nil` instead of `collected` also went red (the chart was
  # answered with no list). Both reverted.
  test "an empty fan-out starts no children and answers the invocation with the empty list" do
    insert_fan_out!("sess_fo_empty", "inv_empty", [])

    assert %{success: 1, cancelled: 0, failure: 0} = drain()

    assert [] == start_jobs("sess_fo_empty", "inv_empty")

    assert_received {:delivered, "inv_empty", []}
    refute_received {:started, _parent, "inv_empty", _index, _count, _opts}
  end

  # -- max_concurrency: clamped, never honoured below the queue (R31-11) ---

  # ADR-0007's dated Note: all N start jobs are enqueued up front and the
  # queue's concurrency limit is the only bound, so a hint ABOVE that
  # limit is clamped by the queue itself, with no code here. What this
  # asserts is the "no code here" half: the hint changes nothing about
  # what is enqueued.
  #
  # sabotage: `check_max_concurrency/1` was made to return
  # `{:error, {:invalid_option, :max_concurrency, hint}}` for every
  # integer - went red (the job failed instead of enqueueing three
  # starts), reverted.
  test "a max_concurrency hint above the queue's limit is clamped by the queue, not by us" do
    insert_fan_out!("sess_fo_hi", "inv_hi", ["a", "b", "c"], max_concurrency: 99)

    assert %{success: 1, cancelled: 0} = drain()

    assert [0, 1, 2] == start_indices("sess_fo_hi", "inv_hi")
  end

  # The reversal of decision 1's `:74`: a hint BELOW the queue's limit is
  # not honoured. Under the batching the record described, a hint of 1
  # would have put one start job out and held the other two back; all
  # three go out.
  #
  # sabotage: `start/4` honoured the hint, passing
  # `min(count, opts[:max_concurrency])` to `enqueue_all/5` - went red
  # (one start job instead of three), reverted.
  test "a max_concurrency hint below the queue's limit is ignored, not honoured" do
    insert_fan_out!("sess_fo_lo", "inv_lo", ["a", "b", "c"], max_concurrency: 1)

    assert %{success: 1, cancelled: 0} = drain()

    assert [0, 1, 2] == start_indices("sess_fo_lo", "inv_lo")
  end

  # sabotage: `check_max_concurrency/1`'s catch-all clause returned `:ok`
  # - went red (the malformed hint was accepted and three starts went
  # out), reverted.
  test "a malformed max_concurrency hint is a scheduling error, not a silent default" do
    assert {:error, {:invalid_option, :max_concurrency, "four"}} =
             FanOut.start(config(), args_for("s", "i", FanOutHandler), invoke_for("i"), ["a"],
               max_concurrency: "four"
             )
  end

  # -- the seam is required (ADR-0007, C4) ---------------------------------

  # sabotage: `fetch/2`'s `nil` clause returned `{:ok, nil}` - went red
  # (the job succeeded, enqueueing start jobs whose meta named `nil` as
  # the starter), reverted.
  test "a fan-out on a config with no :child_starter is a retryable error, starting nothing" do
    insert_fan_out!("sess_fo_nostarter", "inv_nostarter", ["a"], [], NoStarterHandler)

    assert %{success: 0, cancelled: 0, failure: 1} = drain()

    assert [] == start_jobs("sess_fo_nostarter", "inv_nostarter")
  end

  # -- cancelling the unstarted (sb-ADR-0009 decision 6, R31-12) -----------

  # Both halves of the match are load-bearing: the state filter keeps an
  # invocation whose starts already ran out of the sweep, and the
  # invoke_id filter keeps a sibling invocation in the same run out of it.
  #
  # sabotage: `start_jobs/2` dropped the `state in CancellableStates`
  # clause - went red (the count came back 9 and the completed rows read
  # `cancelled`), reverted.
  test "cancelling unstarted starts sweeps one invocation and leaves the others alone" do
    insert_fan_out!("sess_fo_cancel", "inv_started", ["a", "b", "c"])
    assert %{success: 1} = drain()
    # The second drain runs the start jobs the first one enqueued.
    assert %{success: 3} = drain()

    insert_fan_out!("sess_fo_cancel", "inv_unstarted", ["a", "b", "c"])
    insert_fan_out!("sess_fo_cancel", "inv_untouched", ["a", "b", "c"])
    assert %{success: 2} = drain()

    assert {:ok, 3} = FanOut.cancel_unstarted(config(), "sess_fo_cancel", "inv_unstarted")

    assert ["cancelled", "cancelled", "cancelled"] == states("sess_fo_cancel", "inv_unstarted")
    assert ["completed", "completed", "completed"] == states("sess_fo_cancel", "inv_started")
    assert ["available", "available", "available"] == states("sess_fo_cancel", "inv_untouched")

    # An invocation whose starts all ran has nothing left to sweep.
    assert {:ok, 0} = FanOut.cancel_unstarted(config(), "sess_fo_cancel", "inv_started")
  end

  # Which states the sweep reaches, pinned the way
  # `StatifierOban.Invoke.CancellableStatesTest` pins the invoke cancel's:
  # by forcing rows into each state rather than racing a live queue, since
  # the question is only what the query matches.
  for state <- ~w(suspended scheduled available retryable) do
    # sabotage: `StatifierOban.CancellableStates`' `@intended` list was
    # narrowed to `~w(available)` - went red on the suspended, scheduled
    # and retryable rows (each survived the sweep), reverted.
    test "a #{state} start job is swept" do
      id = stored_start_job_id("sess_fo_states_#{unquote(state)}", "inv_states")
      force_state(id, unquote(state))

      assert {:ok, 1} =
               FanOut.cancel_unstarted(config(), "sess_fo_states_#{unquote(state)}", "inv_states")

      assert %Oban.Job{state: "cancelled"} = TestRepo.get!(Oban.Job, id)
    end
  end

  # A cancel that arrives while a start job is running must not kill it:
  # the child may be half-created, and from the query's side that job is
  # indistinguishable from any other `executing` row (sob-uon, sob-84c).
  #
  # sabotage: `start_jobs/2` dropped the `state in CancellableStates`
  # clause - went red (the executing row came back "cancelled", because
  # `Oban.cancel_all_jobs/2`'s own filter excludes only terminal states),
  # reverted.
  test "an executing start job is not swept: its child may already be half-created" do
    id = stored_start_job_id("sess_fo_states_exec", "inv_states")
    force_state(id, "executing")

    assert {:ok, 0} = FanOut.cancel_unstarted(config(), "sess_fo_states_exec", "inv_states")

    assert %Oban.Job{state: "executing"} = TestRepo.get!(Oban.Job, id)
  end

  # -- the seam is reached with the index and the count --------------------

  # sabotage: `ChildStartWorker.start/6` passed `count` where `index`
  # goes - went red (the recorded indices came back [3, 3, 3]), reverted.
  test "each start job calls the seam with the parent run, the effect, its index and the count" do
    insert_fan_out!("sess_fo_seam", "inv_seam", ["a", "b", "c"])
    assert %{success: 1} = drain()
    assert %{success: 3} = drain()

    for index <- 0..2 do
      assert_received {:started, "sess_fo_seam", "inv_seam", ^index, 3, _opts}
    end
  end

  # -- the aggregation policy reaches the seam (RQ-031-4, sob-64p) --------

  # An invocation that says nothing about failure is `:all`, and that is
  # what every one of its children is started with.
  #
  # sabotage: `policy/1`'s `nil` clause returned
  # `{:ok, :first_error}` - went red (all three children were started
  # under the wrong aggregation), reverted.
  test "an invocation with no on parameter starts every child with policy: :all" do
    insert_fan_out!("sess_fo_pol_all", "inv_pol_all", ["a", "b", "c"])
    assert %{success: 1} = drain()
    assert %{success: 3} = drain()

    for index <- 0..2 do
      assert_received {:started, "sess_fo_pol_all", "inv_pol_all", ^index, 3, [policy: :all]}
    end
  end

  # The case a four-value seam could not express at all: `first_error`
  # has to reach the starter at EVERY index, because the settlement side
  # records it on each child's own linkage.
  #
  # sabotage: `enqueue_all/6` passed a literal `:all` to
  # `for_child_start/4` instead of the derived policy - went red (every
  # child was started `[policy: :all]`), reverted.
  test "an on of first_error starts every child with policy: :first_error" do
    insert_fan_out!("sess_fo_pol_fe", "inv_pol_fe", ["a", "b", "c"], on: "first_error")
    assert %{success: 1} = drain()
    assert %{success: 3} = drain()

    for index <- 0..2 do
      assert_received {:started, "sess_fo_pol_fe", "inv_pol_fe", ^index, 3,
                       [policy: :first_error]}
    end
  end

  # `"all"` written out explicitly is the same fan-out as no `on` at all.
  #
  # sabotage: `policy/1`'s `"all"` clause was removed, so the word fell
  # to the catch-all - went red (the fan-out was refused
  # `:invalid_policy` and started nothing), reverted.
  test "an on of all is the same as no on at all" do
    insert_fan_out!("sess_fo_pol_word", "inv_pol_word", ["a"], on: "all")
    assert %{success: 1} = drain()
    assert %{success: 1} = drain()

    assert_received {:started, "sess_fo_pol_word", "inv_pol_word", 0, 1, [policy: :all]}
  end

  # Reading an unrecognised word as `:all` would run a chart that asked
  # for one aggregation under the other, so it is refused before the
  # first child start, like the cap.
  #
  # sabotage: `policy/1`'s catch-all clause returned `{:ok, :all}` - went
  # red (a start job went out and no failure was delivered), reverted.
  test "an on that is neither word refuses the fan-out and starts nothing" do
    insert_fan_out!("sess_fo_pol_bad", "inv_pol_bad", ["a", "b"], on: "any_error")

    assert %{success: 0, cancelled: 1, failure: 0} = drain()

    assert [] == start_jobs("sess_fo_pol_bad", "inv_pol_bad")

    assert_received {:failed, "sess_fo_pol_bad", "inv_pol_bad", failure}
    assert failure[:reason] == "fan_out_refused"
    assert failure[:detail] =~ "invalid_policy"
  end

  # -- helpers -------------------------------------------------------------

  defp insert_fan_out!(scope, invoke_id, items, opts \\ [], handler \\ FanOutHandler) do
    params =
      %{"items" => items}
      |> maybe_put("max_concurrency", Keyword.get(opts, :max_concurrency))
      |> maybe_put("on", Keyword.get(opts, :on))

    {:ok, job} =
      Oban.insert(
        @oban_name,
        Worker.new(args_for(scope, invoke_id, handler, params),
          queue: @queue,
          meta: %{"delivery" => Atom.to_string(RecordingDelivery)}
        )
      )

    job
  end

  defp args_for(scope, invoke_id, handler, params \\ %{}) do
    {:ok, args} =
      JobArgs.from_invoke(scope, handler, %Invoke{
        invoke_id: invoke_id,
        type: "myapp:signup",
        src: "per_item_chart",
        params: params,
        content: nil,
        autoforward: false,
        state_index: 0,
        invoke_index: 0,
        macrostep: 1,
        microstep: 1,
        round: 1,
        caller_context: nil
      })

    args
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)

  # The effect `FanOut.start/5` reads the `on` parameter off, for the
  # tests that call it directly rather than through a drained job.
  defp invoke_for(invoke_id, params \\ %{}) do
    %Invoke{
      invoke_id: invoke_id,
      type: "myapp:signup",
      src: "per_item_chart",
      params: params,
      content: nil,
      autoforward: false,
      state_index: 0,
      invoke_index: 0,
      macrostep: 1,
      microstep: 1,
      round: 1,
      caller_context: nil
    }
  end

  defp drain, do: Oban.drain_queue(@oban_name, queue: @queue)

  defp start_jobs(scope, invoke_id) do
    worker = Oban.Worker.to_string(ChildStartWorker)

    Oban.Job
    |> where([j], j.worker == ^worker)
    |> where([j], j.args["scope"] == ^scope and j.args["invoke_id"] == ^invoke_id)
    |> TestRepo.all()
    |> Enum.sort_by(& &1.args["index"])
  end

  defp start_indices(scope, invoke_id) do
    scope |> start_jobs(invoke_id) |> Enum.map(& &1.args["index"])
  end

  defp stored_start_job_id(scope, invoke_id) do
    args = JobArgs.for_child_start(args_for(scope, invoke_id, FanOutHandler), 0, 1, :all)

    {:ok, job} =
      Oban.insert(
        @oban_name,
        ChildStartWorker.new(args,
          queue: @queue,
          meta: %{"child_starter" => Atom.to_string(RecordingStarter)}
        )
      )

    job.id
  end

  defp force_state(id, state) do
    Oban.Job
    |> where([j], j.id == ^id)
    |> TestRepo.update_all(set: [state: state])
  end

  defp states(scope, invoke_id) do
    scope |> start_jobs(invoke_id) |> Enum.map(& &1.state)
  end
end
