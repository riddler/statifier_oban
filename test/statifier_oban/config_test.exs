defmodule StatifierOban.ConfigTest do
  use ExUnit.Case, async: true

  alias StatifierOban.Config

  # sabotage: fetch_oban :error -> {:ok, Oban} broke the missing-option
  # doctest; check_unknown -> :ok broke the unknown-options doctest (verified)
  doctest StatifierOban.Config

  # sabotage: hardcoding the struct field ({:ok, %__MODULE__{oban: :hardcoded}}) went red (verified)
  test "new/1 accepts a host-supplied Oban instance name" do
    assert {:ok, %Config{oban: MyHost.Oban}} = Config.new(oban: MyHost.Oban)
  end

  # sabotage: same struct-field hardcoding mutation went red here (verified)
  test "new/1 accepts a via-tuple instance name" do
    via = {:via, Registry, {MyHost.Registry, :oban}}
    assert {:ok, %Config{oban: ^via}} = Config.new(oban: via)
  end

  # sabotage: fetch_oban :error -> {:ok, Oban} default fallback went red (verified)
  test "new/1 without :oban is an error - there is no default instance" do
    assert {:error, {:missing_option, :oban}} = Config.new([])
  end

  # sabotage: fetch_oban {:ok, nil} -> {:ok, Oban} went red (verified)
  test "new/1 with an explicit nil :oban is the same error" do
    assert {:error, {:missing_option, :oban}} = Config.new(oban: nil)
  end

  # sabotage: check_unknown -> :ok (ignore unknowns) went red (verified)
  test "new/1 rejects unknown options rather than ignoring them" do
    assert {:error, {:unknown_options, [:quue, :extra]}} =
             Config.new(oban: MyHost.Oban, quue: :timers, extra: 1)
  end
end
