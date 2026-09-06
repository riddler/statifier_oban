### Changed

- A fan-out over an empty `items` list succeeds over nothing: no child starts, the invocation is answered immediately with `[]`, and the `:empty_items` refusal reason is gone (`sb-ADR-0009` decision 8).
