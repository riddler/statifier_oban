defmodule StatifierOban.Invoke.Delivery.Session do
  @moduledoc """
  The default `StatifierOban.Invoke.Delivery`: reports a completed
  invoke back into a live `Statifier.Session` through
  `Statifier.Session.done_invocation/3`, and a permanently failed one
  through `Statifier.Session.failed_invocation/3`, both behind the same
  two-step liveness check `StatifierOban.Timer.Delivery.Session` runs
  for a fired timer.

  The two steps run in order because `Statifier.Session.status/1` is a
  `GenServer.call` that exits the caller against a dead process - it
  cannot itself answer "terminated?":

  1. **Terminated?** `Registry.lookup/2` against `Statifier.Registry`
     under the scope (st-ADR-0027 decision 2: sessions register under
     their session id). Empty means discard: the session no longer
     exists, or never registered, and `status/1` is not safe to call.
  2. **Halted?** With a live process confirmed, `status/1`. Anything but
     `:running` discards too - "live" is stricter than "not terminated":
     a `:done` session keeps its process but declines to drain, so an
     event fed to it would sit queued forever, not be processed and not
     be discarded. The process exiting between the two steps is caught
     and reported as the same `:terminated` fact step 1 answers.

  Delivery is `Statifier.Session.done_invocation/3` - the door st-ADR-0051
  decision 5 gives a handler-backed invocation's host. The session builds
  `done.invoke.<invoke_id>` from `donedata` itself, stamps `invokeid`, and
  runs `<finalize>` off the arriving event; an invocation the session
  already popped (a prior cancel, or a redelivered completion) is a
  harmless no-op there, which is what makes this deliverable at least
  once. `done_invocation/3` is a cast, so `:delivered` means enqueued
  onto the session's inbox, not processed.

  Failure delivery is `Statifier.Session.failed_invocation/3`, the door
  st-ADR-0068 adds beside it, and everything above holds unchanged: the
  session builds `error.communication.invoke.<invoke_id>` from the
  keyword list itself, stamps the same `invokeid`/`origin`/`origintype`,
  pops the same invocation, and casts. Reusing one liveness check for
  both doors is deliberate rather than incidental - st-ADR-0068 makes
  the failure event travel `done_invocation/3`'s own delivery path
  upstream, so a check that diverged here would be this package
  contradicting the contract it implements.

  ## Why only the three-argument doors

  This module implements `c:StatifierOban.Invoke.Delivery.deliver/3` and
  `c:StatifierOban.Invoke.Delivery.deliver_failure/3`, and deliberately
  not their four-argument forms. Those exist to hand a delivery the
  invocation's `caller_context` off the job row, for a host that builds
  the answer event itself. This one builds nothing: `done_invocation/3`
  and `failed_invocation/3` construct the event inside the session and
  inherit the slot from the session's own invocation table (st-ADR-0063).
  Accepting the row's copy here would mean either ignoring it - a door
  that lies about what it does with its argument - or contradicting the
  session's own record of the invocation. A process-less host is the one
  with no such table, and `StatifierOban.Invoke.Delivery` documents the
  wider arities for it.

  This module requires `Statifier.Supervisor` (which owns
  `Statifier.Registry`) to be running: `Registry.lookup/2` raises when it
  is not, and the job retries rather than discards - a missing registry
  is an environment fact about the host, not a liveness fact about the
  run. The scope must therefore be the session id the session registered
  under (`ctx.session_id`); a host using any other scope owes its own
  `StatifierOban.Invoke.Delivery` implementation.
  """

  @behaviour StatifierOban.Invoke.Delivery

  alias StatifierOban.Invoke.Delivery

  @impl Delivery
  def deliver(scope, invoke_id, donedata) when is_binary(scope) and is_binary(invoke_id) do
    if_running(scope, &Statifier.Session.done_invocation(&1, invoke_id, donedata))
  end

  @impl Delivery
  def deliver_failure(scope, invoke_id, failure)
      when is_binary(scope) and is_binary(invoke_id) and is_list(failure) do
    if_running(scope, &Statifier.Session.failed_invocation(&1, invoke_id, failure))
  end

  @spec if_running(String.t(), (pid() -> :ok)) ::
          :delivered | {:discarded, Delivery.discard_reason()}
  defp if_running(scope, deliver) do
    case Registry.lookup(Statifier.Registry, scope) do
      [] -> {:discarded, :terminated}
      [{pid, _value}] -> deliver_if_running(pid, deliver)
    end
  end

  @spec deliver_if_running(pid(), (pid() -> :ok)) ::
          :delivered | {:discarded, Delivery.discard_reason()}
  defp deliver_if_running(pid, deliver) do
    case Statifier.Session.status(pid) do
      %{status: :running} ->
        :ok = deliver.(pid)
        :delivered

      %{status: halted} ->
        {:discarded, halted}
    end
  catch
    # Not a rescue-to-default: the session exiting between the registry
    # lookup and the status call is the same run fact step 1 reports, and
    # this boundary returns it as data instead of crashing the worker
    # into retrying a delivery the run's death requires it to discard.
    :exit, _reason -> {:discarded, :terminated}
  end
end
