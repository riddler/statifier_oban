### Changed

- An undecodable invoke job now reports `error.communication.invoke.<invoke_id>`
  through the delivery seam before cancelling, whenever its row still names a
  scope and an invoke id, so a chart parked on `error.communication` no longer
  hangs on a corrupt row.
