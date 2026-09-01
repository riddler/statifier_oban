defmodule StatifierOban.Timer.Delivery.Session do
  @moduledoc """
  The default `StatifierOban.Timer.Delivery`: feeds a fired event back
  into a live `Statifier.Session`, behind the two-step liveness check
  statifier-ex's `docs/durable-timers.md` spells out.

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

  Delivery is `Statifier.Session.send_event/2` - the same door a fired
  in-process timer rejoins through - with the event built by
  `StatifierOban.Timer.Delivery.fired_event/2`, exactly as the session's
  own delivery path builds it: `origin`/`origintype` stamped as the scxml
  processor at the sending session's location, `sendid` only when the
  author wrote the id (C.1), `data` and `caller_context` carried through
  untouched. The `caller_context` hop is what stitches the firing back to
  the trace that armed the timer, hours or a restart later; the behaviour
  module's "Restoring the caller's trace context" section spells out why.
  `send_event/2` is a cast, so `:delivered` means enqueued onto the
  session's inbox, not processed.

  This module requires `Statifier.Supervisor` (which owns
  `Statifier.Registry`) to be running: `Registry.lookup/2` raises when it
  is not, and the job retries rather than discards - a missing registry
  is an environment fact about the host, not a liveness fact about the
  run. The scope must therefore be the session id the session registered
  under (`ctx.session_id`); a host using any other scope owes its own
  `StatifierOban.Timer.Delivery` implementation.
  """

  @behaviour StatifierOban.Timer.Delivery

  alias Statifier.Effect.SendDelayed
  alias StatifierOban.Timer.Delivery

  @impl StatifierOban.Timer.Delivery
  def deliver(scope, %SendDelayed{} = effect) when is_binary(scope) do
    case Registry.lookup(Statifier.Registry, scope) do
      [] -> {:discarded, :terminated}
      [{pid, _value}] -> deliver_if_running(pid, scope, effect)
    end
  end

  @spec deliver_if_running(pid(), String.t(), SendDelayed.t()) ::
          :delivered | {:discarded, StatifierOban.Timer.Delivery.discard_reason()}
  defp deliver_if_running(pid, scope, effect) do
    case Statifier.Session.status(pid) do
      %{status: :running} ->
        :ok = Statifier.Session.send_event(pid, Delivery.fired_event(scope, effect))
        :delivered

      %{status: halted} ->
        {:discarded, halted}
    end
  catch
    # Not a rescue-to-default: the session exiting between the registry
    # lookup and the status call is the same run fact step 1 reports, and
    # this boundary returns it as data instead of crashing the worker
    # into retrying a delivery spec 6.2 requires it to discard.
    :exit, _reason -> {:discarded, :terminated}
  end
end
