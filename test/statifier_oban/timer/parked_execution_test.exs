defmodule StatifierOban.Timer.ParkedExecutionTest do
  # A timer firing into an execution a chart migration parked, through a
  # delivery shaped on the README's durable module: the refusal raises,
  # the job stays retryable, and the attempt after the unpark delivers;
  # or the refusal answers a snooze (ADR-0010), the job is rescheduled
  # with its retries intact, and the first run after the unpark delivers.
  #
  # Not async: shares the one SQLite repo and oban_jobs table (ADR-0002
  # harness) and the named stand-in store.
  use ExUnit.Case, async: false

  alias Statifier.Effect.{Cancel, SendDelayed}
  alias StatifierOban.{Config, ParkedStoreDelivery, TestRepo, Timer}
  alias StatifierOban.Timer.{JobArgs, Worker}

  @oban_name StatifierOban.Timer.ParkedExecutionTestOban

  setup context do
    start_supervised!(
      {Oban, name: @oban_name, repo: TestRepo, engine: Oban.Engines.Lite, testing: :manual}
    )

    start_supervised!({ParkedStoreDelivery, self()})

    queue = "parked_test_#{context.line}"

    {:ok, config} =
      Config.new(oban: @oban_name, timers_queue: queue, delivery: ParkedStoreDelivery)

    %{config: config, queue: queue, scope: "exec_parked_#{context.line}"}
  end

  # sabotage: perform/1 in StatifierOban.Timer.Worker rescued a raise out
  # of deliver/2 as {:cancel, {:discarded, :needs_migration}} - went red
  # (cancelled: 1 instead of failure: 1, the row cancelled, and the
  # attempt after the unpark never ran) - reverted.
  test "a timer firing into a parked execution is retried, then delivered after the unpark",
       %{config: config, queue: queue, scope: scope} do
    ParkedStoreDelivery.put(scope, :needs_migration)
    assert {:ok, %Oban.Job{id: id}} = Timer.schedule(config, scope, fired_fixture())

    assert %{failure: 1, cancelled: 0, discard: 0, success: 0} = drain(queue)

    assert %Oban.Job{state: "retryable", attempt: 1, errors: [%{"error" => error}]} =
             TestRepo.get!(Oban.Job, id)

    assert error =~ "parked"
    refute_received {:parked_store_delivered, _, _}

    # Still a pending timer for the scope while it waits out the park.
    assert %{^scope => 1} = Timer.pending_for(config, [scope])

    :ok = ParkedStoreDelivery.unpark(scope)

    assert %{success: 1, failure: 0, cancelled: 0} = drain(queue)
    assert %Oban.Job{state: "completed", attempt: 2} = TestRepo.get!(Oban.Job, id)
    assert_received {:parked_store_delivered, ^scope, %Statifier.Event{name: "reminder"}}
  end

  # sabotage: same mutation as above - went red here too (cancelled: 1
  # instead of discard: 1, so the row never reached Oban's exhausted
  # state and the documented revival had nothing to revive) - reverted.
  test "a park that outlasts max_attempts ends the job discarded by Oban, revivable after the unpark",
       %{config: config, queue: queue, scope: scope} do
    ParkedStoreDelivery.put(scope, :needs_migration)
    %Oban.Job{id: id} = insert_with_max_attempts(queue, scope, 1)

    assert %{discard: 1, failure: 0, cancelled: 0, success: 0} = drain(queue)

    # Oban's exhausted state, not the spec 6.2 discard: the recorded
    # error is the raise, never a `{:discarded, reason}`.
    assert %Oban.Job{state: "discarded", errors: [%{"error" => error}]} =
             TestRepo.get!(Oban.Job, id)

    assert error =~ "parked"
    refute error =~ "{:discarded"

    :ok = ParkedStoreDelivery.unpark(scope)

    # The timer does not fire on its own after the unpark...
    assert %{success: 0, failure: 0} = drain(queue)
    refute_received {:parked_store_delivered, _, _}

    # Scheduling the same effect again is swallowed by the dedup guard
    # the discarded row still holds, so it revives nothing...
    assert {:ok, %Oban.Job{id: ^id, conflict?: true}} =
             Timer.schedule(config, scope, fired_fixture())

    assert %{success: 0} = drain(queue)

    # ...and the documented revival delivers it.
    assert :ok = Oban.retry_job(@oban_name, id)
    assert %{success: 1} = drain(queue)
    assert_received {:parked_store_delivered, ^scope, %Statifier.Event{name: "reminder"}}
  end

  # sabotage: removed the {:snooze, seconds} clause from perform/1 in
  # StatifierOban.Timer.Worker - went red (failure: 1 instead of
  # snoozed: 1: the answer raised and spent an attempt) - reverted.
  test "a timer firing into a parked execution snoozes with its retries intact, then delivers after the unpark",
       %{config: config, queue: queue, scope: scope} do
    ParkedStoreDelivery.put(scope, :needs_migration)
    :ok = ParkedStoreDelivery.answer_parked_with({:snooze, 60})
    assert {:ok, %Oban.Job{id: id}} = Timer.schedule(config, scope, fired_fixture())

    %Oban.Job{attempt: 0} = scheduled = TestRepo.get!(Oban.Job, id)
    left = scheduled.max_attempts - scheduled.attempt

    # Two snoozes in a row: each reschedules the row, records no error
    # and leaves the attempts it has left where they were.
    for _run <- 1..2 do
      before_run = DateTime.utc_now()

      assert %{snoozed: 1, failure: 0, cancelled: 0, discard: 0, success: 0} = drain(queue)

      assert %Oban.Job{state: "scheduled", errors: [], scheduled_at: at} =
               job = TestRepo.get!(Oban.Job, id)

      assert job.max_attempts - job.attempt == left
      assert DateTime.diff(at, before_run) >= 59
      refute_received {:parked_store_delivered, _, _}

      # Still a pending timer for the scope while it waits out the park.
      assert %{^scope => 1} = Timer.pending_for(config, [scope])
    end

    :ok = ParkedStoreDelivery.unpark(scope)

    assert %{success: 1, snoozed: 0, failure: 0, cancelled: 0} = drain(queue)
    assert %Oban.Job{state: "completed", errors: []} = TestRepo.get!(Oban.Job, id)
    assert_received {:parked_store_delivered, ^scope, %Statifier.Event{name: "reminder"}}
  end

  # sabotage: same mutation as above - went red here too (failure: 1
  # instead of snoozed: 1, so the row was retryable, not scheduled) -
  # reverted.
  test "a snoozed timer is still reached by a cancel of its send id",
       %{config: config, queue: queue, scope: scope} do
    ParkedStoreDelivery.put(scope, :needs_migration)
    :ok = ParkedStoreDelivery.answer_parked_with({:snooze, 60})
    assert {:ok, %Oban.Job{id: id}} = Timer.schedule(config, scope, fired_fixture())

    assert %{snoozed: 1} = drain(queue)
    assert %Oban.Job{state: "scheduled"} = TestRepo.get!(Oban.Job, id)

    assert {:ok, 1} = Timer.cancel(config, scope, cancel_fixture())
    assert %Oban.Job{state: "cancelled"} = TestRepo.get!(Oban.Job, id)
    assert %{^scope => 0} = Timer.pending_for(config, [scope])
  end

  # sabotage: perform/1 in StatifierOban.Timer.Worker answered
  # {:snooze, 60} for {:discarded, reason} - went red (snoozed: 1
  # instead of cancelled: 1) - reverted.
  test "a finished execution still discards under a delivery that snoozes parked ones",
       %{config: config, queue: queue, scope: scope} do
    ParkedStoreDelivery.put(scope, :completed)
    :ok = ParkedStoreDelivery.answer_parked_with({:snooze, 60})
    assert {:ok, %Oban.Job{id: id}} = Timer.schedule(config, scope, fired_fixture())

    assert %{cancelled: 1, snoozed: 0, failure: 0, success: 0} = drain(queue)
    assert %Oban.Job{state: "cancelled"} = TestRepo.get!(Oban.Job, id)
    refute_received {:parked_store_delivered, _, _}
  end

  # sabotage: dropped `seconds > 0` from the snooze clause's guard in
  # StatifierOban.Timer.Worker - the zero and negative cases went red
  # (Oban snoozed the zero and took the negative as a success) -
  # reverted. Dropped `is_integer(seconds)` instead - the non-integer
  # and period-tuple cases went red (a success and a snooze) - reverted.
  # The four tests share a line, so each takes its own queue and scope.
  for {{label, answer}, index} <-
        Enum.with_index([
          {"a zero snooze", {:snooze, 0}},
          {"a negative snooze", {:snooze, -5}},
          {"a non-integer snooze", {:snooze, 1.5}},
          {"an Oban period tuple", {:snooze, {1, :minute}}}
        ]) do
    test "#{label} is not a snooze: it raises and spends an attempt, as today",
         %{queue: queue, scope: scope} do
      queue = "#{queue}_#{unquote(index)}"
      scope = "#{scope}_#{unquote(index)}"

      {:ok, config} =
        Config.new(oban: @oban_name, timers_queue: queue, delivery: ParkedStoreDelivery)

      ParkedStoreDelivery.put(scope, :needs_migration)
      :ok = ParkedStoreDelivery.answer_parked_with(unquote(Macro.escape(answer)))
      assert {:ok, %Oban.Job{id: id}} = Timer.schedule(config, scope, fired_fixture())
      %Oban.Job{max_attempts: max_attempts} = TestRepo.get!(Oban.Job, id)

      assert %{failure: 1, snoozed: 0, success: 0, cancelled: 0, discard: 0} = drain(queue)

      assert %Oban.Job{
               state: "retryable",
               attempt: 1,
               max_attempts: ^max_attempts,
               errors: [%{"error" => error}]
             } = TestRepo.get!(Oban.Job, id)

      assert error =~ "CaseClauseError"
    end
  end

  defp cancel_fixture do
    %Cancel{
      send_id: "send_1",
      c_index: 1,
      owner: {:onexit, 0, 0},
      macrostep: 2,
      microstep: 0,
      round: 1,
      ordinal: 5
    }
  end

  defp drain(queue) do
    Oban.drain_queue(@oban_name, queue: queue, with_scheduled: true)
  end

  defp insert_with_max_attempts(queue, scope, max_attempts) do
    {:ok, args} = JobArgs.from_effect(scope, fired_fixture())

    changeset =
      Worker.new(args,
        queue: queue,
        max_attempts: max_attempts,
        meta: %{"delivery" => Atom.to_string(ParkedStoreDelivery)}
      )

    {:ok, job} = Oban.insert(@oban_name, changeset)
    job
  end

  defp fired_fixture do
    %SendDelayed{
      event: "reminder",
      target: nil,
      type: nil,
      data: nil,
      send_id: "send_1",
      delay_ms: 0,
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
