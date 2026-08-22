defmodule StatifierOban.Timer.JobArgsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import StatifierOban.EffectGenerators

  alias Statifier.Effect.SendDelayed
  alias StatifierOban.Timer.JobArgs

  # Everything Oban stores crosses JSON, so every round-trip below rides
  # through an encode/decode pass, exactly as a job's args would.
  defp through_json(args), do: args |> JSON.encode!() |> JSON.decode!()

  describe "round-trip through the JSON wire" do
    # sabotage: dropped `ordinal: ordinal` from the struct rebuilt in
    # `to_effect/1` (left it minting 1) - the property went red, reverted.
    property "to_effect/1 inverts from_effect/2 for every schedulable effect" do
      check all(scope <- scope(), effect <- send_delayed()) do
        args = scope |> JobArgs.from_effect(effect) |> through_json()

        assert {:ok, ^scope, ^effect} = JobArgs.to_effect(args)
      end
    end

    # sabotage: encode_owner/1 for :onexit emitted ["onentry", a, b] - went
    # red on the owner field mismatch, reverted.
    test "every owner shape survives, including nil" do
      base = send_delayed_fixture()

      for owner <- [nil, {:onentry, 1, 2}, {:onexit, 3, 0}, {:transition, 7}, {:finalize, 2, 1}] do
        effect = %{base | owner: owner}
        args = "run_1" |> JobArgs.from_effect(effect) |> through_json()

        assert {:ok, "run_1", %SendDelayed{owner: ^owner}} = JobArgs.to_effect(args)
      end
    end

    # sabotage: encode_term/1 encoded every term as nil's payload - went
    # red here and in the round-trip property, reverted.
    test "opaque data and caller_context come back byte-identical" do
      effect = %{
        send_delayed_fixture()
        | data: {:tuple, ~c"charlist", %{nested: 1.5}},
          caller_context: {:trace, 123_456_789, :span}
      }

      args = "run_1" |> JobArgs.from_effect(effect) |> through_json()

      assert {:ok, "run_1",
              %SendDelayed{
                data: {:tuple, ~c"charlist", %{nested: 1.5}},
                caller_context: {:trace, 123_456_789, :span}
              }} = JobArgs.to_effect(args)
    end
  end

  describe "typed decode errors" do
    # sabotage: fetch_binary/2 nil clause returned {:ok, "scope"} - went
    # red (missing scope decoded anyway), reverted.
    test "a missing required field is named" do
      args = "run_1" |> JobArgs.from_effect(send_delayed_fixture()) |> through_json()

      assert {:error, {:missing_field, "scope"}} = JobArgs.to_effect(Map.delete(args, "scope"))

      assert {:error, {:missing_field, "ordinal"}} =
               JobArgs.to_effect(Map.delete(args, "ordinal"))
    end

    # sabotage: decode_owner_field/2 catch-all returned {:ok, nil} - went
    # red (garbage owner decoded to nil), reverted.
    test "a malformed owner is an invalid-field error, not a guess" do
      args = "run_1" |> JobArgs.from_effect(send_delayed_fixture()) |> through_json()

      assert {:error, {:invalid_field, "owner", ["script", 1]}} =
               JobArgs.to_effect(Map.put(args, "owner", ["script", 1]))
    end

    # sabotage: decode_term/2 :error clause returned {:ok, nil} - went red
    # (corrupt payload decoded to nil), reverted.
    test "a corrupt opaque payload is an invalid-field error" do
      args = "run_1" |> JobArgs.from_effect(send_delayed_fixture()) |> through_json()

      assert {:error, {:invalid_field, "data", _}} =
               JobArgs.to_effect(Map.put(args, "data", %{"t2b64" => "not-base64!"}))

      garbage = Base.encode64("not a term")

      assert {:error, {:invalid_field, "data", _}} =
               JobArgs.to_effect(Map.put(args, "data", %{"t2b64" => garbage}))
    end
  end

  defp send_delayed_fixture do
    %SendDelayed{
      event: "reminder",
      target: nil,
      type: nil,
      data: %{"k" => 1},
      send_id: "send_1",
      delay_ms: 60_000,
      c_index: 4,
      owner: {:onentry, 1, 0},
      macrostep: 2,
      microstep: 1,
      round: 3,
      ordinal: 5,
      id_from_author?: false,
      caller_context: nil
    }
  end
end
