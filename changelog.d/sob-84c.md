### Fixed

- A base handler's cancel no longer cancels an invoke job that is already
  executing, so an invocation whose own completion exits its invoking state is
  no longer killed mid-delivery by that state's `<cancel>`.
