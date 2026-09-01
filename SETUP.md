# SETUP.md — agent runbook for a fresh install

> When a user who just cloned this repo tells you "install this", follow this file.
> Goal: build the app, walk the user through the permission, PROVE it works (from the
> log), give a short tour, and close by pointing at the development docs.

## 0. Environment checks

- Requires macOS 13+ and Xcode Command Line Tools: if `clang --version` works you're
  fine; otherwise run `xcode-select --install` (with the user's consent).
- Check for other window managers: `pgrep -lf Rectangle` etc. You'll deal with them
  in step 3.

## 1. Build and launch

```bash
./build.sh
open build/RectZones.app
```

If the user wants it permanent, copy `build/RectZones.app` to `/Applications` and open
it from there — the permission binds to the copy that runs, so open the one they'll use.

## 2. Accessibility permission — together with the user, with proof

1. A system dialog appears on first launch. Guide the user:
   System Settings → Privacy & Security → Accessibility → RectZones **ON** (and it
   must STAY on).
2. **Never claim it works without proof.** Two checks:
   - Menu bar icon: a warning triangle on the icon means no permission; it must disappear.
   - `/tmp/rectzones.log` must contain `trusted=1` and `event tap installed`.
3. If `trusted=0` persists — including when the list entry already shows **ON**, which
   is the usual case after a rebuild — toggling that entry is **NOT enough**. The row
   authorizes the previous build's identity. Have the user:

   - select **RectZones** in the Accessibility list and press **−** to remove it,
   - press **+**, then ⌘⇧G and paste the path to `build/RectZones.app` to add it back.

   `tccutil reset Accessibility app.rectzones.RectZones` is an alternative, but remove-and-
   re-add is the step that has actually worked here — reach for it first.

## 3. Handle conflicting systems (skip this and the user will think it's broken)

- **Rectangle / BetterSnapTool** and similar tools draw their own drag overlays.
  Quit them or disable their snapping — two overlays at once makes users believe
  RectZones ignores its settings.
- **macOS built-in tiling** (macOS 15+) conflicts with our edge snapping. With the
  user's consent:

  ```bash
  defaults write com.apple.WindowManager EnableTilingByEdgeDrag -bool false
  killall WindowManager
  ```

## 4. Live test — the user drives, you verify from the log

1. Hold the trigger key (⌘ by default) and drag a window in the **middle** of the
   screen → zones must appear. Log: `session started`.
2. Still holding the trigger, sweep several zones, drop → the window fills the union.
   Log: `added: zone=…` per zone, then `dropped`. Releasing the trigger before the drop
   must cancel and clear the selection.
3. Drag without the trigger to a screen corner/edge → footprint appears. Log: `edge snap`.
4. Try one keyboard shortcut (Settings → Shortcuts).
5. **Keyboard remap check:** if the user remaps modifiers (System Settings → Keyboard),
   the trigger must match what the key PRODUCES (e.g. a 🌐→⌘ remap means the correct
   trigger is "⌘ Command"; the `flags:` log lines show the raw value).

## 5. Tour and close

- Walk through the README "What it does" list briefly: drag & snap + sweep to combine,
  templates / editor / Apply Grid, shortcut cycling, edge snapping, the Gap setting.
- Closing line: the system is installed and verified; **call me again for feature
  requests** — an agent developing this should read [AGENTS.md](AGENTS.md) first.

## Rules

- **Every rebuild breaks the Accessibility permission** (ad-hoc signing). After any
  build, repeat step 2. Batch your changes into one build — don't drown the user
  in permission dialogs.
- You cannot test drag interactions yourself; have the user do it and read
  `/tmp/rectzones.log`.
- On any bug report: log first, then the README troubleshooting section.
