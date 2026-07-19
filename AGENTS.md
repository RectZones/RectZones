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

## Roadmap / open items

- Launch at login (`SMAppService`).
- Rectangle parity extras: previous display, center, restore.
- Per-screen templates (currently one template applies to all screens).
- Signed team distribution (Developer ID + notarization) if the team ever wants
  prebuilt binaries instead of building from source.
