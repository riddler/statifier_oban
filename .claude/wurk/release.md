# Statifier_oban extension: /wurk:release

Additional required steps for `/wurk:release` in this repo. The skill reads
this file before step 1 of its `kind: "hex"` recipe and treats what is here as
required steps placed where this file says. Extensions add; they never
override, and nothing below rewrites a step the skill already performs.

Read this together with `.claude/wurk.json`'s `release` block. Between them
they name every file a release commit here touches, and no others.

The reference for every shape below is **the most recent release-prep commit
on `main`**, resolved when you read this rather than named here. Find it with:

```bash
git log --oneline --no-patch -L '/@version/,+1:mix.exs'
```

The first line is the last commit that moved `@version`, and the last commit
that moved `@version` is the last release prep by definition. Where this file
and that commit disagree, the commit is the evidence and this file is the
defect.

**This file names no SHA for that reference, on purpose, and carries no
current version string anywhere - only the dated historical claims below.** A
hard-coded reference stops being the most recent the moment the next release
lands, which is how the 0.5.0 prep came to be named here long after 0.6.0,
0.6.1 and 0.7.0 had passed it (corrected 2026-09-06 on `sob-kwz`).

## Why the recipe names no changelog

`kind: "hex"`'s changelog step renames a `## [Unreleased]` heading in one file
to `## [X.Y.Z] - YYYY-MM-DD`. This repo has no such heading and never will:
`changelog.mode` is `fragments`, and `CHANGELOG.md` says so in its own header -
unreleased work lives one file per bead in `changelog.d/`, and the fragments
are assembled into a version section at release. Pointing `release.changelog`
at `CHANGELOG.md` would make the skill's precondition read for an unreleased
section that is not there, and its edit rename a heading that does not exist.

So `release.changelog` is deliberately absent, and a recipe that does not name
a changelog names no changelog edit. The promotion this repo actually performs
is step B below - a required step, not an optional one. A release commit
without it is not a release commit.

The unreleased-work check the skill makes before anything else reads
`changelog.d/` here: if the directory holds no fragment other than its own
`README.md`, there is nothing to release, and the run stops exactly as it
would on an empty unreleased section. That is the directory's normal resting
state between releases (`.claude/wurk/commit.md` says the same), so a run that
stops there has found the expected condition, not a broken repo.

## Step A: the version carrier

**None.** `mix.exs`'s `@version` is the only place this package's version
string lives; `lib/` and `docs/` carry no second copy, and `mix.exs` derives
`source_ref: "v#{@version}"` from the same attribute rather than repeating it.
There is no analogue here of a compiler-stamped version constant, so the
skill's own `version_file` edit is the whole of the bump.

Stated explicitly so that a future release does not go looking for a carrier
that was never there. If one is ever added, it belongs in this section and in
the table below, in the same change that adds it.

## Step B: promote the changelog fragments

Placed where the skill's changelog step would have been, and modeled on the
reference prep commit resolved at the top of this file.

1. Read every `changelog.d/*.md` fragment except `README.md`. Each is a Keep a
   Changelog section heading followed by its bullets.
2. Insert a new `## [X.Y.Z] YYYY-MM-DD` section into `CHANGELOG.md` directly
   above the previous version's section. The heading form is the
   one the file already uses throughout - the bracketed version, a single
   space, then the date, **with no `-` separator between them**. (Keep a
   Changelog's own form has the dash; this file has never used it, and a
   release is not the place to change nine headings.)

   **The date is the operator's local date, not UTC** (the convention the
   operator set on 2026-09-06). A prep run late in the local evening is cut
   under a UTC date that is already tomorrow; writing that UTC date puts a
   section in the file dated a day the release was not cut on, and a reader
   comparing it against the tag or the commit date sees a discrepancy that
   is not real. Take the date from `date +%F` on the machine cutting the prep
   and write that. Sections already shipped are left as they stand, because
   rewriting one to match a convention adopted after it was written buys
   nothing and loses the record of what the published section said.
3. Under the heading, write the fragments' bullets grouped by heading and
   ordered `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`.
   **Carry every bullet over byte for byte.** Reordering, consolidating or
   rewording a fragment's bullet is an editorial pass a human does separately,
   before the release.
4. A lead paragraph between the heading and the first `### ` sub-heading is
   optional here and is the exception, not the rule: `0.2.1` and `0.1.0` carry
   one because each says something the bullets do not (a documentation-only
   release; a first release), and no prep since has written one. Write one
   only when there is such a thing to say, and keep the reasoning for the
   version choice in the commit body, where the reference prep puts it.
5. **No link reference.** Unlike sibling repos, this `CHANGELOG.md` has no
   link-reference block at the end of the file and no `[X.Y.Z]:` definitions
   anywhere - the bracketed versions in the headings are deliberately
   unlinked. Do not add one for the new version, and do not "repair" the file
   by adding the whole block.
6. Delete the promoted fragment files in the same commit. `README.md` stays.

Whether the release is major, minor or patch is not decided here - the version
is explicit input to the skill. The fragments' headings are evidence for that
judgement, not a rule that computes it.

## The README install pin

`release.readme_pin` is `true`. `README.md`'s `def deps` snippet carries
`{:statifier_oban, "~> X.Y"}` - the major/minor form with the patch component
dropped that the skill's step 2 bumps.

Two things about this pin that a release here has to know:

- **The format precedent is `b58fb95` for the pin's shape, and the reference
  prep for the move.** `b58fb95` (the 0.2.1 docs pass) moved the pin from
  `~> 0.1` to `~> 0.2` and recorded that in the 0.2.1 changelog as a fix; for
  a long time no release prep had moved it at all, which is what that
  precedent was here to cover. Preps now move it themselves, so the skill's
  "check a previous release commit rather than inventing the format" step
  reads against the reference prep resolved at the top of this file, with
  `b58fb95` as the older fallback.
- **The pin's current value is not written down here**, for the same reason no
  current version is. Read it and check it against the version file instead:

  ```bash
  grep 'statifier_oban, "~>' README.md   # the pin
  grep '@version "' mix.exs              # the version it should track
  ```

  They should agree on major and minor. If they ever do not, the pin edit
  repairs the drift in one move rather than stepping one release at a time: it
  goes straight to the current major/minor, because the stale constraint no
  longer admits the version being released. That is the recipe correcting a
  drift, not a mistake to undo - say so in the release commit body when it
  happens.

## The files a release commit touches

Exactly these, and a release commit that touches anything else is wrong:

| File | Moved by |
|---|---|
| `mix.exs` | the recipe's `version_file` |
| `README.md` | the recipe's `readme_pin` |
| `CHANGELOG.md` | step B |
| `changelog.d/*.md` (deleted) | step B |

No `lib/` file appears in that table, and step A explains why.

## What a release here still is not

The skill does not tag, push, open a request or publish, and this extension
does not either. In this repo those are the operator's, in every campaign and
outside every campaign. `CLAUDE.md`'s authority table is explicit on both
halves:

- *a release (tag, `mix hex.publish`, GitHub release)* - trigger **never**,
  still unauthorized **always**: "publishing is the operator's, in every
  campaign".
- *a version bump on a release bead's branch* - allowed only on "an
  operator-authorized release bead, inside a campaign carrying the operator's
  explicit consent", and still unauthorized "on any other bead, on main, or
  when the operator has not named this repo's release bead".

So the one thing this recipe performs - the bump plus the step B promotion, on
a named release bead's branch, under a campaign consent that names it - is
release *prep*. `.claude/wurk/commit.md`'s "Version bump: never" section
records the same boundary from the commit side: the version field moves only
through a release bead, never as a convenience.
