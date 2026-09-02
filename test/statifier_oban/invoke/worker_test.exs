defmodule StatifierOban.Invoke.WorkerTest do
  # Not async: shares the one SQLite repo and oban_jobs table (ADR-0002
  # harness) and the globally named Statifier.Supervisor.
  use ExUnit.Case, async: false

  alias Statifier.Effect.Invoke
  alias StatifierOban.Invoke.{Delivery, JobArgs, Worker}
  alias StatifierOban.{TestInvokeHandler, TestRepo}

  @oban_name StatifierOban.Invoke.WorkerTestOban
  @queue "invoke_worker_test"

  defmodule RecordingDelivery do
    @moduledoc false
    @behaviour Delivery

    @impl Delivery
    def deliver(scope, invoke_id, donedata) do
      send(:invoke_worker_test_listener, {:delivered_via_seam, scope, invoke_id, donedata})
      :delivered
    end

    @impl Delivery
    def deliver_failure(scope, invoke_id, failure) do
      send(:invoke_worker_test_listener, {:failed_via_seam, scope, invoke_id, failure})
      :delivered
    end
  end

  # The process-less host shape (sob-10x): builds the answer event itself
  # with `Statifier.Invoke.Answer`, so it needs the invocation's
  # caller_context off the job row. Defines both arities of both doors -
  # the three-argument clauses are the behaviour's, and the worker must
  # route past them to the four-argument ones.
  defmodule ContextRecordingDelivery do
    @moduledoc false
    @behaviour Delivery

    alias Statifier.Invoke.Answer

    @impl Delivery
    def deliver(scope, invoke_id, donedata), do: deliver(scope, invoke_id, donedata, [])

    @impl Delivery
    def deliver(scope, invoke_id, donedata, opts) do
      event =
        Answer.done(scope, invoke_id, donedata,
          caller_context: Keyword.get(opts, :caller_context)
        )

      send(:invoke_worker_test_listener, {:answer_event, :done, event, opts})
      :delivered
    end

    @impl Delivery
    def deliver_failure(scope, invoke_id, failure),
      do: deliver_failure(scope, invoke_id, failure, [])

    @impl Delivery
    def deliver_failure(scope, invoke_id, failure, opts) do
      event =
        Answer.failed(scope, invoke_id, failure,
          caller_context: Keyword.get(opts, :caller_context)
        )

      send(:invoke_worker_test_listener, {:answer_event, :failed, event, opts})
      :delivered
    end
  end

  # A host delivery module written before ADR-0005 added the second door.
  # Deliberately does not declare the behaviour - declaring it would make
  # the compiler, rather than the worker, be the thing under test.
  defmodule DoneOnlyDelivery do
    @moduledoc false
    def deliver(_scope, _invoke_id, _donedata), do: :delivered
  end

  defmodule FailingRunHandler do
    @moduledoc false
    use StatifierOban.Invoke.Handler

    @impl StatifierOban.Invoke.Handler
    def config, do: StatifierOban.TestInvokeHandler.config()

    @impl StatifierOban.Invoke.Handler
    def run(%Invoke{}), do: {:error, :upstream_unreachable}
  end

  defmodule RaisingRunHandler do
    @moduledoc false
    use StatifierOban.Invoke.Handler

    @impl StatifierOban.Invoke.Handler
    def config, do: StatifierOban.TestInvokeHandler.config()

    @impl StatifierOban.Invoke.Handler
    def run(%Invoke{}), do: raise(ArgumentError, "the payment gateway said no")
  end

  # The run-keyed handler shape sob-7b1 exists for: work that has to know
  # which run it is working for, written against the base as shipped.
  defmodule RunKeyedHandler do
    @moduledoc false
    use StatifierOban.Invoke.Handler

    @impl StatifierOban.Invoke.Handler
    def config, do: StatifierOban.TestInvokeHandler.config()

    @impl StatifierOban.Invoke.Handler
    def run(%Invoke{} = invoke, %{scope: scope}),
      do: {:ok, %{"result" => "authorized", "scope" => scope, "invoke_id" => invoke.invoke_id}}
  end

  # Both arities defined: the two-arity one is the more specific contract,
  # so it is the one the worker calls.
  defmodule BothAritiesHandler do
    @moduledoc false
    use StatifierOban.Invoke.Handler

    @impl StatifierOban.Invoke.Handler
    def config, do: StatifierOban.TestInvokeHandler.config()

    @impl StatifierOban.Invoke.Handler
    def run(%Invoke{}), do: {:ok, %{"arity" => 1}}

    @impl StatifierOban.Invoke.Handler
    def run(%Invoke{}, %{scope: _scope}), do: {:ok, %{"arity" => 2}}
  end

  setup do
    start_supervised!(Statifier.Supervisor)

    start_supervised!(
      {Oban, name: @oban_name, repo: TestRepo, engine: Oban.Engines.Lite, testing: :manual}
    )

    :ok
  end

  # sabotage: `perform/1` ignored the meta's delivery module and always
  # used the default - went red (the seam message never arrived, the job
  # cancelled on the dead default lookup instead), reverted.
  test "the meta's delivery module is the seam the completion goes through, donedata intact" do
    Process.register(self(), :invoke_worker_test_listener)

    insert!(args_for("sess_iw_seam", "inv_seam", TestInvokeHandler),
      meta: %{"delivery" => Atom.to_string(RecordingDelivery)}
    )

    assert %{success: 1, cancelled: 0, failure: 0} = drain()

    assert_received {:delivered_via_seam, "sess_iw_seam", "inv_seam", %{"result" => "authorized"}}
  end

  # -- the run context (sob-7b1) ------------------------------------------

  # sabotage: `call_run/3` built the context with the invoke_id in the
  # `:scope` key - went red (the donedata carried "inv_runctx" as its
  # scope), reverted.
  test "a run/2 handler is handed the job's scope, and its donedata is delivered" do
    Process.register(self(), :invoke_worker_test_listener)

    insert!(args_for("sess_iw_runctx", "inv_runctx", RunKeyedHandler),
      meta: %{"delivery" => Atom.to_string(RecordingDelivery)}
    )

    assert %{success: 1, cancelled: 0, failure: 0} = drain()

    assert_received {:delivered_via_seam, "sess_iw_runctx", "inv_runctx", donedata}
    assert donedata["scope"] == "sess_iw_runctx"
    assert donedata["invoke_id"] == "inv_runctx"
  end

  # sabotage: `call_run/3`'s arity test was flipped to prefer `run/1`
  # wherever it exists - went red (the donedata came back `%{"arity" =>
  # 1}`), reverted.
  test "a handler defining both arities runs through run/2" do
    Process.register(self(), :invoke_worker_test_listener)

    insert!(args_for("sess_iw_botharities", "inv_botharities", BothAritiesHandler),
      meta: %{"delivery" => Atom.to_string(RecordingDelivery)}
    )

    assert %{success: 1, cancelled: 0, failure: 0} = drain()

    assert_received {:delivered_via_seam, _scope, "inv_botharities", %{"arity" => 2}}
  end

  # sabotage: `run/2`'s {:error, reason} arm returned {:ok, reason} - went
  # red (the job completed and "delivered" the error as donedata),
  # reverted.
  test "a run returning {:error, reason} retries the job with the reason recorded" do
    insert!(args_for("sess_iw_fail", "inv_fail", FailingRunHandler))

    assert %{failure: 1, success: 0, cancelled: 0} = drain()

    assert [%Oban.Job{errors: [%{"error" => error} | _rest]}] =
             jobs("sess_iw_fail", "inv_fail")

    assert error =~ "run_failed"
    assert error =~ "upstream_unreachable"
  end

  # sabotage: `decode/1` returned {:error, reason} instead of
  # {:cancel, ...} - went red (failure: 1 rather than cancelled: 1),
  # reverted.
  # sabotage: the cancel reason was retagged {:corrupt_row, reason} - went
  # red on the error assertion below, reverted.
  test "an undecodable row cancels rather than retrying forever" do
    %Oban.Job{id: id} = insert!(%{"bogus" => true})

    assert %{cancelled: 1, failure: 0, success: 0} = drain()

    # The cancellation reason is the row fact, not a codec-shaped one:
    # the widened classification must not have swallowed this arm.
    assert %Oban.Job{state: "cancelled", errors: [%{"error" => error}]} =
             TestRepo.get!(Oban.Job, id)

    assert error =~ "undecodable"
  end

  # sabotage: `resolve_module/4` rescued into {:ok, module} - went red
  # (an UndefinedFunctionError crash instead of a clean failure),
  # reverted.
  test "a handler module this node does not know retries as an environment error" do
    args =
      "sess_iw_nohandler"
      |> args_for("inv_nohandler", TestInvokeHandler)
      |> Map.put("handler", "Elixir.StatifierOban.NoSuchHandler")

    insert!(args)

    assert %{failure: 1, success: 0, cancelled: 0} = drain()

    assert [%Oban.Job{errors: [%{"error" => error} | _rest]}] =
             jobs("sess_iw_nohandler", "inv_nohandler")

    assert error =~ "invalid_handler"
  end

  # sabotage: `delivery_module/1`'s binary arm skipped resolution and
  # returned the default - went red (the job completed through the
  # default seam instead of retrying), reverted.
  test "an unresolvable delivery module retries as an environment error" do
    insert!(args_for("sess_iw_nodelivery", "inv_nodelivery", TestInvokeHandler),
      meta: %{"delivery" => "Elixir.StatifierOban.NoSuchDelivery"}
    )

    assert %{failure: 1, success: 0, cancelled: 0} = drain()
  end

  # sabotage: decode/1's {:invalid_codec, ...} clause was dropped, letting
  # the catch-all cancel it - went red (cancelled: 1 instead of failure:
  # 1), reverted.
  test "a codec named on the row that this node cannot resolve retries, not cancels" do
    never_seen = "Elixir.StatifierOban.NeverCompiledCodec#{:erlang.unique_integer([:positive])}"
    insert_with_codec_tag("sess_iw_badcodec", "inv_badcodec", "params", never_seen)

    assert %{failure: 1, success: 0, cancelled: 0} = drain()

    assert [%Oban.Job{errors: [%{"error" => error} | _rest]}] =
             jobs("sess_iw_badcodec", "inv_badcodec")

    assert error =~ "invalid_codec"
  end

  # sabotage: decode/1's {:codec_failed, ...} clause was dropped, letting
  # the catch-all cancel it - went red (cancelled: 1 instead of failure:
  # 1), reverted.
  test "a codec that fails to decode the row retries, not cancels" do
    insert_with_codec_tag(
      "sess_iw_codecfail",
      "inv_codecfail",
      "params",
      "Elixir.StatifierOban.TestCodecs.Boom"
    )

    assert %{failure: 1, success: 0, cancelled: 0} = drain()

    assert [%Oban.Job{errors: [%{"error" => error} | _rest]}] =
             jobs("sess_iw_codecfail", "inv_codecfail")

    assert error =~ "codec_failed"
  end

  # sabotage: `Delivery.Session.deliver_if_running/3`'s halted arm
  # returned :delivered - went red ({:discarded, :done} stopped coming
  # back), reverted.
  test "the default delivery discards against a halted run, with the halt as the reason" do
    chart = """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="end_state">
        <final id="end_state"/>
    </scxml>
    """

    {:ok, machine} = Statifier.compile(chart)
    {:ok, session} = Statifier.Session.start_link(machine)
    scope = Statifier.Session.session_id(session)

    wait_until(fn -> Statifier.Session.status(session).status == :done end)

    assert {:discarded, :done} = Delivery.Session.deliver(scope, "inv_halted", nil)
  end

  # sabotage: `Delivery.Session.deliver/3`'s empty-lookup arm returned
  # :delivered - went red, reverted.
  test "the default delivery discards against a run that no longer exists" do
    assert {:discarded, :terminated} =
             Delivery.Session.deliver("sess_iw_never_lived", "inv_x", nil)
  end

  # -- permanent failure (ADR-0005, st-ADR-0068) ---------------------------

  # sabotage: `maybe_fail/6`'s guard was flipped to `attempt > max_attempts`
  # - went red (the terminal attempt delivered nothing), reverted.
  test "the terminal attempt reports the failure through the seam, classified and counted" do
    Process.register(self(), :invoke_worker_test_listener)

    insert!(args_for("sess_iw_exhausted", "inv_exhausted", FailingRunHandler),
      meta: %{"delivery" => Atom.to_string(RecordingDelivery)},
      max_attempts: 1
    )

    drain()

    assert_received {:failed_via_seam, "sess_iw_exhausted", "inv_exhausted", failure}
    assert failure[:reason] == "run_failed"
    assert failure[:attempts] == 1
    assert failure[:detail] =~ "upstream_unreachable"

    # The job outcome is untouched by the delivery: still a discard,
    # still carrying the run failure it always carried.
    assert [%Oban.Job{state: "discarded", errors: [%{"error" => error} | _rest]}] =
             jobs("sess_iw_exhausted", "inv_exhausted")

    assert error =~ "run_failed"
  end

  # sabotage: `maybe_fail/6`'s catch-all clause was made to deliver too -
  # went red (the retryable attempt told the run about a failure it would
  # retry), reverted.
  test "a failure with retries left tells the run nothing" do
    Process.register(self(), :invoke_worker_test_listener)

    insert!(args_for("sess_iw_retrying", "inv_retrying", FailingRunHandler),
      meta: %{"delivery" => Atom.to_string(RecordingDelivery)},
      max_attempts: 3
    )

    drain()

    assert [%Oban.Job{state: "retryable", attempt: 1}] = jobs("sess_iw_retrying", "inv_retrying")

    refute_received {:failed_via_seam, _scope, _invoke_id, _failure}
  end

  # sabotage: `run/5`'s rescue arm dropped the `maybe_fail/6` call and only
  # re-raised - went red (a crashing handler's exhaustion reached nobody),
  # reverted.
  test "a handler that raises on its last attempt reports run_crashed, and still discards" do
    Process.register(self(), :invoke_worker_test_listener)

    insert!(args_for("sess_iw_crashed", "inv_crashed", RaisingRunHandler),
      meta: %{"delivery" => Atom.to_string(RecordingDelivery)},
      max_attempts: 1
    )

    drain()

    assert_received {:failed_via_seam, "sess_iw_crashed", "inv_crashed", failure}
    assert failure[:reason] == "run_crashed"
    assert failure[:attempts] == 1
    assert failure[:detail] =~ "the payment gateway said no"

    # Re-raised, not swallowed: the exception still reaches the job row.
    assert [%Oban.Job{state: "discarded", errors: [%{"error" => error} | _rest]}] =
             jobs("sess_iw_crashed", "inv_crashed")

    assert error =~ "ArgumentError"
  end

  # sabotage: `resolve_module/3` checked only the first export in the list
  # - went red (the deliver/3-only module resolved instead of retrying),
  # reverted.
  test "a delivery module predating the failure door is unresolvable, not half-usable" do
    insert!(args_for("sess_iw_olddelivery", "inv_olddelivery", TestInvokeHandler),
      meta: %{"delivery" => Atom.to_string(DoneOnlyDelivery)}
    )

    assert %{failure: 1, success: 0, cancelled: 0} = drain()

    assert [%Oban.Job{errors: [%{"error" => error} | _rest]}] =
             jobs("sess_iw_olddelivery", "inv_olddelivery")

    assert error =~ "invalid_delivery"
  end

  # sabotage: `Delivery.Session.deliver_failure/3` was pointed at
  # `if_running/2`'s success path unconditionally - went red (a dead run
  # reported :delivered), reverted.
  test "the default delivery discards a failure against a run that no longer exists" do
    assert {:discarded, :terminated} =
             Delivery.Session.deliver_failure("sess_iw_never_lived", "inv_x",
               reason: "run_failed",
               attempts: 1,
               detail: "gone"
             )
  end

  # sabotage: `deliver_if_running/2`'s halted arm returned :delivered -
  # went red for the failure door exactly as it does for the done door,
  # reverted.
  test "the default delivery discards a failure against a halted run" do
    chart = """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="end_state">
        <final id="end_state"/>
    </scxml>
    """

    {:ok, machine} = Statifier.compile(chart)
    {:ok, session} = Statifier.Session.start_link(machine)
    scope = Statifier.Session.session_id(session)

    wait_until(fn -> Statifier.Session.status(session).status == :done end)

    assert {:discarded, :done} =
             Delivery.Session.deliver_failure(scope, "inv_halted", reason: "run_failed")
  end

  # sabotage: `perform/1`'s undecodable else-arm dropped the
  # `fail_undecodable/2` call and only returned the cancel - went red
  # (the seam message never arrived, mailbox empty), reverted.
  test "an undecodable payload reports through the seam before the row cancels" do
    Process.register(self(), :invoke_worker_test_listener)

    args =
      "sess_iw_undecodable"
      |> args_for("inv_undecodable", TestInvokeHandler)
      |> Map.put("params", %{"t2b64" => Base.encode64("not an external term")})

    %Oban.Job{id: id} =
      insert!(args,
        meta: %{"delivery" => Atom.to_string(RecordingDelivery)},
        max_attempts: 5
      )

    assert %{cancelled: 1, failure: 0, success: 0} = drain()

    assert_received {:failed_via_seam, "sess_iw_undecodable", "inv_undecodable", failure}
    assert failure[:reason] == "undecodable"
    assert failure[:detail] =~ "invalid_field"

    # The attempt that found the corrupt row is the terminal one, so
    # `:attempts` is that attempt and not the `max_attempts` of 5 this
    # job will never reach.
    assert failure[:attempts] == 1

    # The job outcome is untouched by the delivery: still the same
    # cancel, carrying the same row fact.
    assert %Oban.Job{state: "cancelled", errors: [%{"error" => error}]} =
             TestRepo.get!(Oban.Job, id)

    assert error =~ "undecodable"
  end

  # sabotage: `JobArgs.identity/1` returned `{:ok, Map.get(args, "scope"),
  # Map.get(args, "invoke_id")}` unconditionally instead of going through
  # `fetch_binary/2` - went red (the door was called with a nil scope),
  # reverted.
  test "a row whose identity fields are undecodable cancels with nobody to tell" do
    Process.register(self(), :invoke_worker_test_listener)

    args =
      "sess_iw_noidentity"
      |> args_for("inv_noidentity", TestInvokeHandler)
      |> Map.delete("scope")

    %Oban.Job{id: id} =
      insert!(args, meta: %{"delivery" => Atom.to_string(RecordingDelivery)})

    assert %{cancelled: 1, failure: 0, success: 0} = drain()

    # No scope means no run to name, so there is no door to call - and
    # reaching for one anyway would be a delivery to nowhere.
    refute_received {:failed_via_seam, _scope, _invoke_id, _failure}

    assert %Oban.Job{state: "cancelled", errors: [%{"error" => error}]} =
             TestRepo.get!(Oban.Job, id)

    assert error =~ "undecodable"
  end

  # -- helpers ------------------------------------------------------------

  defp args_for(scope, invoke_id, handler, caller_context \\ nil) do
    {:ok, args} =
      JobArgs.from_invoke(scope, handler, %Invoke{
        invoke_id: invoke_id,
        type: "myapp:authorize",
        src: nil,
        params: %{},
        content: nil,
        autoforward: false,
        state_index: 0,
        invoke_index: 0,
        macrostep: 1,
        microstep: 1,
        round: 1,
        caller_context: caller_context
      })

    args
  end

  defp insert!(args, opts \\ []) do
    {:ok, job} = Oban.insert(@oban_name, Worker.new(args, [queue: @queue] ++ opts))
    job
  end

  # Encodes plainly (no codec), then hand-tags one opaque field's payload
  # with `codec_name` - proving the worker reads whatever tag the stored
  # row carries, independent of how it got there.
  defp insert_with_codec_tag(scope, invoke_id, field, codec_name) do
    args = args_for(scope, invoke_id, TestInvokeHandler)
    payload = Map.put(Map.fetch!(args, field), "codec", codec_name)
    args = Map.put(args, field, payload)

    insert!(args)
  end

  defp drain do
    Oban.drain_queue(@oban_name, queue: @queue)
  end

  defp jobs(scope, invoke_id) do
    import Ecto.Query, only: [where: 3]

    worker = Oban.Worker.to_string(Worker)

    Oban.Job
    |> where([j], j.worker == ^worker)
    |> where([j], j.args["scope"] == ^scope and j.args["invoke_id"] == ^invoke_id)
    |> TestRepo.all()
  end

  defp wait_until(check, attempts \\ 200)
  defp wait_until(_check, 0), do: flunk("condition never became true")

  defp wait_until(check, attempts) do
    if check.() do
      :ok
    else
      Process.sleep(5)
      wait_until(check, attempts - 1)
    end
  end

  # -- caller_context across the round trip (st-ADR-0063, sob-10x) ---------

  @caller_context %{"traceparent" => "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"}

  # sabotage: `deliver_done/4`'s arity test was flipped to prefer
  # `deliver/3` wherever it exists - went red (the four-argument door was
  # never reached, so no {:answer_event, ...} message arrived at all),
  # reverted.
  test "the row's caller_context reaches deliver/4 and lands on the done event" do
    Process.register(self(), :invoke_worker_test_listener)

    insert!(args_for("sess_iw_cc", "inv_cc", TestInvokeHandler, @caller_context),
      meta: %{"delivery" => Atom.to_string(ContextRecordingDelivery)}
    )

    assert %{success: 1, cancelled: 0, failure: 0} = drain()

    assert_received {:answer_event, :done, event, opts}

    assert opts[:caller_context] == @caller_context
    assert event.name == "done.invoke.inv_cc"
    assert event.caller_context == @caller_context
  end

  # sabotage: `maybe_fail/7`'s `deliver_failure/5` call passed `nil`
  # instead of `invoke.caller_context` - went red (the failure event came
  # back with a nil slot while the done path still carried one),
  # reverted.
  test "a permanently failed invocation carries the same slot onto the error event" do
    Process.register(self(), :invoke_worker_test_listener)

    insert!(args_for("sess_iw_cc_fail", "inv_cc_fail", FailingRunHandler, @caller_context),
      meta: %{"delivery" => Atom.to_string(ContextRecordingDelivery)},
      max_attempts: 1
    )

    drain()

    assert_received {:answer_event, :failed, event, opts}

    assert opts[:caller_context] == @caller_context
    assert event.name == "error.communication.invoke.inv_cc_fail"
    assert event.caller_context == @caller_context
    assert event.data["reason"] == "run_failed"
  end

  # sabotage: `deliver_done/4` was changed to send a literal
  # `caller_context: %{}` rather than the effect's slot - went red (the
  # nil case came back as an empty map, which is a context attached, not
  # the absence of one), reverted.
  test "an invocation with no context attached delivers a nil slot, not a fabricated one" do
    Process.register(self(), :invoke_worker_test_listener)

    insert!(args_for("sess_iw_cc_nil", "inv_cc_nil", TestInvokeHandler),
      meta: %{"delivery" => Atom.to_string(ContextRecordingDelivery)}
    )

    assert %{success: 1} = drain()

    assert_received {:answer_event, :done, event, opts}

    assert opts[:caller_context] == nil
    assert event.caller_context == nil
  end

  # sabotage: `deliver_done/4`'s arity check was removed so it called
  # `delivery.deliver/4` unconditionally - went red (RecordingDelivery
  # defines only the three-argument doors, so the job failed rather than
  # succeeding). Reverted. This is the back-compatibility pin: an
  # implementation written against 0.5.0 must keep working untouched.
  test "a delivery defining only the three-argument doors is still called at that arity" do
    Process.register(self(), :invoke_worker_test_listener)

    insert!(args_for("sess_iw_cc_narrow", "inv_cc_narrow", TestInvokeHandler, @caller_context),
      meta: %{"delivery" => Atom.to_string(RecordingDelivery)}
    )

    assert %{success: 1, cancelled: 0, failure: 0} = drain()

    assert_received {:delivered_via_seam, "sess_iw_cc_narrow", "inv_cc_narrow", _donedata}
    refute_received {:answer_event, _kind, _event, _opts}
  end

  # Link-stitching parity with the timer path, at the event level. The ots
  # bridge is not a test dependency here, so what is pinned is the fact
  # the bridge consumes: the event an answered invocation feeds back
  # carries the same slot, in the same field, that a fired timer's event
  # does - which is what upstream puts on the macrostep telemetry the
  # answer drives, and what the bridge turns into a link.
  #
  # sabotage: `JobArgs.to_invoke/1` rebuilt the effect with
  # `caller_context: nil` - went red on the equality below (the invoke
  # half went unlinked while the timer half stayed linked), reverted.
  test "the answered invocation's event carries the slot the same way a fired timer's does" do
    Process.register(self(), :invoke_worker_test_listener)

    insert!(args_for("sess_iw_cc_parity", "inv_cc_parity", TestInvokeHandler, @caller_context),
      meta: %{"delivery" => Atom.to_string(ContextRecordingDelivery)}
    )

    assert %{success: 1} = drain()
    assert_received {:answer_event, :done, invoke_event, _opts}

    timer_event =
      StatifierOban.Timer.Delivery.fired_event("sess_iw_cc_parity", %Statifier.Effect.SendDelayed{
        event: "reminder",
        send_id: "s1",
        id_from_author?: true,
        delay_ms: 1,
        ordinal: 1,
        data: nil,
        macrostep: 1,
        microstep: 1,
        round: 1,
        caller_context: @caller_context
      })

    assert invoke_event.caller_context == timer_event.caller_context
    assert invoke_event.caller_context == @caller_context

    # Both are external events, so both reach the macrostep telemetry the
    # bridge reads; neither path smuggles the slot into the payload the
    # datamodel sees (st-ADR-0063 decision 2).
    assert invoke_event.type == :external and timer_event.type == :external
    refute is_map(invoke_event.data) and Map.has_key?(invoke_event.data, "caller_context")
  end
end
