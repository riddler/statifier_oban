defmodule StatifierOban do
  @moduledoc """
  Durable timers and async invoke execution for
  [Statifier](https://github.com/riddler/statifier-ex), backed by Oban.

  Statifier's session runs delayed sends on `Process.send_after/3`, so every
  in-flight timer dies with the node. This package consumes Statifier's
  effect vocabulary (st-ADR-0054) and schedules that work in Oban instead,
  so a chart with delays measured in hours or days survives a deploy.

  This package never owns an Oban instance (ADR-0002). The host supplies its
  own instance through `StatifierOban.Config`, and this package's
  application supervision tree stays empty: nothing here starts Oban, a
  repo, or a notifier. Jobs scheduled through this package are at-least-once
  and must be idempotent.
  """
end
