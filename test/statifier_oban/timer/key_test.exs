defmodule StatifierOban.Timer.KeyTest do
  use ExUnit.Case, async: true

  alias Statifier.Effect.{Cancel, SendDelayed}
  alias StatifierOban.Timer.{CancellationKey, DedupKey, Key}

  defp send_delayed(overrides \\ %{}) do
    struct!(
      %SendDelayed{
        event: "timer.fired",
        target: nil,
        type: nil,
        data: nil,
        send_id: "send_1",
        delay_ms: 1_000,
        c_index: 3,
        owner: {:onentry, 0, 0},
        macrostep: 1,
        microstep: 2,
        round: 0,
        ordinal: 1,
        id_from_author?: false
      },
      overrides
    )
  end

  defp cancel(overrides \\ %{}) do
    struct!(
      %Cancel{
        send_id: "send_1",
        c_index: 9,
        owner: {:transition, 4},
        macrostep: 7,
        microstep: 8,
        round: 1,
        ordinal: 2
      },
      overrides
    )
  end

  describe "dedup_key/2" do
    # sabotage: hardcoded `ordinal: 1` in the `%DedupKey{}` build in
    # `Key.dedup_key/2` - test went red (ordinal 7 came back as 1), reverted.
    test "copies scope and ordinal off the SendDelayed (compact form)" do
      assert {:ok, %DedupKey{scope: "run-1", ordinal: 7}} =
               Key.dedup_key("run-1", send_delayed(%{ordinal: 7}))
    end

    # sabotage: bound `macrostep: m` in `dedup_key/2`'s head and changed the
    # `%DedupKey{}` build to `ordinal: ordinal + m` (folding a position
    # field into the key) - test went red, reverted.
    test "send_id and position fields are row data, not key components" do
      base = send_delayed()

      moved =
        send_delayed(%{
          send_id: "send_99",
          macrostep: 99,
          microstep: 99,
          round: 99,
          c_index: nil,
          owner: nil,
          id_from_author?: true
        })

      assert Key.dedup_key("run-1", base) == Key.dedup_key("run-1", moved)
    end

    # sabotage: changed `validated_ordinal/1`'s fallback clause to
    # `defp validated_ordinal(_ordinal), do: {:ok, 1}` - test went red,
    # reverted.
    test "returns missing_ordinal when ordinal is nil or not a positive integer" do
      for bad_ordinal <- [nil, 0, -1, "1"] do
        assert {:error, :missing_ordinal} =
                 Key.dedup_key("run-1", send_delayed(%{ordinal: bad_ordinal}))
      end
    end

    # sabotage: changed `validated_scope(_scope)` fallback clause to
    # `defp validated_scope(_scope), do: {:ok, "default"}` - test went red
    # (nil/"" no longer errored), reverted.
    test "returns invalid_scope for nil, empty, and non-binary scopes" do
      for bad_scope <- [nil, "", 123, :atom_scope] do
        assert {:error, :invalid_scope} = Key.dedup_key(bad_scope, send_delayed())
      end
    end

    # sabotage: added `System.unique_integer([:positive])` to the
    # `ordinal` written into `%DedupKey{}` - repeated calls stopped
    # matching, test went red, reverted.
    test "is deterministic across repeated calls with equal inputs" do
      effect = send_delayed()
      assert Key.dedup_key("run-1", effect) == Key.dedup_key("run-1", effect)
    end
  end

  describe "cancellation_key/2" do
    # sabotage: changed the SendDelayed clause of cancellation_key/2 to read
    # `send_id <> "!"` instead of `send_id` - test went red, reverted.
    test "SendDelayed and matching Cancel produce equal keys" do
      assert Key.cancellation_key("run-1", send_delayed(%{send_id: "send_1"})) ==
               Key.cancellation_key("run-1", cancel(%{send_id: "send_1"}))
    end

    # sabotage: folded `macrostep` into the cancellation key's `send_id`
    # (`send_id <> Integer.to_string(m)`) - test went red, reverted.
    test "ignores macrostep, microstep, round, c_index, owner, and ordinal" do
      effect =
        send_delayed(%{
          macrostep: 99,
          microstep: 99,
          round: 99,
          c_index: 99,
          owner: {:onexit, 5, 5},
          ordinal: 99
        })

      assert {:ok, %CancellationKey{scope: "run-1", send_id: "send_1"}} =
               Key.cancellation_key("run-1", effect)
    end

    # sabotage: changed the `validated_scope(_scope)` fallback to
    # `{:ok, "default"}` - test went red, reverted.
    test "returns invalid_scope for nil, empty, and non-binary scopes" do
      for bad_scope <- [nil, "", 123, %{}] do
        assert {:error, :invalid_scope} = Key.cancellation_key(bad_scope, send_delayed())
        assert {:error, :invalid_scope} = Key.cancellation_key(bad_scope, cancel())
      end
    end

    # sabotage: changed `validated_send_id(nil)` to `{:ok, "unknown"}` -
    # test went red, reverted.
    test "returns missing_send_id when SendDelayed.send_id is nil" do
      assert {:error, :missing_send_id} =
               Key.cancellation_key("run-1", send_delayed(%{send_id: nil}))
    end

    # sabotage: appended `<> Integer.to_string(System.unique_integer())` to
    # the `send_id` written into `%CancellationKey{}` - repeated calls
    # stopped matching, test went red, reverted.
    test "is deterministic across repeated calls with equal inputs" do
      effect = cancel()
      assert Key.cancellation_key("run-1", effect) == Key.cancellation_key("run-1", effect)
    end
  end

  describe "cancels?/3" do
    # sabotage: collapsed `cancels?/3` to a single
    # `def cancels?(%CancellationKey{}, _scope, %SendDelayed{}), do: false`
    # clause - test went red, reverted.
    test "true when scope and send_id match regardless of position and ordinal" do
      {:ok, cancellation_key} = Key.cancellation_key("run-1", cancel(%{send_id: "send_1"}))

      stored_effect =
        send_delayed(%{
          send_id: "send_1",
          macrostep: 42,
          microstep: 42,
          round: 42,
          c_index: 42,
          owner: {:finalize, 1, 1},
          ordinal: 42
        })

      assert Key.cancels?(cancellation_key, "run-1", stored_effect)
    end

    # sabotage: dropped the scope equality from `cancels?/3`'s matching
    # clause (bound the key's scope and the scope argument to different
    # variables) - test went red, reverted.
    test "false when scope differs" do
      {:ok, cancellation_key} = Key.cancellation_key("run-1", cancel(%{send_id: "send_1"}))

      refute Key.cancels?(cancellation_key, "run-2", send_delayed(%{send_id: "send_1"}))
    end

    # sabotage: dropped the send_id equality from `cancels?/3`'s matching
    # clause (bound the key's send_id and the effect's send_id to different
    # variables) - test went red, reverted.
    test "false when send_id differs" do
      {:ok, cancellation_key} = Key.cancellation_key("run-1", cancel(%{send_id: "send_1"}))

      refute Key.cancels?(cancellation_key, "run-1", send_delayed(%{send_id: "send_2"}))
    end
  end
end
