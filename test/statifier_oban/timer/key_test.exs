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
        round: 1
      },
      overrides
    )
  end

  describe "dedup_key/2" do
    # Sabotage: dropped `c_index: send_delayed.c_index` from the struct build
    # (left c_index unset) - test went red, reverted.
    test "copies all seven components off a fully populated SendDelayed" do
      assert {:ok,
              %DedupKey{
                scope: "run-1",
                send_id: "send_1",
                macrostep: 1,
                microstep: 2,
                round: 0,
                c_index: 3,
                owner: {:onentry, 0, 0}
              }} = Key.dedup_key("run-1", send_delayed())
    end

    # Sabotage: changed `c_index: send_delayed.c_index` to
    # `c_index: send_delayed.c_index || 0` (substituting a default) - test
    # went red, reverted.
    test "preserves nil c_index and owner verbatim rather than defaulting" do
      assert {:ok, %DedupKey{c_index: nil, owner: nil}} =
               Key.dedup_key("run-1", send_delayed(%{c_index: nil, owner: nil}))
    end

    # Sabotage: changed `validated_send_id(nil)` clause to
    # `defp validated_send_id(_send_id), do: {:ok, "unknown"}` - test went
    # red, reverted.
    test "returns missing_send_id when SendDelayed.send_id is nil" do
      assert {:error, :missing_send_id} = Key.dedup_key("run-1", send_delayed(%{send_id: nil}))
    end

    # Sabotage: changed `validated_scope(_scope)` fallback clause to
    # `defp validated_scope(_scope), do: {:ok, "default"}` - test went red
    # (nil/"" no longer errored), reverted.
    test "returns invalid_scope for nil, empty, and non-binary scopes" do
      for bad_scope <- [nil, "", 123, :atom_scope] do
        assert {:error, :invalid_scope} = Key.dedup_key(bad_scope, send_delayed())
      end
    end

    test "is deterministic across repeated calls with equal inputs" do
      effect = send_delayed()
      assert Key.dedup_key("run-1", effect) == Key.dedup_key("run-1", effect)
    end
  end

  describe "cancellation_key/2" do
    # Sabotage: changed the SendDelayed clause of cancellation_key/2 to read
    # `send_id <> "!"` instead of `send_id` - test went red, reverted.
    test "SendDelayed and matching Cancel produce equal keys" do
      assert Key.cancellation_key("run-1", send_delayed(%{send_id: "send_1"})) ==
               Key.cancellation_key("run-1", cancel(%{send_id: "send_1"}))
    end

    test "ignores macrostep, microstep, round, c_index, and owner" do
      effect =
        send_delayed(%{
          macrostep: 99,
          microstep: 99,
          round: 99,
          c_index: 99,
          owner: {:onexit, 5, 5}
        })

      assert {:ok, %CancellationKey{scope: "run-1", send_id: "send_1"}} =
               Key.cancellation_key("run-1", effect)
    end

    test "returns invalid_scope for nil, empty, and non-binary scopes" do
      for bad_scope <- [nil, "", 123, %{}] do
        assert {:error, :invalid_scope} = Key.cancellation_key(bad_scope, send_delayed())
        assert {:error, :invalid_scope} = Key.cancellation_key(bad_scope, cancel())
      end
    end

    test "returns missing_send_id when SendDelayed.send_id is nil" do
      assert {:error, :missing_send_id} =
               Key.cancellation_key("run-1", send_delayed(%{send_id: nil}))
    end

    test "is deterministic across repeated calls with equal inputs" do
      effect = cancel()
      assert Key.cancellation_key("run-1", effect) == Key.cancellation_key("run-1", effect)
    end
  end

  describe "cancels?/2" do
    # Sabotage: changed the matching clause's second argument pattern from
    # `%DedupKey{scope: scope, send_id: send_id}` to
    # `%DedupKey{scope: scope, send_id: _send_id}` (dropping the send_id
    # equality constraint) - test asserting false-on-differing-send_id went
    # red, reverted.
    test "true when scope and send_id match regardless of position fields" do
      {:ok, cancellation_key} = Key.cancellation_key("run-1", cancel(%{send_id: "send_1"}))

      {:ok, dedup_key} =
        Key.dedup_key(
          "run-1",
          send_delayed(%{
            send_id: "send_1",
            macrostep: 42,
            microstep: 42,
            round: 42,
            c_index: 42,
            owner: {:finalize, 1, 1}
          })
        )

      assert Key.cancels?(cancellation_key, dedup_key)
    end

    test "false when scope differs" do
      {:ok, cancellation_key} = Key.cancellation_key("run-1", cancel(%{send_id: "send_1"}))
      {:ok, dedup_key} = Key.dedup_key("run-2", send_delayed(%{send_id: "send_1"}))

      refute Key.cancels?(cancellation_key, dedup_key)
    end

    test "false when send_id differs" do
      {:ok, cancellation_key} = Key.cancellation_key("run-1", cancel(%{send_id: "send_1"}))
      {:ok, dedup_key} = Key.dedup_key("run-1", send_delayed(%{send_id: "send_2"}))

      refute Key.cancels?(cancellation_key, dedup_key)
    end
  end
end
