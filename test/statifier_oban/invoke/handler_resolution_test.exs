defmodule StatifierOban.Invoke.HandlerResolutionTest do
  # Where a *second* invoke's handler comes from, when the first one's
  # answer transitions the run into another invoking state.
  #
  # The reported shape (sob-8pu): a host passing handlers "per delivery"
  # got `error.execution` on every second step. This module pins the
  # actual resolution source, because the package's own moduledocs did
  # not say it out loud: nothing on the delivery seam, and nothing on the
  # job row, chooses a handler for an `<invoke>` that has not been
  # planned yet. The choice is made once per drive, by the engine, out of
  # the run's own `:invoke_handlers` registry (st-ADR-0051 decision 4,
  # `Statifier.Session.Effects.plan/2`). What this package's job row
  # carries is the module that lookup *already* returned.
  #
  # The two tests differ in exactly one variable - what the run's
  # registry holds - and the delivery module is the same host-supplied
  # one in both, which is what refutes "the delivery resolves handlers".
  #
  # Not async: shares the one SQLite repo and oban_jobs table (ADR-0002
  # harness) and the globally named Statifier.Supervisor.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [where: 3]

  alias Statifier.Effect.Invoke
  alias StatifierOban.{Config, TestRepo}
  alias StatifierOban.Invoke.Worker

  @oban_name StatifierOban.ResolutionOban
  @queue "resolution_test"

  @signup_type "myapp:signup"
  @capture_type "myapp:capture"

  # Two invokes, back to back: `signing_up`'s answer is what enters
  # `capturing`, and `capturing` invokes again on entry. The second
  # `<invoke>` is therefore planned by a drive that the *first* one's
  # delivery caused - the reported shape.
  #
  # `error.execution` is what an unregistered type raises at plan time
  # (`Statifier.Session.Effects.plan_invoke/3`), so parking on it makes
  # the failure observable as a resting configuration rather than as a
  # missing job.
  @chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="signing_up">
      <state id="signing_up">
          <invoke id="inv_signup" type="myapp:signup"/>
          <transition event="done.invoke.inv_signup" target="capturing"/>
      </state>
      <state id="capturing">
          <invoke id="inv_capture" type="myapp:capture"/>
          <transition event="done.invoke.inv_capture" target="active"/>
          <transition event="error.execution" target="misconfigured"/>
      </state>
      <state id="active"/>
      <state id="misconfigured"/>
  </scxml>
  """

  defmodule HostDelivery do
    @moduledoc """
    A host-supplied delivery seam, standing in for the process-less
    host's own (`StatifierExamples.Charts.AsyncCalls.Delivery` is the
    real one). It delegates the liveness check so the test runs against
    a session, and it exists to make the point structurally: the
    behaviour has two doors, both about *this* completed invocation, and
    neither of them is handed - or could be handed - a handler map for
    the invocations a run has not planned yet.
    """

    @behaviour StatifierOban.Invoke.Delivery

    alias StatifierOban.Invoke.Delivery.Session, as: SessionDelivery

    @impl StatifierOban.Invoke.Delivery
    def deliver(scope, invoke_id, donedata),
      do: SessionDelivery.deliver(scope, invoke_id, donedata)

    @impl StatifierOban.Invoke.Delivery
    def deliver_failure(scope, invoke_id, failure),
      do: SessionDelivery.deliver_failure(scope, invoke_id, failure)
  end

  defmodule SignupHandler do
    @moduledoc false
    use StatifierOban.Invoke.Handler

    alias StatifierOban.Invoke.HandlerResolutionTest, as: Suite

    @impl StatifierOban.Invoke.Handler
    def config, do: Suite.config()

    @impl StatifierOban.Invoke.Handler
    def run(%Invoke{}), do: {:ok, %{"account_id" => "acct_1"}}
  end

  defmodule CaptureHandler do
    @moduledoc false
    use StatifierOban.Invoke.Handler

    alias StatifierOban.Invoke.HandlerResolutionTest, as: Suite

    @impl StatifierOban.Invoke.Handler
    def config, do: Suite.config()

    @impl StatifierOban.Invoke.Handler
    def run(%Invoke{}), do: {:ok, %{"capture_id" => "cap_1"}}
  end

  @spec config() :: Config.t()
  def config do
    {:ok, config} =
      Config.new(
        oban: @oban_name,
        timers_queue: "timers_unused",
        invoke_queue: @queue,
        invoke_delivery: HostDelivery
      )

    config
  end

  setup do
    start_supervised!(Statifier.Supervisor)

    start_supervised!(
      {Oban, name: @oban_name, repo: TestRepo, engine: Oban.Engines.Lite, testing: :manual}
    )

    :ok
  end

  # sabotage: `JobArgs.from_invoke/4`'s `"handler"` field was pinned to a
  # fixed module instead of the one it is handed - went red here (the
  # signup job's row named the pinned module, not `SignupHandler`),
  # reverted. That is the `lib/` behaviour this test owns: recording the
  # module the engine's lookup already chose.
  test "the second invoke's handler is resolved from the run's registry and written onto its job row" do
    {:ok, session} =
      Statifier.Session.start_link(machine(),
        invoke_handlers: %{@signup_type => SignupHandler, @capture_type => CaptureHandler}
      )

    scope = Statifier.Session.session_id(session)

    # First step: the engine's plan-time lookup already chose the module,
    # and the job row records that choice as a string.
    wait_until(fn -> match?([_job], stored_jobs(scope, "inv_signup")) end)

    assert [%Oban.Job{args: %{"handler" => signup_handler}, meta: %{"delivery" => delivery}}] =
             stored_jobs(scope, "inv_signup")

    assert signup_handler == Atom.to_string(SignupHandler)
    assert delivery == Atom.to_string(HostDelivery)

    # Running it delivers `done.invoke.inv_signup` through the
    # host-supplied seam, which drives the run into `capturing` - and
    # that drive is what plans the second `<invoke>`.
    drain()
    assert [%Oban.Job{state: "completed"}] = stored_jobs(scope, "inv_signup")

    wait_until(fn -> match?([_job], stored_jobs(scope, "inv_capture")) end)

    # The headline: the second job names the *second* handler. Nothing on
    # the delivery seam said so - `HostDelivery` is identical in both
    # steps and holds no map - and nothing on the first job's row said so
    # either. The registry the run was started with did.
    assert [%Oban.Job{args: %{"handler" => capture_handler}, meta: %{"delivery" => ^delivery}}] =
             stored_jobs(scope, "inv_capture")

    assert capture_handler == Atom.to_string(CaptureHandler)

    drain()

    wait_until(fn ->
      Statifier.Session.status(session).configuration == MapSet.new(["active"])
    end)
  end

  # sabotage: this test asserts no `lib/` behaviour of its own - it
  # asserts an *absence* on this package's side (no second job) and an
  # upstream plan-time refusal - so the mutation is the one variable it
  # controls: the registry below was widened to the passing test's, and
  # it went red for the right reason (the run reached `active`, never
  # `misconfigured`), then reverted. Nothing in `lib/` can turn it red,
  # which is itself the finding: the failure is upstream of this package.
  test "a run whose registry lacks the second type gets error.execution on the second step, through the same delivery" do
    {:ok, session} =
      Statifier.Session.start_link(machine(),
        invoke_handlers: %{@signup_type => SignupHandler}
      )

    scope = Statifier.Session.session_id(session)

    wait_until(fn -> match?([_job], stored_jobs(scope, "inv_signup")) end)
    drain()
    assert [%Oban.Job{state: "completed"}] = stored_jobs(scope, "inv_signup")

    # The reported symptom, reproduced: the first step is fine, the
    # answer arrives, and the second `<invoke>` raises `error.execution`
    # at plan time because its type is unregistered in *this* run's
    # registry. `HostDelivery` is byte-identical to the passing test's,
    # which is what places the fault in the registry rather than in the
    # seam.
    wait_until(fn ->
      Statifier.Session.status(session).configuration == MapSet.new(["misconfigured"])
    end)

    # No second job was ever inserted: the failure is upstream of this
    # package entirely - the handler was never chosen, so there was
    # nothing for `perform/2` to enqueue.
    assert [] = stored_jobs(scope, "inv_capture")
  end

  # -- helpers ------------------------------------------------------------

  defp machine do
    {:ok, machine} = Statifier.compile(@chart)
    machine
  end

  defp drain, do: Oban.drain_queue(@oban_name, queue: @queue)

  defp stored_jobs(scope, invoke_id) do
    worker = Oban.Worker.to_string(Worker)

    Oban.Job
    |> where([j], j.worker == ^worker)
    |> where([j], j.args["scope"] == ^scope and j.args["invoke_id"] == ^invoke_id)
    |> TestRepo.all()
  end

  defp wait_until(check, attempts \\ 200)

  defp wait_until(check, 0) do
    flunk("condition never became true: #{inspect(check)}")
  end

  defp wait_until(check, attempts) do
    if check.() do
      :ok
    else
      Process.sleep(25)
      wait_until(check, attempts - 1)
    end
  end
end
