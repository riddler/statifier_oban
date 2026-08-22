defmodule StatifierOban.TestInvokeHandler do
  @moduledoc """
  A concrete handler built on `StatifierOban.Invoke.Handler`, for the
  conformance and end-to-end tests: `run/1` returns a fixed donedata map
  whose `"result"` key matches the e2e chart's `namelist="result"`, so
  the empty `<finalize/>` auto-assign is observable through a `cond`.

  Test-only. The Oban instance name and queue are fixed so `config/0`
  stays a pure read, the shape the base documents; each test module
  starts the instance itself (host-supplied, per ADR-0002).
  """

  use StatifierOban.Invoke.Handler

  @oban_name StatifierOban.InvokeTestOban
  @queue "invoke_test"

  @spec oban_name() :: Oban.name()
  def oban_name, do: @oban_name

  @spec queue() :: String.t()
  def queue, do: @queue

  @impl StatifierOban.Invoke.Handler
  def config do
    {:ok, config} =
      StatifierOban.Config.new(
        oban: @oban_name,
        timers_queue: "timers_unused",
        invoke_queue: @queue
      )

    config
  end

  @impl StatifierOban.Invoke.Handler
  def run(%Statifier.Effect.Invoke{}), do: {:ok, %{"result" => "enriched"}}
end
