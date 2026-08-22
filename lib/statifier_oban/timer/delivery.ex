defmodule StatifierOban.Timer.Delivery do
  @moduledoc """
  The delivery seam a fired timer job goes through - the run-liveness
  check st-ADR-0054 decision 4 requires, plus the feed-back itself.

  Spec 6.2 says a delayed send whose session terminated before the delay
  elapsed MUST be discarded without delivery. Inside statifier-ex,
  `Statifier.Session.terminate/2` satisfies that by cancelling every live
  timer ref before the process exits; a durable scheduler survives process
  death by design, so nothing plays that role for a stored job. What
  replaces it (st-ADR-0054 decision 4): before feeding the fired event
  back, the host MUST establish the run is still live and discard
  otherwise. The guarantee is enforced here, at delivery time - a
  cancel-on-run-end hook may keep the store tidy but is never
  load-bearing, because the node death durability exists to survive takes
  the hook down with it.

  Whether a run is live is the host's question, not this package's: a
  host running `Statifier.Session` processes answers it from the session
  registry and `Statifier.Session.status/1`
  (`StatifierOban.Timer.Delivery.Session`, the default), while a
  process-less host driving `Statifier.Interpreter` against persisted
  positions answers it from whatever it stores as the run's
  terminated/halted state and feeds the event into its next drive. That
  is why this is a behaviour: `StatifierOban.Config` carries the
  implementation (`:delivery`), and the scheduled job carries it to the
  worker.

  Implementations must be idempotent under redelivery: jobs in this
  package are at-least-once, so `c:deliver/2` can run more than once for
  the same fired timer.
  """

  alias Statifier.Effect.SendDelayed

  @typedoc """
  Why the fired event was not fed back.

  The default Session delivery reports `:terminated` (no live process) or
  the halted session's own status (`:done`, `:cancelled`,
  `:budget_exhausted`); a host implementation reports whatever its run
  store calls the not-live case.
  """
  @type discard_reason :: term()

  @doc """
  Establishes that the run named by `scope` is still live and, only then,
  feeds the fired event back into it.

  Returns `:delivered` when the event was fed back, or
  `{:discarded, reason}` when the run is not live and the event was
  dropped per spec 6.2. "Live" is stricter than "not terminated": a
  halted run (`:done` and friends) still discards, because an event fed
  to a halted session just sits queued.

  A failure that is neither of those - the host's run store unreachable,
  for example - should raise (or exit) rather than return: the job is
  retried by Oban, which is the correct response to an environment fact,
  where a discard is the correct response to a run fact.
  """
  @callback deliver(scope :: String.t(), effect :: SendDelayed.t()) ::
              :delivered | {:discarded, discard_reason()}
end
