defmodule StatifierOban.OpaqueTermTest do
  use ExUnit.Case, async: true

  alias StatifierOban.OpaqueTerm

  # sabotage: `encode/1`'s nil arm returned an encoded nil payload - went
  # red (the nil round-trip stopped being the bare nil the row stays
  # readable with), reverted.
  test "nil stays nil in both directions" do
    assert OpaqueTerm.encode(nil) == nil
    assert {:ok, nil} = OpaqueTerm.decode_field(%{"data" => nil}, "data")
    assert {:ok, nil} = OpaqueTerm.decode_field(%{}, "data")
  end

  # sabotage: `decode/2` dropped the Base64 step - went red (every
  # payload came back {:error, ...}), reverted.
  test "an arbitrary term round-trips byte-identical through the JSON wire" do
    term = %{"k" => [1, :two, {~U[2026-08-22 12:00:00Z], self()}]}

    args = %{"data" => OpaqueTerm.encode(term)} |> JSON.encode!() |> JSON.decode!()

    assert {:ok, ^term} = OpaqueTerm.decode_field(args, "data")
  end

  # sabotage: `decode_field/2`'s catch-all returned {:ok, other} - went
  # red (the malformed rows decoded), reverted.
  test "malformed payloads are typed errors about the row, never raises" do
    assert {:error, {:invalid_field, "data", "plain"}} =
             OpaqueTerm.decode_field(%{"data" => "plain"}, "data")

    assert {:error, {:invalid_field, "data", "!!!"}} =
             OpaqueTerm.decode_field(%{"data" => %{"t2b64" => "!!!"}}, "data")

    corrupt = Base.encode64("not external term format")

    assert {:error, {:invalid_field, "data", _binary}} =
             OpaqueTerm.decode_field(%{"data" => %{"t2b64" => corrupt}}, "data")
  end
end
