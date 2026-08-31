### Fixed

- `StatifierOban.Timer.cancel/3` no longer cancels a timer job that is already
  executing, so a fired timer whose delivery exits the state that armed it is
  no longer killed mid-step by its own `onexit` `<cancel>`.
