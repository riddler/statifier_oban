defmodule StatifierOban.CancellableStatesTest do
  # Pure: reads the installed Oban's state vocabulary and the helper's
  # answer, touches no repo. The per-state DB proofs live in the timer
  # and invoke CancellableStatesTests; this one pins the list itself
  # against whatever Oban version `mix.lock` resolved.
  use ExUnit.Case, async: true

  alias StatifierOban.CancellableStates

  # The set the two cancel queries mean to reach: every non-terminal
  # state except `executing` (sob-uon, sob-84c).
  @intended ~w(suspended scheduled available retryable)

  @never ~w(executing completed discarded cancelled)

  # Oban ships `suspended` from 2.21.0 (migration v14). Below that the
  # enum on Postgres has no such value and a query naming it fails at
  # execution time, which is the defect sob-axb records.
  Application.ensure_loaded(:oban)
  @oban_vsn :oban |> Application.spec(:vsn) |> to_string()
  @suspended_shipped? Version.match?(@oban_vsn, ">= 2.21.0")

  # sabotage: prepended a fictional "held" state to list/0 past the
  # filter - went red here (and on the two equality tests below).
  # Reverted.
  test "names no state the installed Oban does not know" do
    known = Enum.map(Oban.Job.states(), &Atom.to_string/1)

    assert CancellableStates.list() -- known == []
  end

  # sabotage: added `executing` to @intended in the helper - went red
  # here, and on the executing rows in the timer and invoke
  # CancellableStatesTests. Reverted.
  test "never names executing or a terminal state" do
    assert Enum.filter(CancellableStates.list(), &(&1 in @never)) == []
  end

  # sabotage: dropped `suspended` from @intended in the helper - went red
  # here (three states came back, not four). Reverted.
  test "names every intended state the installed Oban knows, in order" do
    known = Enum.map(Oban.Job.states(), &Atom.to_string/1)

    assert CancellableStates.list() == Enum.filter(@intended, &(&1 in known))
  end

  if @suspended_shipped? do
    # sabotage: dropped `suspended` from @intended in the helper - went
    # red here on the locked Oban 2.23.1. Reverted.
    test "on Oban #{@oban_vsn} (>= 2.21.0) all four intended states are present" do
      assert CancellableStates.list() == @intended
    end
  else
    # sabotage: not run - the locked Oban is >= 2.21.0, so this arm does
    # not compile here. It is the floor-side twin of the arm above; a host
    # on 2.19/2.20 runs it instead.
    test "on Oban #{@oban_vsn} (< 2.21.0) suspended is left out and the other three stay" do
      assert CancellableStates.list() == ~w(scheduled available retryable)
    end
  end
end
