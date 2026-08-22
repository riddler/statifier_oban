defmodule StatifierOban.ConfigTest do
  use ExUnit.Case, async: true

  alias StatifierOban.Config

  # sabotage: fetch_required :error -> {:ok, :fallback} broke the missing-
  # option doctests; check_unknown -> :ok broke the unknown-options doctest
  # (both verified)
  doctest StatifierOban.Config

  # sabotage: hardcoding the built struct's oban field went red (verified)
  test "new/1 accepts a host-supplied Oban instance name" do
    assert {:ok, %Config{oban: MyHost.Oban}} =
             Config.new(oban: MyHost.Oban, timers_queue: :statifier_timers)
  end

  # sabotage: the same oban-field hardcoding mutation went red here (verified)
  test "new/1 accepts a via-tuple instance name" do
    via = {:via, Registry, {MyHost.Registry, :oban}}
    assert {:ok, %Config{oban: ^via}} = Config.new(oban: via, timers_queue: :statifier_timers)
  end

  # sabotage: fetch_required :error -> {:ok, :fallback} went red (verified)
  test "new/1 without :oban is an error - there is no default instance" do
    assert {:error, {:missing_option, :oban}} = Config.new(timers_queue: :statifier_timers)
  end

  # sabotage: fetch_required {:ok, nil} -> {:ok, :fallback} went red (verified)
  test "new/1 with an explicit nil :oban is the same error" do
    assert {:error, {:missing_option, :oban}} =
             Config.new(oban: nil, timers_queue: :statifier_timers)
  end

  # sabotage: hardcoding timers_queue: :default in the built struct went red (verified)
  test "new/1 carries the host's timers queue" do
    assert {:ok, %Config{timers_queue: "timers"}} =
             Config.new(oban: MyHost.Oban, timers_queue: "timers")
  end

  # sabotage: the fetch_required :error -> {:ok, :fallback} mutation went
  # red here too (verified)
  test "new/1 without :timers_queue is an error - there is no default queue" do
    assert {:error, {:missing_option, :timers_queue}} = Config.new(oban: MyHost.Oban)
  end

  # sabotage: check_queue_name catch-all -> :ok went red (verified)
  test "new/1 rejects a queue name that is neither atom nor string" do
    assert {:error, {:invalid_option, :timers_queue, 42}} =
             Config.new(oban: MyHost.Oban, timers_queue: 42)
  end

  # sabotage: check_unknown -> :ok (ignore unknowns) went red (verified)
  test "new/1 rejects unknown options rather than ignoring them" do
    assert {:error, {:unknown_options, [:quue, :extra]}} =
             Config.new(oban: MyHost.Oban, timers_queue: :t, quue: :timers, extra: 1)
  end
end
