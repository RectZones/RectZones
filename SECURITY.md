# Security Policy

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Use GitHub's private reporting instead:
[**Report a vulnerability**](https://github.com/RectZones/RectZones/security/advisories/new).
It is private between you and the maintainers until we publish an advisory.

What to expect:

- An acknowledgement within a few days.
- An assessment, and if the report is valid, a fix on `main` and a published
  advisory crediting you (unless you prefer otherwise).

RectZones is a small volunteer project with no paid security team and no bug
bounty. We will be honest with you about timelines rather than let a report sit
unanswered.

## Supported versions

Only the current `main` branch is supported. There is no long-term-support
branch and no backporting — RectZones is built from source, so the fix for any
issue is to pull and rebuild.

## What RectZones actually does on your machine

Worth stating plainly, because a window manager asks for an alarming-sounding
permission:

- **It requires Accessibility permission.** This is unavoidable: moving and
  resizing other applications' windows is done through the macOS Accessibility
  API, and macOS gates that behind an explicit user grant. This permission is
  powerful — an app that holds it can read and control other apps' UI.
  Grant it only to software you are willing to trust, and note that the same
  caveat applies to every window manager on macOS.
- **The event tap is listen-only.** RectZones installs a `CGEventTap` to detect
  the trigger key during a drag. It observes events; it does not inject,
  modify, or block them. It is not a keylogger — no keystroke content is
  recorded or stored anywhere.
- **No network access, at all.** There is no updater, no telemetry, no crash
  reporting, no analytics, no license check. The app makes no outbound
  connections. You can confirm this with Little Snitch, `lsof -i`, or by
  reading `src/main.m` — there is no networking code in it.
- **No dependencies.** The entire application is one Objective-C file linked
  against Apple system frameworks (Cocoa, ApplicationServices, Carbon). There
  is no package manager, no vendored library, and therefore no third-party
  supply chain.
- **What it writes to disk:** exactly two paths.
  - `~/Library/Application Support/RectZones/config.json` — your zone
    templates, shortcuts, trigger key, gap setting.
  - `/tmp/rectzones.log` — a diagnostic log of permission state, trigger
    detection, and window placements. It records window positions and
    application names, not window contents or keystrokes.
- **No elevated privileges.** RectZones never asks for admin rights, installs
  no helper tool, no launch daemon, and no kernel extension.

## Verifying what you run

RectZones is distributed as **source, not as a prebuilt binary.** You compile it
yourself with `./build.sh`, so the code you audit is the code you run. There is
no signed-installer trust gap to bridge.

**The build is reproducible.** Building an unchanged `src/main.m` produces a
byte-identical binary. If a release ever ships a prebuilt `.app`, you can verify
it corresponds to the tagged source by building it yourself and comparing:

```bash
codesign -dv --verbose=4 build/RectZones.app     # inspect the code directory hash
shasum -a 256 build/RectZones.app/Contents/MacOS/RectZones
```

The app is **ad-hoc signed** (`codesign --sign -`), not signed with an Apple
Developer ID and not notarized. This is a deliberate consequence of building
from source rather than shipping binaries — it is why every rebuild costs you a
re-grant of the Accessibility permission, and why macOS Gatekeeper treats the
bundle as locally built software rather than something Apple has scanned.

## Static analysis

Every pull request is built on macOS in CI and run through Clang's static
analyzer (`clang --analyze`). Note that GitHub's CodeQL cannot be used on this
project: **CodeQL does not support Objective-C** — it is explicitly excluded
from the `c-cpp` extractor — so the Security tab will not show CodeQL results
no matter how the repository is configured. Clang's analyzer is the meaningful
substitute and it runs on every change.

Secret scanning and push protection are enabled on this repository.

## Scope

In scope: anything that lets RectZones be used to escalate privileges, exfiltrate
data, execute code the user did not intend, or that leaks sensitive information
into the config file or diagnostic log.

Out of scope: the Accessibility permission requirement itself (it is inherent to
what a window manager does), the absence of Developer ID signing and
notarization (documented above and intentional), and anything requiring an
attacker to already have code execution or admin rights on the machine.
