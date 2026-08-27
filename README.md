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
    {:statifier_oban, "~> 0.2"}
  ]
end
```

## Status

Early, under active development. Delayed sends run through Oban end to end -
schedule from the `SendDelayed` effect, cancel from the `Cancel` effect,
deliver behind the run-liveness check - and `use StatifierOban.Invoke.Handler`
is the Oban-backed invoke handler base on statifier's handler registry.

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

The four host-opaque job-arg fields (a timer's `data` and `caller_context`,
an invoke's `params` and `content`) are stored in `oban_jobs.args` as
Base64-encoded external term format - encoded, not protected. Anyone who can
read the host's Oban table can read them.

Two answers, and most hosts want the first:

1. **Pass ids, not values.** Put entity ids in `data`, `caller_context`,
   `params`, and `content`, and re-fetch the current record at execution
   time inside the handler's `run/1` or at delivery. Nothing sensitive is
   ever written to the job row, the row stays small and readable during an
   incident, and the value the handler acts on is the current one rather
   than one captured hours earlier - which matters when the delay is
   measured in days. The moduledoc example at
   `lib/statifier_oban/invoke/handler.ex:16-30` already does this: an
   `myapp:authorize` invoke whose `params` carry an authorization request
   id, with `run/1` loading the record by that id rather than carrying the
   card details on the job.
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

## Scope

In scope: delayed sends into Oban jobs with cancellation, and an Oban-backed
invoke-handler base built on Statifier's per-session handler registry.

Out of scope: storage of chart state, and the handler registry itself. Both
belong to other packages.
