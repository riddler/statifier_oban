defmodule StatifierOban.ObanHarnessTest do
  # Not async: registers a named listener process and drains a shared queue.
  use ExUnit.Case, async: false

  alias StatifierOban.{TestRepo, TestWorker}

  # These tests assert the ADR-0002 harness (Oban Lite on SQLite) and Oban
  # itself, not lib/ code, so the sabotage rule for lib/-asserting tests
  # does not apply here.

  @oban_name StatifierOban.HarnessOban

  test "inserts and executes a trivial job on a host-supplied Oban instance" do
    Process.register(self(), :statifier_oban_harness_listener)

    start_supervised!(
      {Oban, name: @oban_name, repo: TestRepo, engine: Oban.Engines.Lite, testing: :manual}
    )

    {:ok, %Oban.Job{id: id}} =
      Oban.insert(@oban_name, TestWorker.new(%{"ref" => "sob-2hx.2"}))

    assert is_integer(id)

    assert %{success: 1, failure: 0} = Oban.drain_queue(@oban_name, queue: :default)
    assert_received {:performed, %{"ref" => "sob-2hx.2"}}
  end

  test "the package's application starts no Oban instance of its own" do
    # ADR-0002: the supervision tree stays empty; Oban's default name is
    # not running unless a test starts it.
    assert is_nil(Process.whereis(Oban))
  end
end
