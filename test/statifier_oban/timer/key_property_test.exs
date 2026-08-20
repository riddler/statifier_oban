defmodule StatifierOban.Timer.KeyPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import StatifierOban.EffectGenerators

  alias Statifier.Effect.SendDelayed
  alias StatifierOban.Timer.Key

  # Sabotage: changed `build_cancellation_key/2` to append
  # `:erlang.unique_integer()` to `send_id` before building the key - both
  # properties went red (two derivations of the same input stopped
  # matching), reverted. Verified for real.
  describe "determinism" do
    property "two derivations of the same scope and effect are equal" do
      check all(scope <- scope(), effect <- one_of([send_delayed(), cancel()])) do
        assert Key.cancellation_key(scope, effect) == Key.cancellation_key(scope, effect)
      end
    end

    property "two structurally equal SendDelayed effects give equal dedup keys" do
      check all(scope <- scope(), effect <- send_delayed()) do
        rebuilt = struct!(SendDelayed, Map.from_struct(effect))
        assert Key.dedup_key(scope, effect) == Key.dedup_key(scope, rebuilt)
      end
    end
  end

  # Sabotage: changed the `validated_scope/1` success clause to return
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

  # Sabotage: changed `c_index: send_delayed.c_index` to `c_index: 0`
  # (hardcoded) in the `%DedupKey{}` build in `Key.dedup_key/2` - the
  # c_index-only-diff property went red (two effects differing only in
  # c_index produced equal keys), reverted. Verified for real.
  describe "dedup key injectivity" do
    property "equal dedup keys under one scope imply all seven components are equal" do
      check all(scope <- scope(), a <- send_delayed(), b <- send_delayed()) do
        {:ok, key_a} = Key.dedup_key(scope, a)
        {:ok, key_b} = Key.dedup_key(scope, b)

        components_equal? =
          a.send_id == b.send_id and a.macrostep == b.macrostep and
            a.microstep == b.microstep and a.round == b.round and
            a.c_index == b.c_index and a.owner == b.owner

        assert key_a == key_b == components_equal?
      end
    end

    property "two sends sharing every component but c_index produce distinct dedup keys" do
      check all(
              scope <- scope(),
              base <- send_delayed(),
              c_index_a <- counter(),
              c_index_b <- counter(),
              c_index_a != c_index_b
            ) do
        effect_a = %{base | c_index: c_index_a}
        effect_b = %{base | c_index: c_index_b}

        assert Key.dedup_key(scope, effect_a) != Key.dedup_key(scope, effect_b)
      end
    end

    property "two sends sharing every component but owner produce distinct dedup keys" do
      check all(
              scope <- scope(),
              base <- send_delayed(),
              owner_a <- owner(),
              owner_b <- owner(),
              owner_a != owner_b
            ) do
        effect_a = %{base | owner: owner_a}
        effect_b = %{base | owner: owner_b}

        assert Key.dedup_key(scope, effect_a) != Key.dedup_key(scope, effect_b)
      end
    end
  end

  # Sabotage: changed `cancellation_key/2`'s `SendDelayed` clause to fold
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

        {:ok, dedup_key_a} = Key.dedup_key(scope, effect_a)
        {:ok, dedup_key_b} = Key.dedup_key(scope, effect_b)

        assert Key.cancels?(cancellation_key_a, dedup_key_a)
        assert Key.cancels?(cancellation_key_b, dedup_key_b)
      end
    end
  end

  # Sabotage: changed `cancellation_key/2`'s `Cancel` clause to read
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

  # Sabotage: changed `validated_scope/1`'s fallback clause to
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

  # Residual collision, stated honestly (ADR-0054): an author-written `id`
  # on a `<send delay="...">` inside a `<foreach>` body is reused verbatim
  # across iterations, so replaying the same static c_index/owner/microstep
  # with the same author id collapses to one dedup key. The documented
  # workaround is to omit the hand-written `id` so a library-generated id
  # advances `send_counter` per execution and the key stays unique.
  #
  # Sabotage: changed `dedup_key/2`'s `%DedupKey{}` build to store
  # `send_id <> Integer.to_string(System.unique_integer())` instead of
  # `send_id` - the same-struct-replayed property went red (two
  # derivations of one struct stopped matching), reverted. Verified for
  # real.
  describe "<foreach> residual, characterized" do
    property "replaying the same author-id SendDelayed struct yields identical dedup keys" do
      check all(scope <- scope(), effect <- send_delayed()) do
        author_effect = %{effect | id_from_author?: true}
        assert Key.dedup_key(scope, author_effect) == Key.dedup_key(scope, author_effect)
      end
    end

    property "the same effect with distinct generated ids yields distinct dedup keys" do
      check all(
              scope <- scope(),
              effect <- send_delayed(),
              send_id_a <- send_id(),
              send_id_b <- send_id(),
              send_id_a != send_id_b
            ) do
        effect_a = %{effect | send_id: send_id_a, id_from_author?: false}
        effect_b = %{effect | send_id: send_id_b, id_from_author?: false}

        assert Key.dedup_key(scope, effect_a) != Key.dedup_key(scope, effect_b)
      end
    end
  end
end
