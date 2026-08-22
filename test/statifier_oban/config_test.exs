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

  # sabotage: fetch_delivery's default swapped to MyHost.RunStore - went
  # red (the documented default stopped holding), reverted.
  test "new/1 defaults :delivery to the Session-backed liveness check" do
    assert {:ok, %Config{delivery: StatifierOban.Timer.Delivery.Session}} =
             Config.new(oban: MyHost.Oban, timers_queue: :t)
  end

  # sabotage: fetch_delivery ignored the option for the default - went red
  # (the host's module was dropped), reverted.
  test "new/1 carries the host's own delivery module" do
    assert {:ok, %Config{delivery: MyHost.RunStore}} =
             Config.new(oban: MyHost.Oban, timers_queue: :t, delivery: MyHost.RunStore)
  end

  # sabotage: fetch_delivery's guard was widened to any term - went red
  # (nil and a binary both built configs), reverted.
  test "new/1 rejects a :delivery that is not a module" do
    assert {:error, {:invalid_option, :delivery, nil}} =
             Config.new(oban: MyHost.Oban, timers_queue: :t, delivery: nil)

    assert {:error, {:invalid_option, :delivery, false}} =
             Config.new(oban: MyHost.Oban, timers_queue: :t, delivery: false)
  end
end
