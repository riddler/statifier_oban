defmodule StatifierOban.Timer.KeyPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import StatifierOban.EffectGenerators

  alias Statifier.Effect.SendDelayed
  alias StatifierOban.Timer.Key

  describe "determinism" do
    # sabotage: changed `build_cancellation_key/2` to append
    # `:erlang.unique_integer()` to `send_id` before building the key - the
    # property went red (two derivations of the same input stopped
    # matching), reverted. Verified for real.
    property "two derivations of the same scope and effect are equal" do
      check all(scope <- scope(), effect <- one_of([send_delayed(), cancel()])) do
        assert Key.cancellation_key(scope, effect) == Key.cancellation_key(scope, effect)
      end
    end

    # sabotage: added `System.unique_integer([:positive])` to the `ordinal`
    # written into `%DedupKey{}` in `Key.dedup_key/2` - property went red
    # (two derivations of one struct stopped matching), reverted.
    property "two structurally equal SendDelayed effects give equal dedup keys" do
      check all(scope <- scope(), effect <- send_delayed()) do
        rebuilt = struct!(SendDelayed, Map.from_struct(effect))
        assert Key.dedup_key(scope, effect) == Key.dedup_key(scope, rebuilt)
      end
    end
  end

  # sabotage: changed the `validated_scope/1` success clause to return
  # `{:ok, "fixed"}` instead of `{:ok, scope}` - property went red (two
  # distinct scopes produced equal dedup keys), reverted. Verified for real.
  describe "scope separates runs" do
    property "distinct scopes never produce equal dedup or cancellation keys for the same send" do
      check all(
              scope_a <- scope(),
              scope_b <- scope(),
              scope_a != scope_b,
              effect <- send_delayed()
            ) do
        assert Key.dedup_key(scope_a, effect) != Key.dedup_key(scope_b, effect)
        assert Key.cancellation_key(scope_a, effect) != Key.cancellation_key(scope_b, effect)
      end
    end
  end

  # The compact dedup key ADR-0059 decision 3 blesses: `{scope, ordinal}`,
  # unique on its own because upstream's `timer_counter` is session-global
  # and monotone. Everything else on the effect is row data.
  describe "dedup key rides on the ordinal" do
    # sabotage: hardcoded `ordinal: 1` in `dedup_key/2`'s `%DedupKey{}`
    # build - property went red (two effects differing only in ordinal
    # produced equal keys), reverted.
    property "equal dedup keys under one scope imply equal ordinals" do
      check all(scope <- scope(), a <- send_delayed(), b <- send_delayed()) do
        {:ok, key_a} = Key.dedup_key(scope, a)
        {:ok, key_b} = Key.dedup_key(scope, b)

        assert key_a == key_b == (a.ordinal == b.ordinal)
      end
    end

    # sabotage: hardcoded `ordinal: 1` in `dedup_key/2`'s `%DedupKey{}`
    # build - property went red, reverted.
    property "two sends sharing every component but ordinal produce distinct dedup keys" do
      check all(
              scope <- scope(),
              base <- send_delayed(),
              ordinal_a <- ordinal(),
              ordinal_b <- ordinal(),
              ordinal_a != ordinal_b
            ) do
        effect_a = %{base | ordinal: ordinal_a}
        effect_b = %{base | ordinal: ordinal_b}

        assert Key.dedup_key(scope, effect_a) != Key.dedup_key(scope, effect_b)
      end
    end

    # sabotage: bound `macrostep: m` in `dedup_key/2`'s head and changed the
    # `%DedupKey{}` build to `ordinal: ordinal + m` (folding a position
    # field into the key) - property went red, reverted.
    property "send_id and position fields are row data: changing them all keeps the key" do
      check all(
              scope <- scope(),
              base <- send_delayed(),
              send_id <- send_id(),
              macrostep <- counter(),
              microstep <- counter(),
              round <- counter(),
              c_index <- one_of([counter(), constant(nil)]),
              owner <- owner()
            ) do
        moved = %{
          base
          | send_id: send_id,
            macrostep: macrostep,
            microstep: microstep,
            round: round,
            c_index: c_index,
            owner: owner
        }

        assert Key.dedup_key(scope, base) == Key.dedup_key(scope, moved)
      end
    end
  end

  # sabotage: changed `cancellation_key/2`'s `SendDelayed` clause to fold
  # `c_index` into the `send_id` passed to `build_cancellation_key/2`
  # (`"#{send_id}-#{c_index}"`) - the property went red (two effects
  # sharing scope/send_id but differing c_index stopped sharing a
  # cancellation key), reverted. Verified for real.
  describe "cancellation key ignores position" do
    property "effects sharing scope and send_id share a cancellation key that cancels both" do
      check all(
              scope <- scope(),
              send_id <- send_id(),
              a <- send_delayed(),
              b <- send_delayed()
            ) do
        effect_a = %{a | send_id: send_id}
        effect_b = %{b | send_id: send_id}

        {:ok, cancellation_key_a} = Key.cancellation_key(scope, effect_a)
        {:ok, cancellation_key_b} = Key.cancellation_key(scope, effect_b)
        assert cancellation_key_a == cancellation_key_b

        assert Key.cancels?(cancellation_key_a, scope, effect_a)
        assert Key.cancels?(cancellation_key_b, scope, effect_b)
      end
    end
  end

  # sabotage: changed `cancellation_key/2`'s `Cancel` clause to read
  # `send_id <> "!"` instead of `send_id` (mirroring the example test's own
  # sabotage on the `SendDelayed` clause) - the property went red (a
  # SendDelayed and a Cancel sharing a send_id stopped producing equal
  # cancellation keys), reverted. Verified for real.
  describe "Cancel/SendDelayed agreement" do
    property "cancellation key derived from a SendDelayed equals one derived from a matching Cancel" do
      check all(
              scope <- scope(),
              send_delayed_effect <- send_delayed(),
              cancel_effect <- cancel()
            ) do
        matching_cancel = %{cancel_effect | send_id: send_delayed_effect.send_id}

        assert Key.cancellation_key(scope, send_delayed_effect) ==
                 Key.cancellation_key(scope, matching_cancel)
      end
    end
  end

  # sabotage: changed `validated_scope/1`'s fallback clause to
  # `defp validated_scope(_scope), do: {:ok, "default"}` - both properties
  # went red (nil/"" and non-binary scopes stopped erroring), reverted.
  # Verified for real.
  describe "scope is mandatory" do
    property "nil, empty, and generated non-binary scopes always error" do
      non_binary_scope = one_of([constant(nil), constant(""), integer(), atom(:alphanumeric)])

      check all(bad_scope <- non_binary_scope, effect <- one_of([send_delayed(), cancel()])) do
        assert {:error, :invalid_scope} = Key.cancellation_key(bad_scope, effect)
      end
    end

    property "nil, empty, and generated non-binary scopes always error for dedup_key/2" do
      non_binary_scope = one_of([constant(nil), constant(""), integer(), atom(:alphanumeric)])

      check all(bad_scope <- non_binary_scope, effect <- send_delayed()) do
        assert {:error, :invalid_scope} = Key.dedup_key(bad_scope, effect)
      end
    end
  end

  # The retirement this bead exists for. ADR-0054's residual collision -
  # two `<foreach>` iterations of `<send id="x" delay="...">` agreeing on
  # every key component - is closed by ADR-0059: each execution mints a
  # fresh ordinal from a session-global counter, so a hand-written `id`
  # inside a `<foreach>` is fully supported under a durable scheduler. The
  # characterization property that pinned the old seven-component collision
  # is replaced by these assertions of the fix.
  describe "<foreach> iterations are per-instance" do
    # sabotage: hardcoded `ordinal: 1` in `dedup_key/2`'s `%DedupKey{}`
    # build - property went red (the two iterations collided again),
    # reverted.
    property "two iterations sharing an author id and position get distinct dedup keys" do
      check all(
              scope <- scope(),
              effect <- send_delayed(),
              ordinal_a <- ordinal(),
              ordinal_b <- ordinal(),
              ordinal_a != ordinal_b
            ) do
        # Two iterations of one `<foreach>` body: same author id, same
        # content position, same microstep - only the ordinal differs.
        iteration_1 = %{effect | id_from_author?: true, ordinal: ordinal_a}
        iteration_2 = %{effect | id_from_author?: true, ordinal: ordinal_b}

        assert Key.dedup_key(scope, iteration_1) != Key.dedup_key(scope, iteration_2)
      end
    end

    # sabotage: collapsed `cancels?/3` to a single false clause - property
    # went red (the shared-id cancel stopped addressing both rows),
    # reverted.
    property "one cancel under the shared id still addresses every iteration's row" do
      check all(
              scope <- scope(),
              effect <- send_delayed(),
              ordinal_a <- ordinal(),
              ordinal_b <- ordinal(),
              ordinal_a != ordinal_b,
              cancel_effect <- cancel()
            ) do
        iteration_1 = %{effect | id_from_author?: true, ordinal: ordinal_a}
        iteration_2 = %{effect | id_from_author?: true, ordinal: ordinal_b}
        matching_cancel = %{cancel_effect | send_id: effect.send_id}

        {:ok, cancellation_key} = Key.cancellation_key(scope, matching_cancel)

        assert Key.cancels?(cancellation_key, scope, iteration_1)
        assert Key.cancels?(cancellation_key, scope, iteration_2)
      end
    end
  end
end
