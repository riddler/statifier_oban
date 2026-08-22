defmodule StatifierOban.TimerTest do
  # Not async: every test shares the one SQLite repo and its oban_jobs
  # table (ADR-0002 harness). Tests isolate on per-test scopes and queues.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Statifier.Effect.{Cancel, SendDelayed}
  alias StatifierOban.{Config, TestRepo, Timer}
  alias StatifierOban.Timer.JobArgs

  @oban_name StatifierOban.TimerTestOban

  setup context do
    # The session runtime backs the default delivery's liveness check: a
    # fired job here has no session under its scope, so it discards
    # rather than erroring on a missing registry.
    start_supervised!(Statifier.Supervisor)

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

  # sabotage: Worker.perform/1's {:discarded, _} clause returned :ok -
  # went red (drain reported success: 1, cancelled: 0), reverted.
  # No session runs under this scope, so the fired job discards through
  # the run-liveness check (delivery itself is WorkerTest's ground).
  test "a fired job with no live run discards; replay stays a no-op",
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

  # sabotage: dropped the send_id where clause from timer_jobs - went red
  # (the other send_id's job got cancelled too), reverted.
  test "one cancel cancels every job under its send_id, and only those",
       %{config: config, scope_a: scope_a} do
    effect = send_delayed_fixture()
    twin = %{effect | ordinal: effect.ordinal + 1}
    other = %{effect | send_id: "send_2", ordinal: effect.ordinal + 2}

    assert {:ok, %Oban.Job{id: id_a}} = Timer.schedule(config, scope_a, effect)
    assert {:ok, %Oban.Job{id: id_b}} = Timer.schedule(config, scope_a, twin)
    assert {:ok, %Oban.Job{id: id_c}} = Timer.schedule(config, scope_a, other)

    assert {:ok, 2} = Timer.cancel(config, scope_a, cancel_fixture())

    assert %Oban.Job{state: "cancelled"} = TestRepo.get!(Oban.Job, id_a)
    assert %Oban.Job{state: "cancelled"} = TestRepo.get!(Oban.Job, id_b)
    assert %Oban.Job{state: "scheduled"} = TestRepo.get!(Oban.Job, id_c)
  end

  # sabotage: cancel/3 hardcoded {:ok, 1} over the engine's count - went
  # red here (and in the racing test below), reverted.
  test "a cancel matching nothing is a no-op, not an error",
       %{config: config, scope_a: scope_a} do
    assert {:ok, 0} = Timer.cancel(config, scope_a, cancel_fixture())
  end

  # sabotage: the scope where clause was dropped from timer_jobs - went red
  # (scope_b's job got cancelled by scope_a's cancel), reverted.
  test "a cancel is scoped: the twin under another scope survives",
       %{config: config, scope_a: scope_a, scope_b: scope_b} do
    effect = send_delayed_fixture()

    assert {:ok, %Oban.Job{id: id_a}} = Timer.schedule(config, scope_a, effect)
    assert {:ok, %Oban.Job{id: id_b}} = Timer.schedule(config, scope_b, effect)

    assert {:ok, 1} = Timer.cancel(config, scope_a, cancel_fixture())

    assert %Oban.Job{state: "cancelled"} = TestRepo.get!(Oban.Job, id_a)
    assert %Oban.Job{state: "scheduled"} = TestRepo.get!(Oban.Job, id_b)
  end

  # sabotage: cancel/3 skipped Key.cancellation_key and built the key
  # struct directly - went red (the empty scope returned {:ok, 0} instead
  # of the typed error), reverted.
  test "an invalid scope is the key's typed error", %{config: config} do
    assert {:error, :invalid_scope} = Timer.cancel(config, "", cancel_fixture())
  end

  # sabotage: covered by the hardcoded-{:ok, 1} mutation above - went red
  # here too, reverted. The terminal-state exclusion itself is Oban's
  # engine, exercised through cancel/3's {:ok, 0} and the unchanged row.
  test "a cancel racing execution: an already-run job stays run",
       %{config: config, queue: queue, scope_a: scope_a} do
    effect = %{send_delayed_fixture() | delay_ms: 0}

    assert {:ok, %Oban.Job{id: id}} = Timer.schedule(config, scope_a, effect)

    # The job executes (discarding through the run-liveness check, since
    # no session runs under this scope); either way it is in a terminal
    # state when the cancel lands.
    assert %{cancelled: 1} = Oban.drain_queue(@oban_name, queue: queue, with_scheduled: true)
    %Oban.Job{state: terminal_state} = TestRepo.get!(Oban.Job, id)

    # The late cancel matches nothing: terminal states are past cancelling.
    assert {:ok, 0} = Timer.cancel(config, scope_a, cancel_fixture())
    assert %Oban.Job{state: ^terminal_state} = TestRepo.get!(Oban.Job, id)
  end

  defp cancel_fixture do
    %Cancel{
      send_id: "send_1",
      c_index: 1,
      owner: {:onexit, 0, 0},
      macrostep: 2,
      microstep: 0,
      round: 1,
      ordinal: 5,
      caller_context: nil
    }
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
