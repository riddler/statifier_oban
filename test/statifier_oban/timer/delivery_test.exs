defmodule StatifierOban.Timer.DeliveryTest do
  # Pure: builds an event from a struct, touches no process and no store.
  use ExUnit.Case, async: true

  alias Statifier.Effect.SendDelayed
  alias Statifier.Evaluator.SystemVariables
  alias StatifierOban.Timer.Delivery

  @scope "run_42"

  # A W3C traceparent map, the shape `docs/telemetry.md` directs a host
  # tracing through the seam to store: strings only, so it carries no
  # node-local term and no atom the reading node may not have seen.
  @caller_context %{"traceparent" => "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"}

  # sabotage: dropped `caller_context: effect.caller_context` from
  # Delivery.fired_event/2 - went red here (the event carried nil, which
  # is exactly the silent link loss the function exists to prevent) -
  # reverted.
  test "the fired event carries the caller context through unread" do
    event = Delivery.fired_event(@scope, fixture(caller_context: @caller_context))

    assert %Statifier.Event{type: :external, name: "reminder", caller_context: @caller_context} =
             event
  end

  # sabotage: same mutation as above, with the `data` copy dropped too -
  # went red here on both fields - reverted.
  test "an opaque data payload rides beside it, also unread" do
    payload = {:host_term, %{"id" => 7}}

    assert %Statifier.Event{data: ^payload} =
             Delivery.fired_event(@scope, fixture(data: payload))
  end

  # sabotage: made the sendid unconditional (`sendid: effect.send_id`) -
  # went red here (an auto-generated id surfaced on the event, which C.1
  # says is not observable) - reverted.
  test "sendid rides only when the author wrote the id" do
    assert %Statifier.Event{sendid: nil} =
             Delivery.fired_event(@scope, fixture(id_from_author?: false))

    assert %Statifier.Event{sendid: "send_1"} =
             Delivery.fired_event(@scope, fixture(id_from_author?: true))
  end

  # sabotage: swapped `origin` and `origintype` in the builder - went red
  # here - reverted.
  test "origin and origintype are stamped at the sending session's location" do
    assert %Statifier.Event{origin: origin, origintype: origintype} =
             Delivery.fired_event(@scope, fixture([]))

    assert origin == SystemVariables.scxml_location(@scope)
    assert origintype == SystemVariables.scxml_event_processor()
  end

  # `nil` is the ordinary detached case: no context was attached and the
  # firing is simply unlinked, not an error.
  #
  # sabotage: `caller_context: effect.caller_context || :none` in
  # Delivery.fired_event/2 - went red here only (a sentinel for "no
  # context" would make every unlinked fire look like a host term the
  # bridge should read) - reverted.
  test "no attached context stays nil" do
    assert %Statifier.Event{caller_context: nil} = Delivery.fired_event(@scope, fixture([]))
  end

  defp fixture(overrides) do
    struct!(
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
      },
      overrides
    )
  end
end
