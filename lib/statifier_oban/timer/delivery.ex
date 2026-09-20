defmodule StatifierOban.Timer.Delivery do
  @moduledoc """
  The delivery seam a fired timer job goes through - the execution-liveness
  check st-ADR-0054 decision 4 requires, plus the feed-back itself.

  Spec 6.2 says a delayed send whose session terminated before the delay
  elapsed MUST be discarded without delivery. Inside statifier-ex,
  `Statifier.Session` satisfies that on terminate by cancelling every
  live timer ref before the process exits; a durable scheduler survives process
  death by design, so nothing plays that role for a stored job. What
  replaces it (st-ADR-0054 decision 4): before feeding the fired event
  back, the host MUST establish the execution is still live and discard
  otherwise. The guarantee is enforced here, at delivery time - a
  cancel-on-execution-end hook may keep the store tidy but is never
  load-bearing, because the node death durability exists to survive takes
  the hook down with it.

  Whether an execution is live is the host's question, not this package's: a
  host running `Statifier.Session` processes answers it from the session
  registry and `Statifier.Session.status/1`
  (`StatifierOban.Timer.Delivery.Session`, the default), while a
  process-less host driving `Statifier.Interpreter` against persisted
  positions answers it from whatever it stores as the execution's
  terminated/halted state and feeds the event into its next drive. That
  is why this is a behaviour: `StatifierOban.Config` carries the
  implementation (`:delivery`), and the scheduled job carries it to the
  worker.

  ## The contract for a process-less durable host

  A host whose executions are stored rather than run as processes - one
  driving `Statifier.Interpreter` against persisted positions - owes
  this behaviour an implementation, because the default discards every
  one of its timers: a durable execution registers no process, so
  `StatifierOban.Timer.Delivery.Session`'s registry lookup is empty and
  the fired event is dropped as `:terminated`. The contract such an
  implementation works to is three sentences:

  1. **The scope is the host's execution id.** It is the id the timer
     was scheduled under (`StatifierOban.Timer.Key`) and the id the
     stored execution is read and stepped by, not a session id.
  2. **Liveness is the execution's stored status.** Only an active
     execution takes the event; a finished one answers `{:discarded,
     status}`, with the store's own word for the status - the same
     "live is stricter than not terminated" rule the default applies
     through `Statifier.Session.status/1`.
  3. **Delivery is a step of the execution with the event
     `fired_event/2` builds**, and it is safe to retry: the job's dedup
     key already is (`StatifierOban.Timer.DedupKey`), so a redelivered
     job is the same scheduling decision rather than a second one.

  A store the host cannot reach is an environment fact and raises, per
  `c:deliver/2` above, rather than being reported as a discard. The
  README's "Delivering timers to a durable execution" carries a worked
  host module and the one config line that selects it.

  Implementations must be idempotent under redelivery: jobs in this
  package are at-least-once, so `c:deliver/2` can run more than once for
  the same fired timer.

  ## Restoring the caller's trace context

  `caller_context` (st-ADR-0063) is the opaque host slot the sending
  macrostep stamped onto the effect. It rides the job args untouched
  (`StatifierOban.Timer.JobArgs`) and is on the `%SendDelayed{}` handed
  to `c:deliver/2` days later, on another node, byte-identical to what
  was scheduled. **An implementation MUST copy it onto the event it
  feeds back**, unchanged. That last hop is where the value earns its
  keep: upstream puts the fed-back event's `caller_context` on the
  macrostep telemetry the firing drives
  (`[:statifier, :session, :macrostep, :start | :stop]`), which is what
  lets `opentelemetry_statifier` link the firing back to the trace that
  armed the timer instead of leaving it detached. A delivery that drops
  the slot loses the link at the last hop, and loses it silently.

  `fired_event/2` builds that event correctly, and host implementations
  should use it rather than assembling one by hand - it is the same
  event `StatifierOban.Timer.Delivery.Session` feeds back.

  What a host may put in the slot is the host's business and none of
  this package's: nothing here reads it, matches on it, or keys anything
  on it (ADR-0006 decision 7). Two durability rules do bind the host's
  choice, and they are `StatifierOban.Timer.JobArgs`'s to state.
  """

  alias Statifier.Effect.SendDelayed
  alias Statifier.Evaluator.SystemVariables
  alias Statifier.Event

  @typedoc """
  Why the fired event was not fed back.

  The default Session delivery reports `:terminated` (no live process) or
  the halted session's own status (`:done`, `:cancelled`,
  `:budget_exhausted`); a host implementation reports whatever its
  execution store calls the not-live case.
  """
  @type discard_reason :: term()

  @doc """
  Establishes that the execution named by `scope` is still live and, only
  then, feeds the fired event back into it.

  Returns `:delivered` when the event was fed back, or `{:discarded,
  reason}` when the execution is not live and the event was dropped per
  spec 6.2. "Live" is stricter than "not terminated": a halted execution
  (`:done` and friends) still discards, because an event fed to a halted
  session just sits queued.

  A failure that is neither of those - the host's execution store
  unreachable, for example - should raise (or exit) rather than return:
  the job is retried by Oban, which is the correct response to an
  environment fact, where a discard is the correct response to an
  execution fact.
  """
  @callback deliver(scope :: String.t(), effect :: SendDelayed.t()) ::
              :delivered | {:discarded, discard_reason()}

  @doc """
  Builds the external event a fired timer job feeds back, from the scope
  it was scheduled under and the effect the job stored.

  This mirrors statifier-ex's own `Session.Effects.delivered_event/2` for
  a fired `target: nil` send, so an event that rejoins an execution
  through a durable job is indistinguishable from one an in-process timer
  delivered:

  - `origin` and `origintype` are stamped as the SCXML event processor at
    the sending session's location (C.1);
  - `sendid` rides only when the author wrote the id - an auto-generated
    send id is not observable on the event;
  - `data` and `caller_context` are carried through untouched, neither
    read nor interpreted here.

  It is public because every `StatifierOban.Timer.Delivery` owes the same
  event, and a hand-assembled one is where the `caller_context` link
  quietly goes missing. A host whose execution is not a
  `Statifier.Session` still gets the right event to feed into its next
  `Statifier.Interpreter` drive.
  """
  @spec fired_event(String.t(), SendDelayed.t()) :: Event.t()
  def fired_event(scope, %SendDelayed{} = effect) when is_binary(scope) do
    Event.external(effect.event,
      data: effect.data,
      origin: SystemVariables.scxml_location(scope),
      origintype: SystemVariables.scxml_event_processor(),
      sendid: if(effect.id_from_author?, do: effect.send_id),
      caller_context: effect.caller_context
    )
  end
end
