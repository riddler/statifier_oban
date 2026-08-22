defmodule StatifierOban.Invoke.Delivery do
  @moduledoc """
  The delivery seam a completed invoke goes through - the run-liveness
  check at the `done.invoke` door, the same shape
  `StatifierOban.Timer.Delivery` gives a fired timer.

  When an invoke-handler job (`StatifierOban.Invoke.Worker`) finishes its
  work, the result has to travel back into the run as
  `done.invoke.<invoke_id>` with `donedata`. A durable job survives the
  run it was started for, so before feeding anything back the host MUST
  establish the run is still live and discard otherwise - a completed
  invoke against a dead or halted run is discarded exactly the way a
  fired timer is. The guarantee is enforced here, at delivery time.

  Whether a run is live is the host's question, not this package's: a
  host running `Statifier.Session` processes answers it from the session
  registry and delivers through `Statifier.Session.done_invocation/3`
  (`StatifierOban.Invoke.Delivery.Session`, the default), while a
  process-less host driving `Statifier.Interpreter` against persisted
  positions answers it from its own run store and feeds the completion
  into its next drive. That is why this is a behaviour:
  `StatifierOban.Config` carries the implementation (`:invoke_delivery`),
  and the enqueued job carries it to the worker.

  Implementations must be idempotent under redelivery: jobs in this
  package are at-least-once, so `c:deliver/3` can run more than once for
  the same completed invoke. The default implementation gets that from
  `Statifier.Session.done_invocation/3` itself, which documents a second
  call for the same `invoke_id` as a harmless no-op.
  """

  @typedoc """
  Why the completion was not fed back.

  The default Session delivery reports `:terminated` (no live process) or
  the halted session's own status (`:done`, `:cancelled`,
  `:budget_exhausted`); a host implementation reports whatever its run
  store calls the not-live case.
  """
  @type discard_reason :: term()

  @doc """
  Establishes that the run named by `scope` is still live and, only then,
  reports the invocation named `invoke_id` complete with `donedata`.

  Returns `:delivered` when the completion was fed back, or
  `{:discarded, reason}` when the run is not live and the completion was
  dropped. "Live" is stricter than "not terminated": a halted run
  (`:done` and friends) still discards, because an event fed to a halted
  session just sits queued.

  A failure that is neither of those - the host's run store unreachable,
  for example - should raise (or exit) rather than return: the job is
  retried by Oban, which is the correct response to an environment fact,
  where a discard is the correct response to a run fact.
  """
  @callback deliver(scope :: String.t(), invoke_id :: String.t(), donedata :: term()) ::
              :delivered | {:discarded, discard_reason()}
end
