<!--
Thanks for contributing to RectZones.

The PR title becomes the commit message on `main` (every PR is squash-merged),
so please write it as a description of the change: "Fix top-edge dead zone on
external displays", not "fixes" or "update main.m".
-->

## What this changes

<!-- One or two sentences. What is different after this PR? -->

## Why

<!-- The problem being solved. Link the issue if there is one: "Fixes #12" -->

## How I tested it

<!--
There is no automated test suite for window behavior — CI only proves it
compiles. Tell us what you actually exercised by hand. For example:

- Dragged with the trigger key held, dropped on a zone
- Swept across three zones, confirmed the preview matched the result
- Pushed into each edge and corner without the trigger key
- Pressed the shortcut twice, confirmed it cycled
- Checked on a second display
-->

**macOS version:**
**Display setup:** <!-- single / multi-monitor, any scaling or notch -->

## Checklist

- [ ] I read [CONTRIBUTING.md](../CONTRIBUTING.md)
- [ ] This is one logical change (unrelated fixes are separate PRs)
- [ ] `./build.sh` succeeds and I ran the app
- [ ] I regenerated `docs/` screenshots, if this changes the UI
- [ ] I updated [AGENTS.md](../AGENTS.md), if this changes architecture or adds a gotcha
