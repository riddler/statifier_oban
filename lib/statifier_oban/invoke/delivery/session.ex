defmodule StatifierOban.Invoke.Delivery.Session do
  @moduledoc """
  The default `StatifierOban.Invoke.Delivery`: reports a completed invoke
  back into a live `Statifier.Session` through
  `Statifier.Session.done_invocation/3`, behind the same two-step
  liveness check `StatifierOban.Timer.Delivery.Session` runs for a fired
  timer.

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

  This module requires `Statifier.Supervisor` (which owns
  `Statifier.Registry`) to be running: `Registry.lookup/2` raises when it
  is not, and the job retries rather than discards - a missing registry
  is an environment fact about the host, not a liveness fact about the
  run. The scope must therefore be the session id the session registered
  under (`ctx.session_id`); a host using any other scope owes its own
  `StatifierOban.Invoke.Delivery` implementation.
  """

  @behaviour StatifierOban.Invoke.Delivery

  @impl StatifierOban.Invoke.Delivery
  def deliver(scope, invoke_id, donedata) when is_binary(scope) and is_binary(invoke_id) do
    case Registry.lookup(Statifier.Registry, scope) do
      [] -> {:discarded, :terminated}
      [{pid, _value}] -> deliver_if_running(pid, invoke_id, donedata)
    end
  end

  @spec deliver_if_running(pid(), String.t(), term()) ::
          :delivered | {:discarded, StatifierOban.Invoke.Delivery.discard_reason()}
  defp deliver_if_running(pid, invoke_id, donedata) do
    case Statifier.Session.status(pid) do
      %{status: :running} ->
        :ok = Statifier.Session.done_invocation(pid, invoke_id, donedata)
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
