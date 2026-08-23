# ADR-0003: Macrostep joins the invoke job dedup key

Status: proposed (2026-08-23, sob-76d) - the decision is the operator's;
this record lays out the collision, the options, and a recommendation

## Context

`StatifierOban.Invoke.Worker` deduplicates enqueues on the
`{scope, invoke_id}` pair, over every job state and an infinite window.
That key was chosen for the crash-replay case st-ADR-0051 decision 4
names: re-executing the same drive after a crash re-performs the same
start instruction, `invoke_id` rebuilds byte-identically, and the
duplicate insert conflicts with the stored job and becomes a no-op.

The first production embedder (a production CQRS/Oban host) found the
case that key cannot represent, during its end-to-end spike
(2026-08-23). Upstream, a document-authored invoke id is used verbatim -
st-ADR-0008 as amended, "document-authored IDs are always respected"
(`Statifier.Machine.Invoke`). A chart whose states re-enter - a retry
loop is the canonical shape - therefore produces `<invoke id="resolve">`
with a byte-identical `invoke_id` on every re-entry. Each re-entry is a
legitimately new invocation: the state exited (cancelling the old one)
and was entered again. Under the infinite-window `{scope, invoke_id}`
key, the second entry's insert conflicts with the first entry's stored
job - in whatever terminal state it reached - and the fresh invocation
silently never runs. Only generated ids (`invoke_counter`) escape,
because the counter is never reset and each re-entry mints a new id.

The host reconciled by packing its scope as `run_id#macrostep` (its own
scope wrapper), so crash replays still dedup while re-entries get fresh
jobs, and by matching cancels with a scope-prefix `LIKE`. It works, but
it overloads the meaning of `scope`, forces prefix matching into
cancellation, and every embedder would have to rediscover and reimplement
it.

Three facts bound the fix:

**1. The effect already carries the discriminator.** A
`%Statifier.Effect.Invoke{}` carries `macrostep`, `microstep`, and
`round` - "the counters as they stand when the invoke is produced" -
and they are pure fold state, so a crash replay rebuilds them
byte-identically (the same argument st-ADR-0059 makes for the timer
ordinal). `StatifierOban.Invoke.JobArgs` already writes `macrostep` at
the top level of the args, where Oban's uniqueness `keys` read.

**2. Macrostep granularity is exactly re-entry granularity for
invocations.** Invocations start only at the end of a macrostep, for
states still active then (spec 6.4's statesToInvoke discipline): a state
exited mid-macrostep never invokes, so a `{state_index, invoke_index}`
pair invokes at most once per macrostep. Within one macrostep,
`{scope, invoke_id, macrostep}` collides exactly when the insert is a
replay of the same scheduling decision; across macrosteps it never
collides. This is where invocations differ from timers: a `<send>`
inside a `<foreach>` executes many times per microstep, which is why
timers needed a minted ordinal (st-ADR-0059) - invocations do not.

**3. Cancellation addresses the id, not the generation.** Spec 6.4.3
cancels the invocation named by its id when the state exits; the base
handler matches stored jobs on `{scope, invoke_id}` via an args query,
not via the unique key. That match must keep spanning every generation -
exactly as timer cancellation matches every row under a `send_id` - so
the discriminator belongs in the insert key only.

## Decision

Three options were on the table for sob-76d:

**A. Bless the host's scope-packing recipe as documented practice.**
Rejected: it overloads `scope` (one field carrying two identities),
forces prefix-`LIKE` cancel matching on every embedder, leaks into the
delivery seam (the packed scope must be unpacked before the run-liveness
check), and diverges invoke-job scoping from timer-job scoping inside
the same package.

**B. Add `macrostep` to the worker's unique keys.** Chosen. The unique
key becomes `{scope, invoke_id, macrostep}`, all three read off the args
at the top level, window and states unchanged. `JobArgs` already puts
the field on the wire, so no wire change, no upstream change, and stored
rows keep self-describing. Cancellation is untouched: it still matches
`{scope, invoke_id}` across every generation. The host recipe becomes
unnecessary: hosts pass their plain scope again.

**C. Ask statifier-ex for a first-class per-execution ordinal on
`%Effect.Invoke{}`** (st-ADR-0059's shape, a third counter or the shared
`timer_counter`). Not pursued: fact 2 means macrostep already gives
per-scheduling-decision uniqueness for invocations, so the ordinal would
add an effect-struct field upstream to solve a problem the effect's
existing fields solve. If upstream ever grows one for its own reasons,
this key can migrate by a superseding ADR.

## Consequences

- A re-entered state's authored invoke id schedules a fresh job; a crash
  replay of the same drive still dedups. The two cases are separated by
  a field that is deterministic fold state, per the same replay argument
  the timer key rests on.
- Hosts that packed generation into the scope should stop: with this key
  the packed scope splits one run's jobs across scopes for no benefit,
  and plain scopes restore uniform cancel matching. (No released version
  carried the old key; 0.1.x shipped timers only.)
- Residual, recorded honestly: two `<invoke>` elements authored with the
  same id, active in the same macrostep of the same session, still
  collide. That document is already ambiguous upstream - `done.invoke.
  <invoke_id>` delivery and 6.4.3 cancellation address the same shared
  id - so whether it is even valid is statifier-ex's call (invoke-id
  semantics are the interpreter contract's); this package does not
  paper over it with a wider key. The same boundary covers the stale-
  generation delivery question: a prior generation's completed job that
  escaped cancellation delivers `done.invoke.<id>` that the session
  cannot tell from the new generation's - the delivery seam's liveness
  check knows runs, not generations. Both are raised upstream rather
  than decided here.
