defmodule StatifierOban.TimerTest do
  # Not async: every test shares the one SQLite repo and its oban_jobs
  # table (ADR-0002 harness). Tests isolate on per-test scopes and queues.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Statifier.Effect.SendDelayed
  alias StatifierOban.{Config, TestRepo, Timer}
  alias StatifierOban.Timer.JobArgs

  @oban_name StatifierOban.TimerTestOban

  setup context do
    start_supervised!(
      {Oban, name: @oban_name, repo: TestRepo, engine: Oban.Engines.Lite, testing: :manual}
    )

    # Uniqueness ignores the queue on purpose (see Worker), so isolation
    # between tests comes from per-test scopes; the per-test queue only
    # keeps counting and draining local to a test.
    queue = "timer_test_#{context.line}"
    {:ok, config} = Config.new(oban: @oban_name, timers_queue: queue)

    %{
      config: config,
      queue: queue,
      scope_a: "run_#{context.line}_a",
      scope_b: "run_#{context.line}_b"
    }
  end

  # sabotage: dropped `keys: [:scope, :ordinal]` down to `keys: [:scope]`
  # in Worker's unique options - the distinct-ordinals test went red (the
  # second insert conflicted); dropping uniqueness entirely turned
  # `conflict?` false here and two rows appeared - both reverted.
  test "one job per dedup key: a duplicate insert is a no-op", %{
    config: config,
    queue: queue,
    scope_a: scope_a
  } do
    effect = send_delayed_fixture()

    assert {:ok, %Oban.Job{id: id, conflict?: false}} =
             Timer.schedule(config, scope_a, effect)

    assert {:ok, %Oban.Job{id: ^id, conflict?: true}} =
             Timer.schedule(config, scope_a, effect)

    assert job_count(queue) == 1
  end

  # sabotage: covered by the keys-narrowing mutation above (keys: [:scope]
  # made this test's second insert a conflict) - went red, reverted.
  test "distinct ordinals are distinct jobs, same send_id and position",
       %{config: config, queue: queue, scope_a: scope_a} do
    effect = send_delayed_fixture()

    assert {:ok, %Oban.Job{conflict?: false}} = Timer.schedule(config, scope_a, effect)

    assert {:ok, %Oban.Job{conflict?: false}} =
             Timer.schedule(config, scope_a, %{effect | ordinal: effect.ordinal + 1})

    assert job_count(queue) == 2
  end

  # sabotage: same-scope hardcoding is already covered by Key's own tests;
  # here the scope was dropped from the args ("scope" => "fixed") - went
  # red (the two scopes collapsed into one conflicting job), reverted.
  test "the same effect under two scopes is two jobs",
       %{config: config, queue: queue, scope_a: scope_a, scope_b: scope_b} do
    effect = send_delayed_fixture()

    assert {:ok, %Oban.Job{conflict?: false}} = Timer.schedule(config, scope_a, effect)
    assert {:ok, %Oban.Job{conflict?: false}} = Timer.schedule(config, scope_b, effect)

    assert job_count(queue) == 2
  end

  # sabotage: scheduled_at computed with `effect.delay_ms * 0` - went red
  # (fire time collapsed to now), reverted.
  test "delay_ms is relative: the fire time is computed at insert", %{
    config: config,
    scope_a: scope_a
  } do
    effect = %{send_delayed_fixture() | delay_ms: 3_600_000}

    lower = DateTime.add(DateTime.utc_now(), 3_599, :second)
    assert {:ok, %Oban.Job{scheduled_at: scheduled_at}} = Timer.schedule(config, scope_a, effect)
    upper = DateTime.add(DateTime.utc_now(), 3_601, :second)

    assert DateTime.compare(scheduled_at, lower) == :gt
    assert DateTime.compare(scheduled_at, upper) == :lt
  end

  # sabotage: the schedule head's `target: nil` pattern was relaxed to any
  # target - went red (a #_parent send got scheduled), reverted.
  test "a non-nil target is refused, per st-ADR-0055", %{
    config: config,
    queue: queue,
    scope_a: scope_a
  } do
    effect = %{send_delayed_fixture() | target: "#_parent"}

    assert {:error, {:non_self_target, "#_parent"}} = Timer.schedule(config, scope_a, effect)
    assert job_count(queue) == 0
  end

  # sabotage: Timer.schedule/3 skipped Key.dedup_key validation - went red
  # (the empty scope inserted a job), reverted.
  test "an invalid scope is the key's typed error, nothing inserted",
       %{config: config, queue: queue} do
    assert {:error, :invalid_scope} = Timer.schedule(config, "", send_delayed_fixture())
    assert job_count(queue) == 0
  end

  # sabotage: from_effect/2 stored "ordinal" => 1 unconditionally - went
  # red here (the rebuilt effect stopped matching), reverted.
  test "the stored job rebuilds the effect and its position", %{config: config, scope_a: scope_a} do
    effect = %{
      send_delayed_fixture()
      | data: {:host, "payload"},
        owner: {:transition, 9},
        caller_context: {:trace, 42}
    }

    assert {:ok, %Oban.Job{id: id}} = Timer.schedule(config, scope_a, effect)

    # Read the row back from the store, exactly as a fired job would see it.
    %Oban.Job{args: args} = TestRepo.get!(Oban.Job, id)

    assert {:ok, ^scope_a, ^effect} = JobArgs.to_effect(args)
  end

  # sabotage: Worker.perform/1 success clause returned :ok - went red
  # (drain reported success: 1, cancelled: 0), reverted.
  test "a fired job cancels awaiting sob-2hx.5's delivery; replay stays a no-op",
       %{config: config, queue: queue, scope_a: scope_a} do
    effect = %{send_delayed_fixture() | delay_ms: 0}

    assert {:ok, %Oban.Job{id: id, conflict?: false}} = Timer.schedule(config, scope_a, effect)

    assert %{cancelled: 1, discard: 0, failure: 0, success: 0} =
             Oban.drain_queue(@oban_name, queue: queue, with_scheduled: true)

    # At-least-once: re-executing the drive after the job already ran (or
    # was cancelled) must still be a no-op - the unique window spans every
    # job state over an infinite period.
    assert {:ok, %Oban.Job{id: ^id, conflict?: true}} = Timer.schedule(config, scope_a, effect)
    assert job_count(queue) == 1
  end

  defp job_count(queue) do
    TestRepo.aggregate(from(j in Oban.Job, where: j.queue == ^queue), :count)
  end

  defp send_delayed_fixture do
    %SendDelayed{
      event: "reminder",
      target: nil,
      type: nil,
      data: nil,
      send_id: "send_1",
      delay_ms: 60_000,
      c_index: 0,
      owner: {:onentry, 0, 0},
      macrostep: 1,
      microstep: 0,
      round: 1,
      ordinal: 1,
      id_from_author?: false,
      caller_context: nil
    }
  end
end
