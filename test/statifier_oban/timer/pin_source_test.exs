defmodule StatifierOban.Timer.PinSourceTest do
  # Not async: every test shares the one SQLite repo and its oban_jobs
  # table (ADR-0002 harness). Tests isolate on per-test execution ids.
  use ExUnit.Case, async: false

  alias Statifier.Effect.SendDelayed
  alias StatifierOban.{Config, Timer}
  alias StatifierPersistence.PinSource

  @oban_name StatifierOban.PinSourceTestOban
  @detached_oban_name StatifierOban.PinSourceTestDetachedOban

  defmodule DetachedRepo do
    @moduledoc false
    # A second repo, started and then stopped inside one test, so the
    # Oban instance over it is running while its repo cannot answer.
    use Ecto.Repo, otp_app: :statifier_oban, adapter: Ecto.Adapters.SQLite3
  end

  defmodule HoldHost do
    @moduledoc false
    # The host: a library whose hold charts wait on a pickup timer.
    use StatifierOban.Timer.PinSource, config: {__MODULE__, :oban_config}

    def oban_config do
      {:ok, config} =
        Config.new(oban: StatifierOban.PinSourceTestOban, timers_queue: "pin_source_test")

      config
    end
  end

  defmodule DetachedHost do
    @moduledoc false
    use StatifierOban.Timer.PinSource, config: {__MODULE__, :oban_config}

    def oban_config do
      {:ok, config} =
        Config.new(
          oban: StatifierOban.PinSourceTestDetachedOban,
          timers_queue: "pin_source_test"
        )

      config
    end
  end

  defmodule StoppedHost do
    @moduledoc false
    use StatifierOban.Timer.PinSource, config: {__MODULE__, :oban_config}

    def oban_config do
      {:ok, config} =
        Config.new(oban: StatifierOban.PinSourceTestNotStarted, timers_queue: "pin_source_test")

      config
    end
  end

  setup context do
    start_supervised!(Statifier.Supervisor)

    start_supervised!(
      {Oban,
       name: @oban_name, repo: StatifierOban.TestRepo, engine: Oban.Engines.Lite, testing: :manual}
    )

    %{
      config: HoldHost.oban_config(),
      hold_a: "hold_#{context.line}_a",
      hold_b: "hold_#{context.line}_b",
      hold_c: "hold_#{context.line}_c"
    }
  end

  describe "pins/2" do
    # sabotage: the injected `Map.values() |> Enum.sum()` was replaced with
    # `map_size()` - went red: the answer was 2 (one per execution asked
    # about) instead of 3 pending timers. Reverted.
    test "counts the timers pending under the given execution ids",
         %{config: config, hold_a: hold_a, hold_b: hold_b, hold_c: hold_c} do
      assert {:ok, _job} = Timer.schedule(config, hold_a, pickup_expired(1))
      assert {:ok, _job} = Timer.schedule(config, hold_a, pickup_expired(2))
      assert {:ok, _job} = Timer.schedule(config, hold_b, pickup_expired(1))
      # Pending, but under an execution the source is not asked about.
      assert {:ok, _job} = Timer.schedule(config, hold_c, pickup_expired(1))

      assert HoldHost.pins("chart-hash", %{execution_ids: [hold_a, hold_b]}) == %{timers: 3}
    end

    # sabotage: the injected sum was replaced with `length(execution_ids)` -
    # went red: two executions with nothing pending answered 2, not 0.
    # Reverted.
    test "answers zero for executions with nothing pending, and for none",
         %{config: config, hold_a: hold_a, hold_b: hold_b, hold_c: hold_c} do
      assert {:ok, _job} = Timer.schedule(config, hold_c, pickup_expired(1))

      assert HoldHost.pins("chart-hash", %{execution_ids: [hold_a, hold_b]}) == %{timers: 0}
      assert HoldHost.pins("chart-hash", %{execution_ids: []}) == %{timers: 0}
    end

    # sabotage: the injected body was wrapped in `rescue _ -> %{timers: 0}` -
    # went red: the detached repo's call answered a zero instead of
    # raising. Reverted.
    test "raises, rather than answering zero, when the count cannot be taken",
         %{hold_a: hold_a} do
      detached_db = Path.join(Mix.Project.build_path(), "pin_source_detached.db")
      for file <- Path.wildcard(detached_db <> "*"), do: File.rm!(file)
      start_supervised!({DetachedRepo, database: detached_db, pool_size: 1, log: false})
      # Oban refuses to start over a repo without its tables.
      Ecto.Migrator.up(DetachedRepo, 1, StatifierOban.TestMigration, log: false)

      start_supervised!(
        {Oban,
         name: @detached_oban_name,
         repo: DetachedRepo,
         engine: Oban.Engines.Lite,
         testing: :manual}
      )

      :ok = stop_supervised!(DetachedRepo)

      assert_raise RuntimeError, ~r/could not lookup Ecto repo/, fn ->
        DetachedHost.pins("chart-hash", %{execution_ids: [hold_a]})
      end

      assert_raise RuntimeError, ~r/No Oban instance named/, fn ->
        StoppedHost.pins("chart-hash", %{execution_ids: [hold_a]})
      end
    end
  end

  describe "through StatifierPersistence.PinSource.collect/3" do
    # sabotage: the injected answer's key was changed from `:timers` to
    # `"timers"` - went red: collect/3 answered
    # `{:error, {HoldHost, {:invalid_return, _}}}` (the two counting tests
    # above went red too). Reverted.
    test "the same answer comes back under the host's module",
         %{config: config, hold_a: hold_a, hold_b: hold_b} do
      assert {:ok, _job} = Timer.schedule(config, hold_a, pickup_expired(1))

      context = %{execution_ids: [hold_a, hold_b]}
      direct = HoldHost.pins("chart-hash", context)

      assert direct == %{timers: 1}
      assert PinSource.collect([HoldHost], "chart-hash", context) == {:ok, %{HoldHost => direct}}
      # The content hash is unused: another hash, the same answer.
      assert PinSource.collect([HoldHost], "other-hash", context) == {:ok, %{HoldHost => direct}}
    end

    # sabotage: covered by the rescue mutation above - with the rescue in
    # place collect/3 answered `{:ok, %{StoppedHost => %{timers: 0}}}`
    # and this went red too. Reverted.
    test "a source that cannot count is a refusal naming the host's module",
         %{hold_a: hold_a} do
      assert {:error, {StoppedHost, {:raised, %RuntimeError{}}}} =
               PinSource.collect([StoppedHost], "chart-hash", %{execution_ids: [hold_a]})
    end
  end

  describe "use StatifierOban.Timer.PinSource" do
    # sabotage: both `raise` sites in `config!/2` were replaced with
    # `{nil, nil}` - went red: the malformed definition compiled instead
    # of raising. Reverted.
    test "refuses at compile time a config that is not {module, function}" do
      for opts <- ["[]", "[config: :oban_config]"] do
        assert_raise ArgumentError, ~r/expects config: \{module, function\}/, fn ->
          Code.compile_string("""
          defmodule StatifierOban.Timer.PinSourceTest.Malformed#{:erlang.unique_integer([:positive])} do
            use StatifierOban.Timer.PinSource, #{opts}
          end
          """)
        end
      end
    end
  end

  # The library hold's pickup timer: scheduled when the copy becomes
  # available, fired if the patron never collects it.
  defp pickup_expired(ordinal) do
    %SendDelayed{
      event: "pickup.expired",
      target: nil,
      type: nil,
      data: nil,
      send_id: "pickup_#{ordinal}",
      delay_ms: 60_000,
      c_index: 0,
      owner: {:onentry, 0, 0},
      macrostep: 1,
      microstep: 0,
      round: 1,
      ordinal: ordinal,
      id_from_author?: false,
      caller_context: nil
    }
  end
end
