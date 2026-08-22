# ADR-0001: Record architecture decisions

Status: accepted (2026-08-22)

## Context

This package implements a contract owned elsewhere (statifier-ex's
ADR-0054 durable-timer rules and its ADR-0055 routing limits), while the
decisions it owns for itself - Oban scheduling, dedup keying, retry
semantics, queue and worker layout - are exactly the kind that accumulate
as unrecorded folklore or end up buried in commit messages where nobody
looks for them.

statifier-ex records decisions as ADRs under `docs/adr/`, numbered
sequentially, with a three-section format (Context, Decision,
Consequences) and an index table in `docs/adr/README.md`. Citing an ADR
number ends re-argument; amending one is explicit. The rest of the family
follows the same practice.

## Decision

This repository records architecture decisions the same way: numbered
ADRs under `docs/adr/`, three-section format, a Status line with the
date it took effect, indexed in `docs/adr/README.md`, next free number
picked against a freshly fetched remote. An accepted ADR is never
rewritten: changing or extending a decision means a new ADR that
supersedes or amends it, with the old ADR's Status line updated to
point at its successor. A decision owned by another repository is
adopted by reference in an ADR here, never restated in a way that
could drift.

## Consequences

- Design decisions land as ADRs before or with the code that encodes
  them; cite numbers instead of re-arguing.
- Cross-repo authority follows the umbrella rule: the repository whose
  files change owns the decision. Effect-vocabulary and durable-timer
  contract questions go to statifier-ex; how effects are scheduled,
  keyed, and retried in Oban is decided here.
- No automated ADR tooling (statifier-ex's guard and judge) is adopted
  yet; that is a decision to record when there is an ADR set worth
  protecting mechanically.
