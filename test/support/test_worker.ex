defmodule StatifierOban.TestWorker do
  @moduledoc """
  Trivial worker for the ADR-0002 harness test: reports its execution to
  the test process registered as `:statifier_oban_harness_listener`.
  """

  use Oban.Worker

  @listener :statifier_oban_harness_listener

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case Process.whereis(@listener) do
      nil -> :ok
      pid -> send(pid, {:performed, args}) && :ok
    end
  end
end
