# AGENTS.md — development & maintenance guide

For developers and agents working on RectZones.
User docs: [README.md](README.md) · Fresh-install runbook: [SETUP.md](SETUP.md).

## Why the project looks like this

The original plan was to fork Rectangle. The dev machine had no Xcode and its Command
Line Tools shipped a Swift compiler/SDK mismatch (`could not build module 'Foundation'`,
the known CLT 16.2 issue), so the same behavior was written as an **independent,
single-file Objective-C app**: clang + Cocoa, zero external dependencies. Rectangle's
`SnappingManager` was studied as a reference (see README "Lineage"), not copied.

## Architecture — `src/main.m`, sections in order

| Section | What |
|---|---|
| `RZLog` | Diagnostic log → `/tmp/rectzones.log`. Read this FIRST on any bug report. |
| Model (`RZTemplate`, `RZStore`) | Templates + active template + trigger + shortcuts + gap; JSON persistence at `~/Library/Application Support/RectZones/config.json`. |
| Coordinates | CRITICAL: CG/AX coordinates are top-left origin (y down), AppKit is bottom-left (y up). Zones are ratios (0–1) of a screen's `visibleFrame`, top-left origin. All conversions live here — if windows land in the wrong place, look here first. |
| Overlay (`RZZoneView`, `RZFootprint`, `RZOverlay`) | Per-screen click-through borderless panels; zone highlighting (hover/selected/covered) and the single-rect footprint for edge snapping. |
| AX helpers (`RZWindowAt`…) | Window under cursor, read/write frames. Position is written again after resize (some apps shift it). |
| `RZDrag` | `CGEventTap` (listen-only) state machine. Modifier state is read from **every** event — `flagsChanged` alone misses remapped keys. Window-moving check runs continuously with no threshold (Rectangle's approach) plus a title-strip heuristic. Every swept zone accumulates while the trigger is held — no second modifier; drop applies the union, releasing the trigger cancels. Accumulation is bounded by the keypress, not the drag, so the path taken before pressing does not pollute the pick; selection is scoped to one screen. Edge/corner snapping (`updateSnapWithMouse`) shows `RZFootprint` after a 0.12 s dwell when dragging without the trigger; the top band is offset by the menu bar height and top corners get a title-strip allowance (see gotcha 5). |
| Shortcuts (`RZHotkeys`) | Carbon `RegisterEventHotKey`. Cycle memory is scoped (template vs. each grid vs. corner hop) so cycles don't clobber each other. |
| Editor (`RZEditor*`) | Code-built UI (no xibs — CLT has no ibtool). Canvas is `isFlipped=YES` to match the zone model. Selecting a template in the popup activates it. |
| Shortcuts UI (`RZShortcutsUI`) | Press-to-record rows with mini previews (`RZMiniGridView`). Bare ⎋ cancels recording; modified ⎋ combos are recordable. |
| `RZSettings` | One window, three tabs (Template Editor / Trigger Key / Shortcuts). |
| `RZApp` | Menu bar item (▦ / ▦⚠ permission badge), permission polling, single-instance guard. |
| `RZ_SNAPSHOT` section | Alternate `main()` that renders the real UI views to PNGs for the README (no screen-recording permission needed). |

## Development loop

```bash
pkill -f RectZones.app
./build.sh
open build/RectZones.app
```

- **Every build breaks the Accessibility grant** (ad-hoc signing → new cdhash → the
  old TCC row authorizes an identity that no longer exists). The row keeps showing as
  **ON** while the app sees `trusted=0` — an enabled toggle proves nothing. Toggling it
  off and on does NOT help either. The proven fix, and the one the user wants used:
  System Settings → Privacy & Security → Accessibility → select **RectZones** → **−**
  to remove the row → **+** and add
  `build/RectZones.app` back. Cannot be automated — batch changes into one build.
- The build is reproducible: rebuilding with `src/main.m` unchanged yields a byte-identical
  binary, so the cdhash — and the grant — survive. Only a real source change costs a
  permission cycle. Verify with `codesign -dv --verbose=4 build/RectZones.app` before
  putting the user through the steps above.
- **Do not propose stable/self-signed code signing to survive rebuilds.** It would work,
  but the user has declined it more than once and does not want to be asked again. The
  remove-and-re-add step above is the accepted cost of an ad-hoc build.
- You cannot test drag interactions yourself: have the user try, then read
  `/tmp/rectzones.log`.
- Screenshots for the README: `clang -DRZ_SNAPSHOT -fobjc-arc src/main.m -o /tmp/rz-snap
  -framework Cocoa -framework Carbon -framework ApplicationServices && /tmp/rz-snap docs`

## Field-tested gotchas (do not relearn these)

1. `valueForKey:@"mutableCopy"` on an array of `NSDictionary` does **dictionary
   lookups**, not copies — the array fills with `NSNull`. Use `RZCopyZones()`.
2. Up to three window placers can overlap on a user's machine: RectZones + Rectangle +
   macOS built-in tiling. On "my settings don't work" reports, first answer **who is
   drawing** (README troubleshooting 2–3).
3. Keyboard remaps: compare against the modifier flag the key *produces*, never the
   key label.
4. Two running instances split menu ↔ event-tap across processes and settings appear
   dead. The single-instance guard in `applicationDidFinishLaunching` stays.
5. **The top screen edge is not symmetric with the other three.** macOS stops a dragged
   window at the menu bar and the cursor rides on the title strip, so the cursor stalls
   ~`menuH + 34` px below the screen top and can never enter a plain 16 px band — the
   `left`/`right` test wins and pushing into a top corner reads as a half. Any edge test
   at the top must measure from `visibleFrame`, not `frame`. Corners get the full
   title-strip allowance; the maximize band stays tight, since it lacks the side-edge
   requirement that keeps corners from misfiring.

## Landing a change

`main` is protected. Nobody pushes to it directly — including maintainers.

```bash
git checkout -b short-descriptive-branch-name
# ... work ...
git push -u origin short-descriptive-branch-name
gh pr create
```

- **Squash merge only.** Merge commits and rebase merges are disabled, so each PR
  becomes exactly one commit on `main` and the PR title becomes the commit message.
  Intermediate commits on your branch are fine — they disappear on merge.
- **Force pushing `main` is blocked**, and should stay that way now that the repo
  accepts outside contributions: it invalidates open PRs and diverges forks. (This is
  not hypothetical — an early force push closed a Dependabot PR.)
- Two required checks, both on `macos-latest` (`.github/workflows/build.yml`):
  - **`build`** — runs `build.sh`, validates the bundle and its signature, then builds a
    second time and fails if the binary is not byte-identical. Reproducibility is a
    feature, not a nicety: it is what lets an unchanged source tree keep its
    Accessibility grant across rebuilds.
  - **`static analysis`** — `clang --analyze` with `-Werror`, currently clean and
    expected to stay clean. **CodeQL cannot be used on this project** — it does not
    support Objective-C (excluded from the `c-cpp` extractor), so enabling code scanning
    would produce a silent no-op. Clang's analyzer is the substitute.
    Note: pass no `-framework` flags to `--analyze`; it does not link, and under
    `-Werror` they become "unused linker input" errors.
  - A third, non-blocking step reports `-Wall -Wextra` warnings. It is
    `continue-on-error` because of one known dead function (`RZTriggerSymbol`). Clean
    that up and the step can become a real gate.
- Contributor-facing guidance lives in [CONTRIBUTING.md](CONTRIBUTING.md); what the app
  does on a user's machine, and how to verify a build, is in [SECURITY.md](SECURITY.md).

## Distribution — decided, and why

RectZones ships **source, not binaries**, and that is a deliberate security position
rather than an unfinished chore.

macOS applies the `com.apple.quarantine` attribute only to files a *downloading*
application fetched. An app the user compiles locally is never quarantined, so the
ad-hoc signature is sufficient and Gatekeeper never fires. Publishing a prebuilt archive
would manufacture a problem the project does not currently have: the download arrives
quarantined, the ad-hoc signature fails Gatekeeper, and the user gets "damaged and can't
be opened" with no supported workaround.

Consequences worth knowing before proposing packaging work:

- **A Homebrew *cask* is the wrong vehicle** — casks install a prebuilt archive and
  cannot build from source.
- **Upstream `homebrew-cask` is closed** to this project on three independent counts:
  the self-submission notability bar (90 forks / 90 watchers / 225 stars), the absence
  of a prebuilt artifact, and the ad-hoc signature — Homebrew disables casks that fail
  Gatekeeper checks from 1 September 2026.
- **Upstream `homebrew-core` is closed structurally**, regardless of popularity:
  "Don't make your formula build an `.app`".
- **The route that works is a *formula* in our own tap**,
  [RectZones/homebrew-tap](https://github.com/RectZones/homebrew-tap). It builds from
  source on the user's machine, so it keeps the no-quarantine property, gives a one-line
  install, and is subject to none of the official repositories' acceptance policies.
  Install with the fully-qualified name — `brew install RectZones/tap/rectzones` —
  because Homebrew 6.0's tap trust otherwise requires an explicit `brew trust`.

Changing the **bundle identifier** (`app.rectzones.RectZones`) is a breaking act: the
ad-hoc signature embeds it in the code directory, so the binary hash changes even with
unchanged source, and the Accessibility grant is keyed to it. It must not change again
outside a deliberate, announced migration.

## Roadmap / open items

- Launch at login (`SMAppService`).
- Rectangle parity extras: previous display, center, restore.
- Per-screen templates (currently one template applies to all screens).
- Test coverage. There is none, and the single-file layout is the obstacle: there is no
  separable unit to test. The agreed direction is to lift the pure logic — zone
  geometry, placement math, config read/write — out of the UI and syscall paths into a
  second file that `build.sh` also compiles, with the test runner as another `clang`
  target. **Not** a migration to SwiftPM or an Xcode project: that is the toolchain the
  project could not use in the first place (see "Why the project looks like this"), and
  it puts the reproducible build at risk.
- Release process: version is currently hardcoded in `build.sh` (`0.1`) and should be
  derived from the git tag instead. No releases or tags exist yet.
- Signed distribution (Developer ID + notarization, $99/year) — only becomes worth
  discussing if prebuilt binaries are ever wanted. It is a prerequisite for any upstream
  cask, but that also needs 225+ stars, so it is not a near-term question.
