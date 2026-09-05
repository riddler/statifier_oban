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

  # sabotage: fetch_opaque_codec/1 was replaced with a body that always
  # returns {:ok, nil} regardless of opts - went red here and on two
  # doctests (a configured codec never made it into the struct), reverted.
  test "new/1 carries the host's opaque codec module" do
    assert {:ok, %Config{opaque_codec: MyHost.ArgsCodec}} =
             Config.new(oban: MyHost.Oban, timers_queue: :t, opaque_codec: MyHost.ArgsCodec)
  end

  # sabotage: `Keyword.get(opts, :opaque_codec)` was given a non-nil
  # sentinel default (`StatifierOban.SentinelDefaultCodec`) - went red
  # here and on unrelated doctests (an absent option stopped defaulting
  # to identity), reverted.
  test "new/1 defaults :opaque_codec to nil (identity)" do
    assert {:ok, %Config{opaque_codec: nil}} = Config.new(oban: MyHost.Oban, timers_queue: :t)
  end

  # sabotage: fetch_opaque_codec's guard clause was replaced with a
  # catch-all `codec -> {:ok, codec}` - went red (a string and a doctest
  # binary both built configs instead of erroring), reverted.
  test "new/1 rejects an :opaque_codec that is not a module" do
    assert {:error, {:invalid_option, :opaque_codec, "MyHost.ArgsCodec"}} =
             Config.new(oban: MyHost.Oban, timers_queue: :t, opaque_codec: "MyHost.ArgsCodec")

    assert {:error, {:invalid_option, :opaque_codec, true}} =
             Config.new(oban: MyHost.Oban, timers_queue: :t, opaque_codec: true)
  end

  # sabotage: `:opaque_codec` was dropped from `@known_options` - went red
  # here and on the corresponding doctest (a correctly-spelled, valid
  # option was rejected as unknown), reverted.
  test "new/1 still rejects an unknown option alongside a valid :opaque_codec" do
    assert {:error, {:unknown_options, [:bogus]}} =
             Config.new(
               oban: MyHost.Oban,
               timers_queue: :t,
               opaque_codec: MyHost.ArgsCodec,
               bogus: 1
             )
  end

  # -- the fan-out options (ADR-0007, sob-q3y) -----------------------------

  # sabotage: `:child_starter` was dropped from the defstruct's nil list -
  # went red at compile (the struct had no such key), reverted.
  test "new/1 defaults :child_starter to nil" do
    assert {:ok, %Config{child_starter: nil}} = Config.new(oban: MyHost.Oban, timers_queue: :t)
  end

  # sabotage: `fetch_optional_module/2` was made to ignore its `key` and
  # always read `:opaque_codec` - went red (the starter came back nil),
  # reverted.
  test "new/1 keeps a :child_starter module" do
    assert {:ok, %Config{child_starter: MyHost.Starter}} =
             Config.new(oban: MyHost.Oban, timers_queue: :t, child_starter: MyHost.Starter)
  end

  # sabotage: `fetch_optional_module/2`'s guard clause was replaced with a
  # catch-all - went red (a string built a config instead of erroring),
  # reverted.
  test "new/1 rejects a :child_starter that is not a module" do
    assert {:error, {:invalid_option, :child_starter, "MyHost.Starter"}} =
             Config.new(oban: MyHost.Oban, timers_queue: :t, child_starter: "MyHost.Starter")

    assert {:error, {:invalid_option, :child_starter, true}} =
             Config.new(oban: MyHost.Oban, timers_queue: :t, child_starter: true)
  end

  # The default is ADR-0007 decision 8's cap, given a number by R31-9.
  #
  # sabotage: `@default_max_fan_out` was changed to 10 - went red here and
  # on the moduledoc's default, reverted.
  test "new/1 defaults :max_fan_out to 1_000" do
    assert {:ok, %Config{max_fan_out: 1_000}} = Config.new(oban: MyHost.Oban, timers_queue: :t)
  end

  # sabotage: `fetch_max_fan_out/1` ignored the option and always returned
  # the default - went red (the host's 50 came back as 1_000), reverted.
  test "new/1 keeps a host's :max_fan_out" do
    assert {:ok, %Config{max_fan_out: 50}} =
             Config.new(oban: MyHost.Oban, timers_queue: :t, max_fan_out: 50)
  end

  # sabotage: `fetch_max_fan_out/1`'s guard dropped `cap > 0` - went red
  # (zero and a negative cap both built configs), reverted.
  test "new/1 rejects a :max_fan_out that is not a positive integer" do
    assert {:error, {:invalid_option, :max_fan_out, 0}} =
             Config.new(oban: MyHost.Oban, timers_queue: :t, max_fan_out: 0)

    assert {:error, {:invalid_option, :max_fan_out, -1}} =
             Config.new(oban: MyHost.Oban, timers_queue: :t, max_fan_out: -1)

    assert {:error, {:invalid_option, :max_fan_out, "1000"}} =
             Config.new(oban: MyHost.Oban, timers_queue: :t, max_fan_out: "1000")
  end

  # sabotage: `:child_starter` and `:max_fan_out` were dropped from
  # `@known_options` - went red here and on their doctests (correctly
  # spelled options were rejected as unknown), reverted.
  test "new/1 accepts both fan-out options alongside the rest" do
    assert {:ok, %Config{child_starter: MyHost.Starter, max_fan_out: 7}} =
             Config.new(
               oban: MyHost.Oban,
               timers_queue: :t,
               invoke_queue: :i,
               child_starter: MyHost.Starter,
               max_fan_out: 7
             )
  end
end
