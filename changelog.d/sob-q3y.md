### Added

- `StatifierOban.Invoke.FanOut` schedules a fan-out invocation: a handler's `run/1` returns `{:fan_out, items}` and one start job goes out per item, keyed per index and resumable from the ones already stored.
- `StatifierOban.Invoke.ChildStarter` is the seam a fan-out's child runs are created through, named by the new `:child_starter` config option.
- `:max_fan_out` caps a fan-out's width (default `1_000`); a wider one starts no children and fails the invocation on `error.communication.invoke.<invoke_id>` with the count and the cap.
- `StatifierOban.Invoke.FanOut.cancel_unstarted/3` cancels the start jobs of an invocation whose children have not been created yet.
