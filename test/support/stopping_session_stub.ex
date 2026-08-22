defmodule StatifierOban.StoppingSessionStub do
  @moduledoc """
  A registered process whose `:status` call stops without replying, so
  the caller of `Statifier.Session.status/1` exits mid-call.

  This is the deterministic stand-in for the race
  `StatifierOban.Timer.Delivery.Session` documents between its two steps:
  the registry lookup finds a live pid, and the process is gone by the
  time the status call lands. `Registry` cleans a dead process's entries
  up asynchronously, so constructing the race with a real session is
  inherently flaky; stopping inside the call is the same observable fact
  at the caller.
  """

  use GenServer

  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(scope), do: GenServer.start_link(__MODULE__, scope)

  @impl GenServer
  def init(scope) do
    {:ok, _owned} = Registry.register(Statifier.Registry, scope, nil)
    {:ok, scope}
  end

  @impl GenServer
  def handle_call(:status, _from, scope), do: {:stop, :normal, scope}
end
