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

  The seam has two doors, not one. `c:deliver/3` carries a completed
  invocation back as `done.invoke.<invoke_id>`; `c:deliver_failure/3`
  carries a **permanently failed** one back as
  `error.communication.invoke.<invoke_id>` (st-ADR-0068), which is what
  a chart parking failed work for operator recovery transitions on.
  Both run the same run-liveness check first, because a durable job
  outlives the run it was started for either way.

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

  @typedoc """
  What a permanently failed invocation reports about itself.

  The keys are st-ADR-0068's: `:reason` is the failure class as a
  string, `:attempts` the attempt number the invocation gave up on, and
  `:detail` a human-readable elaboration. statifier-ex interprets none
  of them - it copies them into the error event's `data` map - so the
  vocabulary is this package's, and `StatifierOban.Invoke.Worker`
  documents the classes it emits.

  `:detail` is a **string**, deliberately, where st-ADR-0068 would
  allow any term: the value travels into chart data, where a raw term
  carrying pids or refs is a serialization hazard for any host
  persisting a run, and a string is what an expression can usefully
  read.
  """
  @type failure :: [reason: String.t(), attempts: pos_integer(), detail: String.t()]

  @doc """
  Establishes that the run named by `scope` is still live and, only
  then, reports the invocation named `invoke_id` **permanently failed**.

  Called when the invocation's retries are exhausted, never for a
  transient failure: a retry that will be tried again is not a fact the
  chart should hear about, which is why `run/1` returning
  `{:error, reason}` on a non-terminal attempt reaches nobody.

  The return values, the meaning of "live", and the raise-rather-than-
  return rule are `c:deliver/3`'s exactly. A `{:discarded, reason}` here
  is the ordinary case where the run died before its invocation gave up;
  the job is discarded either way, so the caller records the outcome and
  does not retry on it.

  The default implementation delivers through
  `Statifier.Session.failed_invocation/3` (st-ADR-0068), which is a
  no-op for an invocation the session already popped - the same property
  that makes `c:deliver/3` safe to redeliver.
  """
  @callback deliver_failure(scope :: String.t(), invoke_id :: String.t(), failure :: failure()) ::
              :delivered | {:discarded, discard_reason()}
end
