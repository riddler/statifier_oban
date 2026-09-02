# Telemetry and the OpenTelemetry bridge half

This note is the design record for what `statifier_oban` emits and what it
deliberately leaves to others. The eleven events below are implemented in
`StatifierOban.Telemetry` (sob-kmw), which owns every event name and is the
only module here that calls `:telemetry.execute/3`. This note and
`docs/adr/0006-telemetry-events-for-the-durable-seams.md` are the contract it
implements; neither is amended by the implementation.

Three records govern and are not restated here:

- statifier-ex `docs/opentelemetry.md` and `st-ADR-0062` - the family's span
  topology and the ruling that the OpenTelemetry bridge is one separate
  package, `opentelemetry_statifier`, consuming public `:telemetry` events
  only. Its "What lands where" table assigns *sibling-package telemetry
  surfaces and their bridge halves* to "each sibling repo's own ADR, bridged
  in `opentelemetry_statifier`". That line is this note's mandate.
- statifier-ex `st-ADR-0040` (as amended by `st-ADR-0067`) and
  `Statifier.Telemetry` - the family's event conventions, adopted here in
  full except where this note records a deliberate departure.
- `st-ADR-0063` - `caller_context`, the opaque host slot that rides on
  `%SendDelayed{}` and `%Cancel{}` and is already carried through this
  package's job args and back onto the fired effect untouched.

## The question this package actually has

Two other surfaces already report on this package's work, and most of what
looks like an obvious event here is already covered by one of them.

**Oban instruments the job.** Every job this package stores is an ordinary
Oban job, and `[:oban, :job, :start | :stop | :exception]` carry the whole
`%Oban.Job{}` in metadata - `worker`, `queue`, `args`, `attempt`,
`max_attempts`, `meta`, `id`, `state`, `scheduled_at`, `errors` - plus
`:duration`, `:queue_time`, `:memory` and `:reductions`. `[:oban, :engine,
:insert_job | :cancel_all_jobs | :discard_job | ...]` cover the writes.
Emitting a second timing for the same job would give a host two numbers and
two places to fix when they disagree.

**statifier-ex instruments the effect.** `[:statifier, :session, :effect,
:send_delayed]` already fires the moment the chart decides to arm a delayed
send, carrying `delay_ms`, `ordinal`, `send_id`, `target`, `caller_context`,
`macrostep`, `microstep`, `round` and the location. `[..., :effect, :cancel]`
and `[..., :effect, :invoke]` do the same for the other two. The *decision*
is upstream's to report, and it is already reported.

So this package's question is narrow: **what happens between the effect and
the job row that neither of those can see?** Three answers, and they are the
whole contract.

1. **Whether the durable write actually happened, and whether it was new.**
   Upstream says the chart armed a timer. Oban says a row exists. Neither
   says that *this* effect became *that* row, and neither says the insert
   conflicted. Conflicting is the normal case here - the `{scope, ordinal}`
   dedup key (`st-ADR-0059`; ADR-0003 for the invoke triple) exists
   precisely so a replayed drive re-inserts and no-ops - so "did that replay
   do anything" is a question with no current answer. `job.conflict?` off
   the insert is the answer, and this package is the only place holding it.
   The same gap covers the two ways a scheduling attempt produces no row at
   all: the `st-ADR-0055` non-self-target bailout, and a missing
   `:invoke_queue`.

2. **The statechart identity behind an opaque job row.** The chart-level
   facts - which run, which `send_id`, which `invoke_id`, which macrostep -
   live inside `args` as encoded strings. A bridge that had to reach in and
   parse them would be reading this package's wire format, which
   `st-ADR-0062` and the bridge's own `ots-ADR-0002` both forbid. Metadata that
   names them directly is what keeps the bridge a translator.

3. **The verdicts that are successes for Oban and non-events for the
   chart.** A fired timer whose run is no longer live is *discarded* per
   spec 6.2: the delivery seam returns `{:discarded, reason}`, the worker
   returns `{:cancel, {:discarded, reason}}`, and Oban reports
   `[:oban, :job, :stop]` with `state: :cancelled` - a *stop*, not an
   exception, with the reason buried inside `:result`. From Oban's side that
   is a job that asked to be cancelled. From the chart's side it is the
   spec-mandated drop of an event nobody will ever see, and it is the single
   most useful thing in this package to be able to count. The same holds for
   a completed invocation delivered into a dead run, for the spec 6.3 and
   6.4.3 cancellation sweeps (whose `count` is legitimately `0`), and for a
   permanently failed invocation.

Everything else - duration, attempts, retries, queue latency, exceptions,
snoozes - is Oban's, and this package emits nothing for it.

## Conventions adopted from statifier-ex

`Statifier.Telemetry` fixes the family's shape, and this package follows it:

- **Measurements are numbers; metadata is everything else**, including
  integer-valued indexes, because an opaque index has no numeric meaning to
  average. `ordinal`, `macrostep`, `microstep` and `round` are therefore
  metadata here exactly as they are upstream, even though upstream's own
  *effect* events carry `macrostep`/`microstep`/`round` as measurements -
  see the departures below.
- **One definition site, enumerable ahead of a call.** Event names are built
  from module attributes holding literal atoms, and
  `StatifierOban.Telemetry.events/0` returns the full list, the way
  `Statifier.Telemetry.events/0` does. This is not a convenience: the bridge
  attaches one handler per event name under its own handler id, and it cannot
  do that for a list it has to hand-copy.
  Deriving a name segment from a module name at runtime is forbidden for the
  same reason (and by Credo's `UnsafeToAtom`).
- **Moduledoc shape**: a one-line opener naming the governing ADR, a section
  per structural rule, then a markdown table of Event | Measurements |
  Metadata per family, with each family's emission gate stated above its
  table. Each emitter's `@doc` names the exact event it emits.
- **Amendment discipline**, modeled on how `st-ADR-0040` is actually kept -
  a long list of dated in-place amendments rather than successor records.
  Adopted here as an explicit rule: adding a measurement or metadata
  key to an existing event is an amendment and is fine; renaming or removing
  one, or renaming an event, is breaking and needs a new ADR. A bridge that
  needs data these events lack gets a new field here - it never reaches into
  this package.

### Deliberate departures, and why

- **The prefix is `[:statifier_oban, ...]`, not `[:statifier, ...]`.**
  Upstream reserves its second segment (`:session`) for the *logical SCXML
  session*, and nothing this package emits is scoped to one: a scheduling
  call runs on the caller, a worker runs days later on another node, and the
  scope may not be a session id at all. Ecosystem-normal per-package prefixes
  are also what a separate per-library bridge `setup` call implies
  (`opentelemetry_ecto` / `opentelemetry_oban` compose exactly that way).
- **Every event is a single point-in-time event; there are no `:start` /
  `:stop` pairs.** Upstream brackets macrosteps because it owns that
  interval. This package owns no interval Oban does not already own: the
  schedule and cancel calls are single writes, and the fire and run
  intervals are the Oban job's, already spanned by
  `[:oban, :job, :start | :stop]`. Every event below therefore measures
  `system_time` and nothing durational.
- **The identity key is `scope`, not `session_id`.** `StatifierOban.Timer.Key`
  is explicit that the scope is `ctx.session_id` for a live session *or the
  host's own durable run id* for a process-less host, and calling a run id
  `session_id` in the metadata would be a lie on exactly the hosts this
  package exists for. The correspondence is nonetheless one-to-one where
  both exist, and the bridge maps `scope` onto `statifier.session_id` for
  correlation - see "The bridge half".
- **`driver` has no analogue.** `st-ADR-0067` decision 4 puts a `driver`
  atom on every upstream event because several drivers emit the same events.
  Here the driver is always Oban. The nearest thing - which run-liveness
  implementation the job went through - is genuinely variable and travels as
  `delivery` on the delivery-seam events.

## The events

### Scheduling seam

Emitted synchronously on the process that drove the macrostep, before any
Oban job exists.

| Event | Emitted from | Measurements | Metadata |
|---|---|---|---|
| `[:statifier_oban, :timer, :scheduled]` | `Timer.schedule/3`, after a successful insert | `system_time`, `delay_ms` | `scope`, `send_id`, `ordinal`, `macrostep`, `microstep`, `round`, `scheduled_at`, `queue`, `conflict?`, `job_id`, `caller_context` |
| `[:statifier_oban, :timer, :schedule_rejected]` | `Timer.schedule/3`, on any error return | `system_time` | `scope`, `send_id`, `ordinal`, `reason` |
| `[:statifier_oban, :timer, :cancelled]` | `Timer.cancel/3`, after the sweep | `system_time`, `count` | `scope`, `send_id`, `ordinal`, `caller_context` |
| `[:statifier_oban, :invoke, :enqueued]` | `Invoke.Handler.perform_start/3`, after a successful insert | `system_time` | `scope`, `invoke_id`, `macrostep`, `handler`, `queue`, `conflict?`, `job_id` |
| `[:statifier_oban, :invoke, :enqueue_rejected]` | `Invoke.Handler.perform_start/3`, on any error return | `system_time` | `scope`, `invoke_id`, `handler`, `reason` |
| `[:statifier_oban, :invoke, :cancelled]` | `Invoke.Handler.perform_cancel/3`, after the sweep | `system_time`, `count` | `scope`, `invoke_id`, `handler` |

`conflict?` is what answers "did that replay do anything": it is
`job.conflict?` off the insert, and `true` means the dedup key held and no
second job was stored. A host that never sees `conflict?: true` under
crash-replay load has a key that is not doing its job; a host that sees only
`conflict?: true` is replaying and never progressing. Neither is visible from
a job row, because in both cases the row is the same single row.

`reason` on the two `*_rejected` events is the typed error the call returned,
and the vocabulary is exactly the one the functions already have:
`{:non_self_target, target}` (the `st-ADR-0055` bailout - the commonest one,
and not a fault), `{:invalid_scope, ctx}`, `{:missing_option, :invoke_queue}`,
the `Key` errors (`:invalid_scope`, `:missing_send_id`, `:missing_ordinal`),
the codec errors, and an `%Ecto.Changeset{}` from a refused insert.

`count` on the two cancellation events is the sweep's own return. It is
legitimately `0`: spec 6.3 cancels every timer under a `send_id` and a cancel
that matches nothing is a no-op, not an error, and a crash-recovering host
may replay a cancel whose start it never durably recorded. A `0` is data.

### Delivery seam

Emitted on the Oban worker process, inside the job.

| Event | Emitted from | Measurements | Metadata |
|---|---|---|---|
| `[:statifier_oban, :timer, :fired]` | `Timer.Worker.perform/1`, after `:delivered` | `system_time`, `attempt` | `scope`, `send_id`, `ordinal`, `delivery`, `job_id`, `caller_context` |
| `[:statifier_oban, :timer, :discarded]` | `Timer.Worker.perform/1`, on `{:discarded, reason}` | `system_time`, `attempt` | `scope`, `send_id`, `ordinal`, `delivery`, `reason`, `job_id`, `caller_context` |
| `[:statifier_oban, :invoke, :delivered]` | `Invoke.Worker.perform/1`, after `:delivered` | `system_time`, `attempt` | `scope`, `invoke_id`, `macrostep`, `handler`, `delivery`, `job_id` |
| `[:statifier_oban, :invoke, :discarded]` | `Invoke.Worker.perform/1`, on `{:discarded, reason}` | `system_time`, `attempt` | `scope`, `invoke_id`, `macrostep`, `handler`, `delivery`, `reason`, `job_id` |
| `[:statifier_oban, :invoke, :failed]` | `Invoke.Worker`'s terminal-attempt failure path | `system_time`, `attempts` | `scope`, `invoke_id`, `reason`, `detail`, `handler`, `job_id` |

**There is no lateness measurement here, on purpose.** How far past its due
time a timer actually fired is the number a durable timer most wants to make
answerable, and it is tempting to compute it as `utc_now` minus the job's
`scheduled_at`. Oban already publishes exactly that: `:queue_time` on
`[:oban, :job, :stop]` is `attempted_at - scheduled_at` computed in
nanoseconds (`Oban.Queue.Executor.record_finished/1`), which is the same
subtraction against the same two timestamps. Emitting it again would be the
duplication this whole contract exists to avoid. Read the measurement as
`:native` time units, not as nanoseconds: the executor converts before
emitting, the same way it does for `:duration`. The one caveat belongs to
Oban either way: on a retried job `scheduled_at` has been rewritten by the
backoff, so on any attempt past the first, both numbers measure the backoff
rather than the original lateness, and the original due time is no longer on
the row for anyone to recover.

`reason` on the two `:discarded` events is the delivery seam's
`t:discard_reason/0` - `:terminated` for no live run, or the halted run's own
status (`:done`, `:cancelled`, `:budget_exhausted`), or whatever a host's own
run store calls the not-live case. This is the spec 6.2 verdict as data, and
it is the value Oban buries inside `:result`.

`[:statifier_oban, :invoke, :failed]` mirrors
`c:StatifierOban.Invoke.Delivery.deliver_failure/3` exactly, including the
three-class `reason` vocabulary ADR-0005 fixed - `"run_failed"`,
`"run_crashed"`, `"undecodable"` - and its `attempts` semantics, which are
`max_attempts` for the first two and the cancelling attempt's own number for
`"undecodable"`. It fires from the same two call sites as the delivery, on
the terminal attempt only, for the same reason: a retry that will be tried
again is not a fact worth reporting, and non-terminal failures are already
`[:oban, :job, :exception]`.

Where the seam delivers nothing, this emits nothing. The environment errors
`:invalid_handler`, `:invalid_delivery`, `:invalid_codec` and `:codec_failed`
say the deploy is wrong rather than anything about the invocation, and
ADR-0005 already records that limit; they ride Oban's exception event.

### What is deliberately absent

- **No event for a retry, a snooze, an exception, a queue wait, or a job
  duration.** All Oban's, all already emitted, all with the full job row.
- **No event around `handler.run/1` or `handler.run/2`.** The host's work is
  the host's to instrument. Wrapping it here would put this package inside a
  span it knows nothing about, and the enclosing job span already bounds it.
- **No event for the codec seam.** How often a host's own encryption fails is
  not a statechart-shaped fact, and surfacing it in this stream would leak
  the host's key-rotation state into a chart's telemetry.
- **No `:start` / `:stop` pairs.** See the departures above.

## Cardinality

Every metadata key above is bounded, and bounded by the chart rather than by
traffic: `scope` is one per run; `send_id` and `invoke_id` are one per
authored node or a deterministic counter; `handler`, `delivery`, `queue` and
`reason` are module names or fixed vocabularies. `job_id` is unbounded and is
present as a correlation id for a span or a log line, never as a metric
dimension - the same status Oban's own `id` has.

**Nothing from the chart's datamodel is ever on an event.** The effect's
`data`, `params` and `content` are host-opaque terms
(`StatifierOban.OpaqueTerm`), possibly encrypted through a host codec, and
they are never emitted - not truncated, not hashed, not "just the keys."
Upstream's `record_datamodel_values` opt-in has no counterpart here, because
there is no value to opt into recording: this package cannot read those
fields even in principle once a codec is configured.

`caller_context` is the one unbounded metadata value, and it is deliberate:
it is an opaque host term, present because the bridge needs it and for no
other reason. A consumer that is not the bridge should ignore it, and no
consumer may fold it into a metric dimension. Upstream states the same rule
for its own `caller_context` metadata - the bridge *uses* the term, and never
flattens it into span attributes.

## The bridge half

`opentelemetry_statifier` is the only package in the family that calls an
OpenTelemetry API (`st-ADR-0062`), and it bridges siblings as separate
per-library `setup` calls rather than as separate packages. This package's
half of that bridge is therefore an obligation, not code: it is the promise
that the events above carry everything the bridge needs, so the bridge never
reads `oban_jobs.args`, `StatifierOban.Timer.JobArgs`, or any other internal
here. Span construction, handler attachment, and the span table are the
bridge repo's decisions and are not this note's to make; where a bullet below
names one, it is reporting what `ots-ADR-0004` accepted, because a sentence
here that contradicted that record would mislead a host reading both.

What the events are built to let the bridge do:

- **`scope` maps to `statifier.session_id`.** The bridge keys its per-session
  correlation on that attribute, and a durable timer whose events used a
  different key would be a run the bridge could not stitch to its own
  macrostep spans. The rename happens in the bridge, once, where the mapping
  is visible; this package keeps the honest name. Every other measurement and
  metadata key maps by name into the `statifier_oban.` namespace, *not* the
  shared `statifier.` one: `ots-ADR-0004` decision 7 gives each bridged
  sibling family its own prefix, because three families sharing one namespace
  would make `statifier.reason` mean three different vocabularies.
  `system_time` is dropped there as clock plumbing the span's own timestamps
  already carry, and `caller_context` never becomes an attribute at all - it
  becomes a link, per the bullet below.

- **Scheduling-seam events land on the macrostep span, through the bridge's
  own span table.** They are emitted synchronously on the process that drove
  the macrostep, which is also the process where upstream's macrostep span is
  open, and they become span events on it. The parent is found in the
  bridge's pid-keyed span table, *not* in the process's ambient OTel context:
  `ots-ADR-0003` decision 8 forbids the bridge from reading or writing that
  context, and `ots-ADR-0004` decision 4 makes its own table the whole of the
  nesting mechanism. Decision 6 adds the pid check - a `scope`'s macrostep
  span is used only when the bridge's row for that scope names this very
  process - so a `scope` that is a host's durable run id matches nothing and
  the event becomes its own span instead. No propagation machinery is
  involved either way.

- **Delivery-seam events are detached roots carrying a link, not spans inside
  the job's trace.** They are emitted inside `perform/1`, days later and
  usually on another node, where this bridge has nothing of its own open at
  all - and because it never reads the ambient context, a job span a host's
  `opentelemetry_oban` has open in that same process does not parent them
  either. Each becomes its own zero-duration root span, linked to the arming
  trace through `caller_context` (`ots-ADR-0004` decisions 5 and 8).
  Correlation back to the run is by the `statifier.session_id` attribute
  rather than by nesting.

- **The scheduling trace is reached by a link, never by parenthood.** A timer
  that fires three days after it was armed does not belong inside the request
  span that armed it, and would hold that trace open for three days if it
  did. The link's source is `caller_context`, which is why it is on both the
  scheduling and the delivery events: `st-ADR-0063` makes it an opaque host
  slot, the library and this package both carry it without reading it, and
  the OTel-shaped reading of it lives in the bridge. `nil` means no context
  was attached, and a fire with no context is simply an unlinked span - the
  standard detached case, not an error.

- **Restoring the context at fire time happens inside that seam**, and the
  section below says how (`sob-v28`, mirroring the closed `st-yoi0`). This
  note fixes the seam itself: the field is on the effect, it round-trips
  through the job args untouched, it is restored onto the fired event by
  `StatifierOban.Timer.Delivery.fired_event/2`, and it is on the
  delivery-seam telemetry events.

- **`trigger` is a pass-through string.** No event here originates one, but
  where one is carried onward it is copied and never validated against an
  enum. statifier-ex owns that vocabulary and is still growing it (`:resume`
  is the most recent addition); a consumer that hardcodes today's value set
  is wrong on the next release.

- **Trace-off degrades to nothing, structurally.** With no bridge attached,
  `:telemetry.execute/3` on an event with no handlers is a lookup and a
  return. There is no build-time flag, no compile-time removal, and no
  `StatifierOban.Config` option to disable emission - consistent with the
  bridge adding no second filter of its own, and with this package's rule
  that every config option is a seam a host must state explicitly. Upstream's
  `trace: true` sampling knob has no counterpart here: none of these events
  scale with microstep count, so there is nothing to gate.

### Restoring the caller's trace context

A timer armed inside a request and fired three days later is only one trace
if something carries the request's trace identity across the gap. That
something is `caller_context`, and this is the whole of what each party owes.

**The host writes it, at schedule time, in W3C text form.** The host stamps
`%MachineState{}.caller_context` before the macrostep that arms the send
(`st-ADR-0063`), and the core copies it onto the effect. What it should stamp
for tracing is the serialized propagation form - `%{"traceparent" =>
"00-<trace-id>-<span-id>-01"}`, plus `"tracestate"` where the host propagates
one - and not a live span context or an OTel context map. The row outlives
the node: pids, refs and other node-local terms come back meaningless, and
`:safe` decoding turns a term naming atoms the reading node has never seen
into an undecodable row rather than a delivery. Strings and string keys have
neither problem, and the wire form is fixed by a published spec rather than by
a library version. `StatifierOban.Timer.JobArgs` states the two rules; nothing
enforces them, because nothing here reads the term.

**This package carries it and never reads it.** `from_effect/3` encodes it
opaquely (through the host's `:opaque_codec` if one is configured),
`to_effect/1` returns it byte-identical, `Timer.Delivery.fired_event/2` copies
it onto the external event fed back, and the scheduling and delivery events
carry it as metadata. Nothing in this package parses a traceparent, matches on
the slot, or keys anything on it - `caller_context` is not a component of the
dedup key or the cancellation key (`st-ADR-0063` decision 6), so two sends
differing only in caller context are still the same scheduling decision. A
host `Timer.Delivery` implementation owes the one hop this package cannot make
for it: copying the slot onto the event it feeds back, which
`fired_event/2` does for it.

**The async invoke half round-trips it the same way, and hands it back at a
different door.** `%Statifier.Effect.Invoke{}` carries the same slot
(`st-ADR-0063`), `StatifierOban.Invoke.JobArgs` stores it beside `params` and
`content` through the same opaque encoding and the same host codec, and
`StatifierOban.Invoke.Worker` decodes it days later byte-identical. What
differs from the timer half is who builds the answering event. A host driving
`Statifier.Session` does not build one at all: `done_invocation/3` and
`failed_invocation/3` build `done.invoke.<invoke_id>` and
`error.communication.invoke.<invoke_id>` inside the session and inherit the
slot from the session's own invocation table, so
`StatifierOban.Invoke.Delivery.Session` has nothing to carry and implements
only the three-argument doors. A process-less host builds the event itself
with `Statifier.Invoke.Answer.done/4` or `failed/4`, and the job row is its
only record of the invocation - which is what
`c:StatifierOban.Invoke.Delivery.deliver/4` and
`c:StatifierOban.Invoke.Delivery.deliver_failure/4` are for: the same two
doors, handed the stored slot to pass into the builder's `caller_context:`
option. The worker calls whichever arity a delivery module exports, so an
implementation written before those arities existed is untouched. The one
gap is a row whose opaque payload will not decode: the slot is exactly what
failed, so the failure delivery reports `caller_context: nil` and the span is
unlinked, while `scope` and `invoke_id` still name the invocation.

A durable invocation is where the row's copy earns its keep over the
session's. A run resumed after a node death rebuilds its invocation table
from the persisted position, where `caller_context` is an optional entry key;
the Oban row survives that death intact either way, so a process-less host
answering from the row links the completion even when nothing else remembers
the arming trace.

**The bridge turns it into a link, never a parent.** On a delivery-seam event
the bridge reads `caller_context`, extracts the traceparent, and adds a *link*
to the span it opens for the firing; that span is a root with no parent at all,
because the bridge has nothing of its own open on an Oban worker and does not
read the job span a host's `opentelemetry_oban` may have open there.
Parenthood on the arming trace would hold it open for the length of the delay.
`nil` is the ordinary detached case - no context was attached, the fire is
unlinked, and nothing is wrong.

**The last hop is upstream's, and it is already in place.** The fed-back
event's `caller_context` reaches `[:statifier, :session, :macrostep, :start]`
and `[..., :stop]` as metadata, so the macrostep the firing drives is itself
linkable to the arming trace without the bridge correlating anything by hand.
That is the end of the chain, and `StatifierOban.RestartRoundTripTest` pins it
across a simulated node death: schedule with a context, kill every process,
fire from the store, and the context observed on the resumed run's macrostep
is the one that was scheduled.

## For a host that is not using the bridge

The events are plain `:telemetry`. A host attaching `Telemetry.Metrics` gets
counters for scheduled / fired / discarded / failed, and a distribution over
`delay_ms` and one over `count`, with no OpenTelemetry in the picture at all
- and Oban's `:queue_time` sits alongside them for the timing half. That is
why the
contract is defined in events rather than spans, and it is the same reason
`st-ADR-0062` gave for the bridge being a separate package.
