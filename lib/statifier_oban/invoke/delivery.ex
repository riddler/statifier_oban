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

  ## Carrying the caller's trace context

  `caller_context` (`st-ADR-0063`) is the opaque host slot the macrostep
  that executed the `<invoke>` stamped onto the effect. It rides the job
  args untouched (`StatifierOban.Invoke.JobArgs`) and is on the
  `%Statifier.Effect.Invoke{}` the worker decodes days later, on another
  node, byte-identical to what was enqueued. **The answer event owes it
  onward**, unchanged, exactly as `StatifierOban.Timer.Delivery` says a
  fired timer's event does: upstream puts the answering event's
  `caller_context` on the macrostep telemetry the answer drives
  (`[:statifier, :session, :macrostep, :start | :stop]`), which is what
  lets `opentelemetry_statifier` link the completion back to the trace
  that started the invocation instead of leaving it detached. Drop the
  slot and the link is lost at the last hop, silently.

  Which door gets it depends on who builds the event, and that differs
  from the timer half:

  - **A host driving `Statifier.Session`** does not build the event at
    all - `Statifier.Session.done_invocation/3` and
    `failed_invocation/3` build it inside the session and inherit the
    slot from the session's own invocation table (`st-ADR-0063`). There
    is nothing for such an implementation to carry, which is why
    `StatifierOban.Invoke.Delivery.Session` implements only the
    three-argument doors.
  - **A process-less host** builds the event itself, with
    `Statifier.Invoke.Answer.done/4` or `failed/4`, and has no
    invocation table to inherit from - the job row is its record of the
    invocation. That is what `c:deliver/4` and `c:deliver_failure/4`
    are for: the same two doors, handed the slot off the row, to pass
    straight into the builder's `caller_context:` option.

  ## Two arities per door

  Each door has a three-argument form and a four-argument one. The
  three-argument forms are the contract and stay required; the
  four-argument forms are optional, and `StatifierOban.Invoke.Worker`
  calls the widest one a delivery module exports - the same "define the
  wider arity when the work needs what it carries" shape
  `StatifierOban.Invoke.Handler` gives `run/1` and `run/2`. A module
  defining both runs through the four-argument form, and its
  three-argument clause is dead code kept for the behaviour; a one-line
  delegate is the usual way to satisfy it:

      @impl StatifierOban.Invoke.Delivery
      def deliver(scope, invoke_id, donedata), do: deliver(scope, invoke_id, donedata, [])

  An existing implementation that defines neither four-argument form is
  unaffected and keeps being called exactly as before. That is the whole
  reason the widening is an added arity rather than a changed signature:
  every `StatifierOban.Invoke.Delivery` written against 0.5.0 still
  conforms.
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
  What the worker knows about the answer that the invoke id and the
  donedata do not carry.

  One key today, `:caller_context` - `st-ADR-0063`'s opaque host slot as
  it was stored on the job row, or `nil` when no context was attached.
  Pass it straight into `Statifier.Invoke.Answer.done/4`'s or
  `failed/4`'s own `caller_context:` option; nothing in this package
  reads it (ADR-0006 decision 7).

  The list is open by construction: this package may add keys, so read
  the ones you need with `Keyword.get/3` rather than matching the whole
  list.
  """
  @type answer_opts :: [caller_context: term()]

  @doc """
  `c:deliver/3` with the answer's `t:answer_opts/0` - the arity to define
  when the implementation **builds the answer event itself** and wants
  the invocation's `caller_context` on it.

  Optional. `StatifierOban.Invoke.Worker` calls this in preference to
  `c:deliver/3` whenever a delivery module exports it, so an
  implementation defining both is only ever reached here. Everything
  `c:deliver/3` promises holds unchanged - the liveness check, the
  return values, and the raise-rather-than-return rule for an
  environment failure.

      @impl StatifierOban.Invoke.Delivery
      def deliver(scope, invoke_id, donedata, opts) do
        if live?(scope) do
          event =
            Statifier.Invoke.Answer.done(scope, invoke_id, donedata,
              caller_context: Keyword.get(opts, :caller_context)
            )

          MyApp.Runs.drive(scope, event)
          :delivered
        else
          {:discarded, :terminated}
        end
      end
  """
  @callback deliver(
              scope :: String.t(),
              invoke_id :: String.t(),
              donedata :: term(),
              opts :: answer_opts()
            ) :: :delivered | {:discarded, discard_reason()}

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

  @doc """
  `c:deliver_failure/3` with the answer's `t:answer_opts/0`, on
  `c:deliver/4`'s terms exactly.

  `failure` and `opts` stay separate lists for
  `Statifier.Invoke.Answer.failed/4`'s own reason: `failure`'s three
  keys become the chart-visible payload, and `:caller_context` is host
  plumbing the datamodel never sees (`st-ADR-0063` decision 2).

  The one asymmetry worth stating: an **undecodable** row reaches this
  door with `caller_context: nil` even when a context was stored. The
  opaque payload is exactly what failed to decode, so the slot is not
  recoverable, while `scope` and `invoke_id` are read off the row as
  plain strings and still name the invocation. An unlinked failure span
  is the correct outcome there, and it is the same detached case a
  never-attached context produces.
  """
  @callback deliver_failure(
              scope :: String.t(),
              invoke_id :: String.t(),
              failure :: failure(),
              opts :: answer_opts()
            ) :: :delivered | {:discarded, discard_reason()}

  @optional_callbacks deliver: 4, deliver_failure: 4
end
