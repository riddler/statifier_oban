### Added

- `StatifierOban.Timer.Delivery.fired_event/2` builds the external event a
  fired timer feeds back, so a host delivery implementation restores the
  caller's trace context instead of assembling the event by hand and dropping
  it.
