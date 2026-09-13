# Changelog fragments

Changelog entries for unreleased work live here as one file per issue, not as
edits to `CHANGELOG.md`. At release the fragments are assembled into a single
version section and deleted.

## Why fragments

Parallel work happens in one worktree per issue, so several branches are
usually open at once. If each branch appended to the `## [Unreleased]` block
at the top of `CHANGELOG.md`, every branch would touch the same few lines of
the same file and nearly every pull request would conflict with every other
one.

A fragment is named after its issue, so no two branches ever write the same
file and the conflict cannot happen.

## When a change needs a fragment

The changelog serves **people who use the library**. Repo history is git's job,
and work tracking is beads' job. Neither belongs here.

Write a fragment for:

- a public API addition, change, or removal
- a change in observable behavior
- a bug fix a user could have noticed
- anything breaking

Do **not** write a fragment for:

- test harness or fixtures
- documentation, ADRs, or plans
- internal refactors with no visible effect
- quality gate, CI, or agent tooling changes

If you are unsure, ask whether someone who only ever calls the public API could
tell the difference. If not, skip it.

## Format

One file per issue, named for the beads issue ID:

    changelog.d/sob-abc.md

Contents are the Keep a Changelog section heading followed by the entry:

```markdown
### Changed

- Delayed sends are scheduled through Oban instead of `Process.send_after/3`.
```

Rules:

- Use only the standard headings: `Added`, `Changed`, `Deprecated`, `Removed`,
  `Fixed`, `Security`.
- One line per change, present tense, describing the effect on the user.
- No nested bullets. Detail belongs in the pull request and the commit body; a
  changelog line that needs sub-points is really several changes or one that is
  over-explained.
- One file may carry more than one heading if an issue genuinely spans them.
- For a breaking change, say what to do about it, not just what broke.

## At release

Assemble the fragments into a new version section in `CHANGELOG.md`, grouped by
heading and ordered `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`,
`Security`. Delete the fragments in the same commit that cuts the release, and
tag it.

A breaking entry gets a bold `**Breaking**` heading of its own, written
directly under the standard heading its fragment named and above that
heading's ordinary bullets. `README.md`'s pre-1.0 banner promises readers that
every such change is recorded in `CHANGELOG.md` "under a bold **Breaking**
heading that says what to do about it", and promotion is the only place that
promise can be kept: a fragment writes one of the six standard headings and
nothing else, so nothing before the release knows which of its bullets are
breaking. The bullet itself still carries over byte for byte - this is where
it is placed, not a license to reword it.

The promise is forward-looking, and so is the rule. Sections already shipped
are left as they stand, for the reason the release recipe gives for shipped
headings generally: rewriting a published section to match a convention
adopted after it was written loses the record of what the published section
said. The one shipped section that carries a breaking entry today has it as a
bold bullet among the ordinary ones, and it stays that way (ruled 2026-09-13).
