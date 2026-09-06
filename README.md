# StatifierOban

[![CI](https://github.com/riddler/statifier_oban/actions/workflows/ci.yml/badge.svg)](https://github.com/riddler/statifier_oban/actions/workflows/ci.yml)
[![Hex.pm Version](https://img.shields.io/hexpm/v/statifier_oban.svg)](https://hex.pm/packages/statifier_oban)
[![Hex Downloads](https://img.shields.io/hexpm/dt/statifier_oban.svg)](https://hex.pm/packages/statifier_oban)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/statifier_oban/)
[![License](https://img.shields.io/hexpm/l/statifier_oban.svg)](https://github.com/riddler/statifier_oban/blob/main/LICENSE)

Durable timers and async invoke execution for
[Statifier](https://github.com/riddler/statifier-ex), backed by
[Oban](https://github.com/oban-bg/oban).

Statifier's session runs delayed sends on `Process.send_after/3`, so every
in-flight timer dies with the node: a deploy silently drops every pending
delayed send. Charts with human-timescale delays - a signup wizard's
abandonment follow-up, a card authorization's settlement window, escalations
and timeouts measured in hours or days - need the timers to outlive the
process.
This package consumes Statifier's effect vocabulary and schedules that work in
Oban instead.

## Installation

```elixir
def deps do
  [
    {:statifier_oban, "~> 0.8"}
  ]
end
```

## Status

Early, under active development. Delayed sends run through Oban end to end -
schedule from the `SendDelayed` effect, cancel from the `Cancel` effect,
deliver behind the run-liveness check - and `use StatifierOban.Invoke.Handler`
is the Oban-backed invoke handler base on statifier's handler registry. Both
enqueue sites run the host-opaque job-arg fields through the optional
`:opaque_codec` seam described below.

One thing is deliberately unfinished: what a *permanently* failed invocation
should look like inside the chart. A `run/1` that keeps failing exhausts its
Oban retries and is discarded, observable on the job row and nowhere else. The
event vocabulary is statifier-ex's to decide, so the semantics are being
finalized upstream and this package documents the gap rather than inventing an
event for it. See `StatifierOban.Invoke.Handler`'s moduledoc.

Beyond this package's own suite, the shape is exercised downstream:
[statifier_examples](https://github.com/riddler/statifier_examples), a public
example application, runs an abandoned-signup reminder on `Oban.Engines.Lite`
end to end - arming a delayed send, cancelling it, letting it fire, and
delivering the fired event into a run that is rebuilt from storage rather
than held in a process - with no host-side workarounds. Nothing in that is
engine-specific. This package never owns, starts, or names an Oban instance
(ADR-0002), so the engine stays the host's choice; what the host supplies is
the ordinary host-side contract:

- its own Oban instance, configured on whichever engine it wants (that app
  names `Oban.Engines.Lite`, and a matching notifier with it, because SQLite
  has no `LISTEN/NOTIFY` for the default one to use);
- Oban's own migration, run against the host's repo - this package ships
  none;
- a `StatifierOban.Timer.Delivery` implementation, where the default
  session-registry one does not fit. That app keeps its runs in storage
  rather than in session processes, so its delivery answers the liveness
  question from the stored run's status and feeds the fired event back as
  one more drive.

## A worked example

Two things have to be true before any of this runs: the host owns an Oban
instance (this package never starts one - ADR-0002), and the host names the
queues. That is the whole of the configuration:

```elixir
{:ok, config} =
  StatifierOban.Config.new(
    oban: MyApp.Oban,                  # the host's own Oban instance name
    timers_queue: :statifier_timers,   # required
    invoke_queue: :statifier_invokes   # only if you run invoke handlers
  )
```

There is no default for any of the three: a missing one is a configuration
error at the call site rather than a silent fall-back into whatever instance
or queue happens to be running.

### Durable timers: a card authorization's settlement window

An authorization holds for seven days. If nothing captures it in that window
it expires, and a capture before then has to take the timer back down. In
SCXML that is one delayed send and one cancel:

```xml
<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="authorized">
  <state id="authorized">
    <onentry>
      <send id="hold" event="authorization.expired" delay="7d"/>
    </onentry>
    <onexit>
      <cancel sendid="hold"/>
    </onexit>
    <transition event="capture.requested" target="capturing"/>
    <transition event="authorization.expired" target="expired"/>
  </state>
  <state id="capturing">
    <!-- filled in by the invoke example below -->
    <transition event="done.invoke.capture" target="settled"/>
  </state>
  <final id="settled"/>
  <final id="expired"/>
</scxml>
```

Left alone, `Statifier.Session` arms that seven-day delay with
`Process.send_after/3` and the next deploy drops it. To make it durable, read
the two effects off the session's subscriber stream and hand them here:

```elixir
defmodule MyApp.TimerSubscriber do
  use GenServer

  alias Statifier.Effect.{Cancel, SendDelayed}
  alias StatifierOban.Timer

  def start_link({session, config}), do: GenServer.start_link(__MODULE__, {session, config})

  @impl GenServer
  def init({session, config}) do
    :ok = Statifier.Session.subscribe(session, self())
    # The scope keys every stored job. `session_id` is the right answer for
    # any host running sessions; a host with its own durable run id supplies
    # that instead, along with its own `StatifierOban.Timer.Delivery`.
    {:ok, %{scope: Statifier.Session.session_id(session), config: config}}
  end

  @impl GenServer
  def handle_info(
        {:statifier, _id, {:effect, {:send_delayed, %SendDelayed{target: nil} = effect}}},
        state
      ) do
    {:ok, _job} = Timer.schedule(state.config, state.scope, effect)
    {:noreply, state}
  end

  # Any other target's route is resolved inside the session and never travels
  # on the effect (st-ADR-0055), so leave it to the library.
  def handle_info({:statifier, _id, {:effect, {:send_delayed, %SendDelayed{}}}}, state),
    do: {:noreply, state}

  def handle_info({:statifier, _id, {:effect, {:cancel, %Cancel{} = effect}}}, state) do
    {:ok, _cancelled} = Timer.cancel(state.config, state.scope, effect)
    {:noreply, state}
  end

  def handle_info({:statifier, _id, _other}, state), do: {:noreply, state}
end
```

`Timer.schedule/3` inserts one job into `:timers_queue`, scheduled at now plus
the effect's relative `delay_ms`, unique on `{scope, ordinal}`. That
uniqueness is the load-bearing part: an at-least-once host that re-executes
the same drive after a crash gets `{:ok, %Oban.Job{conflict?: true}}` and one
stored job, not two authorizations expiring. When the job fires seven days
later, `StatifierOban.Timer.Worker` feeds `authorization.expired` back into
the run through the delivery seam, behind a liveness check - a run that
terminated or halted in the meantime discards the event rather than receiving
it.

`Timer.cancel/3` matches on `{scope, send_id}` and returns `{:ok, count}`:
`capture.requested` leaves `authorized`, the `<cancel sendid="hold"/>` becomes
a `Cancel` effect, and the stored job is cancelled. A cancel that matches
nothing is `{:ok, 0}`, not an error - a real-time cancel is allowed to lose a
race with a timer that already fired.

### Async invoke: capturing the authorization off the session

The capture itself is a call to a payment processor: slow, retryable, and the
one thing that must not happen twice. `use StatifierOban.Invoke.Handler` puts
it in an Oban job and delivers completion back as `done.invoke.<invoke_id>`:

```elixir
defmodule MyApp.CaptureHandler do
  use StatifierOban.Invoke.Handler

  @impl StatifierOban.Invoke.Handler
  def config, do: MyApp.statifier_oban_config()

  @impl StatifierOban.Invoke.Handler
  def run(invoke) do
    # `invoke.invoke_id` is the idempotency key upstream hands you, stable by
    # construction across replays. `params` carries an id, not the card.
    with {:ok, capture} <-
           MyApp.Payments.capture_by_invoke_id(invoke.invoke_id, invoke.params) do
      {:ok, %{"capture_id" => capture.id}}
    end
  end
end
```

Work that keys on the **run** - provisioning tied to the workflow instance, a
write into a per-run table - defines `run/2` instead. The invoke effect names
the invocation but not the run it belongs to, so the second argument carries
the run's scope (and its `invoke_id`) from the job row:

```elixir
@impl StatifierOban.Invoke.Handler
def run(invoke, %{scope: scope}) do
  with {:ok, record} <- MyApp.Provisioning.provision(scope, invoke.invoke_id) do
    {:ok, %{"provision_id" => record.id}}
  end
end
```

Define one arity or the other: a handler defining both runs through `run/2`,
and one defining neither does not compile.

The handler is registered per session, not globally, and the chart names it by
type:

```elixir
{:ok, machine} = Statifier.compile(chart_xml)

{:ok, session} =
  Statifier.Session.start_link(machine,
    invoke_handlers: %{
      "myapp:authorize" => MyApp.AuthorizationHandler,
      "myapp:capture" => MyApp.CaptureHandler
    }
  )

{:ok, _subscriber} = MyApp.TimerSubscriber.start_link({session, config})
```

```xml
<state id="capturing">
  <invoke id="capture" type="myapp:capture"/>
  <transition event="done.invoke.capture" target="settled"/>
  <transition event="error.communication.invoke.capture" target="needs_attention"/>
</state>
```

Entering `capturing` inserts one job into `:invoke_queue`, unique on
`{scope, invoke_id, macrostep}` (ADR-0003) - a replayed drive conflicts with
the stored job, while a genuine re-entry of the state (a retry loop in the
chart) gets a fresh one. Leaving the state before the job runs cancels it.
`run/1` executing twice is still possible, though: the job is at-least-once,
so keying the write on `invoke.invoke_id` is the handler's own job and is not
optional.

The second transition is the other end of the same story. `run/1` returning
`{:error, reason}` retries, as at-least-once work should - but when the
retries run out, the job is discarded and
`error.communication.invoke.capture` is delivered into the run behind the
same liveness check, carrying `%{"reason" => "run_failed", "attempts" => n,
"detail" => text}`. Without it the chart would sit in `capturing` forever on
a processor that never comes back; with it the run parks in
`needs_attention`, where an operator can see it. A chart that would rather
catch every kind of communication failure at once transitions on the bare
`error.communication` instead, and catches this too. See ADR-0005 and
statifier-ex's ADR-0068.

### The same two seams in a signup wizard

Nothing above is specific to card processing. A signup wizard with an A/B test
across its variants uses the same two doors:

- **Durable timer.** `<send id="nudge" event="signup.abandoned" delay="24h"/>`
  on entry to a wizard step, `<cancel sendid="nudge"/>` on exit. The visitor
  who leaves mid-wizard gets the follow-up a day later even though the node
  that scheduled it was replaced by a deploy; the visitor who finishes the
  step cancels it.
- **Async invoke.** `<invoke type="myapp:signup">` with the step and the
  assigned variant in `params`, so recording a conversion event happens off
  the wizard's own progress. `invoke_id` keys the write, so a redelivery
  records one conversion rather than two - which is the difference between an
  A/B result and a fiction.

### Fan-out: one invocation, N children

A `core.map`-shaped block is one invocation that becomes N child runs, one
per item, with their answers accumulated into one result. This package
schedules that; it does not create runs. A handler fans out by returning
`{:fan_out, items}` instead of `{:ok, donedata}`:

```elixir
defmodule MyApp.MapHandler do
  use StatifierOban.Invoke.Handler

  @impl StatifierOban.Invoke.Handler
  def config, do: MyApp.statifier_oban_config()

  # `run/2` rather than `run/1`, because the list is not on the effect.
  # `core.map` compiles its `items` field into the params as a quoted
  # literal (`sb-ADR-0009` decision 3), so `invoke.params["items"]` is
  # the datamodel *path* the author typed - `"chunks"` - and never the
  # list itself: the emitted bytes are the same over any N. A job holds
  # the effect and no datamodel, so evaluating that path is the
  # handler's work, against the parent run's own persisted position -
  # which is what the job's scope names.
  @impl StatifierOban.Invoke.Handler
  def run(invoke, %{scope: parent_run_id}) do
    with {:ok, path} <- items_path(invoke),
         {:ok, machine_state} <- MyApp.Runs.machine_state(parent_run_id) do
      # Fan out over descriptors - ids, ranges - not over row payloads:
      # every start job reads this list again, and it lives in the
      # parent run's datamodel for the run's whole life.
      resolve(machine_state.datamodel, path)
    end
  end

  defp items_path(%{params: %{"items" => path}}) when is_binary(path) and path != "",
    do: {:ok, path}

  defp items_path(invoke), do: {:error, {:items_missing, invoke.invoke_id}}

  # A dotted walk over the string-keyed datamodel. What the block emits
  # is a path and not an expression, so a host that evaluated it as one
  # would be inventing a capability `core.map` deliberately withheld.
  # Neither refusal is a condition a retry changes.
  defp resolve(datamodel, path) do
    case get_in(datamodel, String.split(path, ".")) do
      items when is_list(items) -> {:fan_out, items}
      nil -> {:error, {:items_undefined, path}}
      _other -> {:error, {:items_not_a_list, path}}
    end
  end
end
```

That return says "this invocation is N children, not an answer": the job
enqueues one start job per index and completes **without delivering**, and
the invocation stays open until the settlement side answers it once, on
behalf of all N. An empty `items` list is the one exception: a fan-out over
nothing succeeds over nothing, so no start job goes out and the job answers
the invocation with `[]` immediately (`sb-ADR-0009` decision 8). All N start
jobs go out up front - there are no slices, and
the queue's own concurrency limit is what bounds how many children run at
once. A handler may pass a width hint of its own as
`{:fan_out, items, max_concurrency: n}`, and it is shape-validated and
clamped to that limit in both directions; a hint below it is not honoured
(ADR-0007 and its 2026-09-05 Note). `core.map` declares no such field, so
nothing arrives in `params` to pass along: `max_concurrency` is one of the
block fields `sb-ADR-0009` decision 4 leaves deferred. A fan-out isolated
from a host's other async work gets its own queue, which is a deployment
change.

Two config options belong to this half:

| Option | Default | What it is |
|---|---|---|
| `:child_starter` | `nil` | the module implementing `StatifierOban.Invoke.ChildStarter` that each start job creates its child through - the seam, because this package creates no runs |
| `:max_fan_out` | `1_000` | the cap on a fan-out's width, checked before the first child start; a wider fan-out starts nothing and fails the invocation on `error.communication.invoke.<invoke_id>` with the count and the cap in `detail` |

The seam's callback takes five values - the **parent run id, the effect,
the index, the count, and an option list** - and must be idempotent on
`{parent run id, invoke_id, index}`, because a start job is at-least-once
like every other job here:

```elixir
@impl StatifierOban.Invoke.ChildStarter
def start_child(parent_run_id, invoke, index, count, opts) do
  StatifierPersistence.Driver.start_child_at(
    MyApp.driver(), parent_run_id, invoke, index, count, opts
  )
  |> case do
    :ok -> :ok
    {:refused, reason} -> {:error, reason}
  end
end
```

`opts` carries `policy: :all | :first_error`, the invocation's aggregation
policy, and is where a later scheduling fact would arrive too - so read the
keys you know and ignore the rest. The policy is read off the `core.map`
invocation's own `on` parameter: `"all"`, `"first_error"`, or absent, which
means `:all`. An `on` that is neither word refuses the fan-out on
`error.communication.invoke.<invoke_id>` rather than defaulting, because
`:all` and `:first_error` differ in whether a failing child cancels its
siblings. It rides on every start job rather than being held once by the
starter module, because the settlement side records it on **each child's
own linkage** at creation.

A host running
[statifier_persistence](https://github.com/riddler/statifier_persistence)
passes it straight through to that package's

```elixir
StatifierPersistence.Driver.start_child_at(
  driver, parent_run_id, effect, index, count, policy: :all | :first_error
) :: :ok | {:refused, term()}
```

(0-based `index`, `count` = N, `effect` accepted either as the resolved
`%Statifier.Effect.Invoke{}` or as the whole `{:start_child, ...}`
instruction, and `opts` the same keyword list this seam is handed). The
host's module is what holds the driver; a host with its own run store
wires its own function instead:

```elixir
{:ok, config} =
  StatifierOban.Config.new(
    oban: MyApp.Oban,
    timers_queue: :statifier_timers,
    invoke_queue: :statifier_invokes,
    child_starter: MyApp.ChildStarter,
    max_fan_out: 500
  )
```

When a fan-out fails and the remaining children have to be cancelled, the
children that already exist are cancelled as runs by whoever owns them;
`StatifierOban.Invoke.FanOut.cancel_unstarted/3` is the other door, for the
indices whose start job has not run yet and which therefore have no run
record to cancel.

## The contract this package implements

The host-facing pattern is already specified upstream, and this package is one
implementation of it rather than the definition of it:

- `docs/durable-timers.md` in statifier-ex is the recipe: consume the effect,
  schedule externally, feed the fired event back in.
- ADR-0054 there records the rules a durable-timer host works to - consume the
  effect vocabulary rather than the instruction vocabulary, the re-entry door,
  how stored timers are keyed, and what replaces the SCXML 6.2
  discard-on-termination guarantee. ADR-0055 records the routing limit below.

Read both before adding code here. One limit recorded upstream shapes what
this package can promise:

- The contract covers delayed sends that resolve to the session itself. A
  send routed to `#_internal`, `#_parent`, `#_invokeid`, or an external session
  is left to the library, because the resolved route does not travel on the
  effect.

(An earlier limit is gone: ADR-0059 in statifier-ex added a per-execution
`ordinal` to the durable-timer effects, so a hand-written `id` on a
`<send delay="...">` inside a `<foreach>` is fully supported and the old
leave-the-id-off guidance is retired.)

## Sensitive values in job args

The five host-opaque job-arg fields (a timer's `data` and `caller_context`,
an invoke's `params`, `content` and `caller_context`) are stored in
`oban_jobs.args` as
Base64-encoded external term format - encoded, not protected. Anyone who can
read the host's Oban table can read them.

Two answers, and most hosts want the first:

1. **Pass ids, not values.** Put entity ids in `data`, `caller_context`,
   `params`, and `content`, and re-fetch the current record at execution
   time inside the handler's `run/1` or at delivery. Nothing sensitive is
   ever written to the job row, the row stays small and readable during an
   incident, and the value the handler acts on is the current one rather
   than one captured hours earlier - which matters when the delay is
   measured in days. A `myapp:authorize` invoke would put an authorization
   request id in `params` and let `run/1` load the record by that id,
   rather than carrying the card details on the job;
   `StatifierOban.Invoke.Handler`'s moduledoc shows that `run/1` shape.
2. **Configure `:opaque_codec`** when a value genuinely has to travel on
   the row. Implement `StatifierOban.OpaqueTerm.Codec` and name the module
   in `StatifierOban.Config`. It must round-trip byte-identically; its
   module name travels in the payload alongside the encoded bytes, so
   every node that later reads the row needs the module deployed; key
   rotation lives inside the host's codec, because the module name - not
   any key material - is what is durable; an unresolvable codec or a
   failing decode retries rather than cancelling; and a codec failure at
   enqueue means no job is inserted. See ADR-0004 for the full decision.

The two compose: ids-only for most fields, a codec for the few that
genuinely cannot be reduced to an id. The non-opaque fields (`scope`,
`send_id`, `invoke_id`, and the position data) are never transformed by
either answer, because dedup and cancellation query them directly.

## Telemetry

`StatifierOban.Telemetry` emits eleven `[:statifier_oban, ...]` events - five
on the timer half, six on the invoke half - covering the one thing neither
Oban nor Statifier can see: the durable step between the effect and the job
row. Whether the write happened and whether it was new (`conflict?`), which
statechart identity an opaque job row belongs to, and the spec-level verdicts
that are successes for Oban and non-events for the chart - the 6.2 discard of
a timer firing into a dead run above all.

Attach to the whole surface without hand-copying names:

```elixir
:telemetry.attach_many(
  "my-app-statifier-oban",
  StatifierOban.Telemetry.events(),
  &MyApp.Telemetry.handle_event/4,
  nil
)
```

Emission is unconditional and there is no knob to disable it: an event with no
handlers is a lookup and a return. Duration, attempts, retries, snoozes and
queue latency are Oban's and are not re-emitted here.

`docs/telemetry.md` is the full contract - every event with its measurements
and metadata, what is deliberately absent, and what
`opentelemetry_statifier` builds on top of it. ADR-0006 records the decisions
behind it, including the amendment discipline that makes these names as public
as a function signature.

## Scope

In scope: delayed sends into Oban jobs with cancellation, and an Oban-backed
invoke-handler base built on Statifier's per-session handler registry.

Out of scope: storage of chart state, and the handler registry itself. Both
belong to other packages.
