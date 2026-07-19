# Contributing to RectZones

Thanks for taking the time. RectZones is a single Objective-C file with no
dependencies, so the barrier to hacking on it is deliberately low: clone, run
`./build.sh`, and you have the app.

## Before you start

- **Small fix or obvious bug?** Just open a pull request.
- **New feature or a change in behavior?** Open an issue first so we can agree on
  the shape before you spend time on it. The [roadmap in AGENTS.md](AGENTS.md#roadmap--open-items)
  lists what is already planned.
- **Security issue?** Do not open a public issue — see [SECURITY.md](SECURITY.md).

## Setting up

```bash
# Fork the repo on GitHub, then:
git clone https://github.com/<your-username>/RectZones.git rectzones
cd rectzones
git remote add upstream https://github.com/RectZones/RectZones.git
./build.sh
open build/RectZones.app
```

**Requirements:** macOS 13+, Xcode Command Line Tools (`xcode-select --install`).
Nothing else — no Xcode project, no package manager, no external libraries.

Grant Accessibility when macOS asks (System Settings → Privacy & Security →
Accessibility). The menu bar icon flips from **▦⚠** to **▦** once the app can
actually move windows.

## The development loop

```bash
pkill -f RectZones.app
./build.sh
open build/RectZones.app
```

Two things about this loop will bite you if nobody tells you:

1. **Every source change breaks your Accessibility grant.** The app is ad-hoc
   signed, so a new binary means a new identity, while the existing Accessibility
   entry still authorizes the old one. The row keeps showing **ON** while the app
   sees `trusted=0`. Toggling it off and on does not fix it. Remove and re-add:
   System Settings → Privacy & Security → Accessibility → select **RectZones** →
   **−**, then **+** and pick your `build/RectZones.app` (⌘⇧G pastes a path).
   Batch your changes into one build to pay this cost less often.
2. **Rebuilding without a source change is free.** The build is reproducible —
   an unchanged `src/main.m` yields a byte-identical binary, so the grant
   survives. Check with `codesign -dv --verbose=4 build/RectZones.app`.

**The diagnostic log is your first stop for anything:** `/tmp/rectzones.log`
records permission state, trigger detection, and every window placement.
Config lives at `~/Library/Application Support/RectZones/config.json`.

## Finding your way around the code

Everything is `src/main.m`, organized in labeled sections top to bottom.
[AGENTS.md](AGENTS.md) has the full section-by-section map plus the field-tested
gotchas — **read it before touching coordinates or the event tap.** The short
version of the two traps that cost the most time:

- **Coordinate systems.** CG/AX are top-left origin (y down), AppKit is
  bottom-left (y up). Zones are stored as ratios of a screen's `visibleFrame`,
  top-left origin. If windows land in the wrong place, look at the Coordinates
  section first.
- **The top screen edge is not symmetric with the other three.** macOS stops a
  dragged window at the menu bar, so the cursor can never enter a plain 16 px
  band at the top. Any edge test at the top must measure from `visibleFrame`,
  not `frame`.

## Testing your change

There is no automated test suite — this is a UI app whose whole job is dragging
real windows around. CI builds every pull request on macOS, which catches
compile errors, but **behavior has to be verified by hand.** Please say in your
PR what you actually exercised.

A reasonable pass for most changes:

- Drag a window with the trigger key held; drop it on a zone.
- Sweep across several zones; confirm the preview matches what you get.
- Drag without the trigger key into each edge and corner.
- Press a shortcut twice; confirm it cycles to the next cell.
- Do it once on a second display if you have one.

Attach `/tmp/rectzones.log` if something behaves oddly — it is usually enough to
tell what happened.

## Screenshots

Screenshots in `docs/` are generated from the real UI, not captured by hand:

```bash
clang -DRZ_SNAPSHOT -fobjc-arc src/main.m -o /tmp/rz-snap \
  -framework Cocoa -framework Carbon -framework ApplicationServices
/tmp/rz-snap docs
```

Regenerate them if your change alters the editor, the shortcuts list, or the
trigger key tab.

## Style

Match the file you are editing. The existing code is the style guide: `RZ`
prefix on types and functions, four-space indent, braces on the same line,
comments only where the *why* is not obvious from the code. No new dependencies
and no new files unless there is a real reason — the single-file layout is a
deliberate feature, not an accident.

## Opening the pull request

```bash
git checkout -b short-descriptive-branch-name
# ... work, commit ...
git push origin short-descriptive-branch-name
```

Then open a PR against `main`. Fill in the template: what changed, why, and how
you tested it.

- **One logical change per PR.** Two unrelated fixes are two pull requests.
- **Intermediate commits are fine.** Every PR is squash-merged into a single
  clean commit on `main`, so you do not need to rewrite your history — but do
  write a clear PR title, because it becomes the commit message.
- CI must be green before merge.
- A maintainer reviews and merges. If a PR sits for a week without a response,
  it is an oversight — please comment and nudge it.

By contributing, you agree that your contribution is licensed under the
[MIT License](LICENSE), same as the rest of the project.
