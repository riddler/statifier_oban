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
  end

  defmodule FailingRunHandler do
    @moduledoc false
    use StatifierOban.Invoke.Handler

    @impl StatifierOban.Invoke.Handler
    def config, do: StatifierOban.TestInvokeHandler.config()

    @impl StatifierOban.Invoke.Handler
    def run(%Invoke{}), do: {:error, :upstream_unreachable}
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
  test "an undecodable row cancels rather than retrying forever" do
    insert!(%{"bogus" => true})

    assert %{cancelled: 1, failure: 0, success: 0} = drain()
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

  # -- helpers ------------------------------------------------------------

  defp args_for(scope, invoke_id, handler) do
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
        round: 1
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
end
