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
- **No dependencies.** The entire application is Objective-C source in this
  repository, linked against Apple system frameworks (Cocoa,
  ApplicationServices, Carbon). There is no package manager, no vendored
  library, and therefore no third-party supply chain.
- **What it writes to disk:** exactly two paths.
  - `~/Library/Application Support/RectZones/config.json` — your zone
    templates, shortcuts, trigger key, gap setting.
  - `/tmp/rectzones.log` — a diagnostic log of permission state, trigger
    detection, and window placements. It records window positions and
    application names, not window contents or keystrokes.
- **No elevated privileges.** RectZones never asks for admin rights, installs
  no helper tool, no launch daemon, and no kernel extension.

## "Is this thing safe?" — the short answer

You do not have to take our word for any of this, which is the point of the rest
of this section. In brief:

- You **build it yourself from source you can read**. Nobody hands you a binary.
- It **makes no network connections** — there is nothing for it to phone home to.
- Every change is **checked automatically before it can be merged**, and those
  checks are in the repository where you can read them.
- Two independent people must sign off on a change to `main`.

What we cannot claim: nobody has run RectZones through a commercial antivirus
suite, and it carries no Apple notarization ticket (see below for why). If your
organisation requires either, RectZones does not currently meet that bar, and we
would rather say so than imply a review that never happened.

## Verifying what you run

RectZones is distributed as **source, not as a prebuilt binary.** You compile it
yourself with `./build.sh`, so the code you audit is the code you run. There is
no signed-installer trust gap to bridge.

**The build is reproducible.** An unchanged source tree produces a byte-identical
binary — verify it yourself in two commands:

```bash
./build.sh && shasum -a 256 build/RectZones.app/Contents/MacOS/RectZones
./build.sh && shasum -a 256 build/RectZones.app/Contents/MacOS/RectZones
# the two hashes are identical
```

This is not a party trick. It means the binary is a pure function of the source:
there is no hidden input, no build-time randomness, and nothing that could vary
between your machine and ours. If we ever publish a prebuilt `.app`, you can
check it against the tagged source by building it and comparing hashes — a claim
that is meaningless without reproducibility, and checkable with it.

Precisely, the binary is determined by the source **and the version string**. The
ad-hoc signature covers `Info.plist`, so bumping the version changes the hash even
with identical code. That is why upgrading costs you one Accessibility re-grant.

CI enforces this on every pull request: it builds twice and fails if the two
binaries differ.

### What reproducibility means for the Accessibility permission

macOS ties your Accessibility grant to the app's code signature. Because the build
is reproducible:

- **Rebuilding unchanged source keeps your permission.** The signature is the same,
  so macOS still recognises the app.
- **Rebuilding after any change to the code or version needs a fresh grant** — a
  different binary is, correctly, a different app as far as macOS is concerned.

If you are developing RectZones you will hit the second case constantly; see the
Troubleshooting section of the README for how to re-grant cleanly.

### Gatekeeper, quarantine, and the "damaged app" warning

The app is **ad-hoc signed** (`codesign --sign -`), not signed with an Apple
Developer ID and not notarized.

This sounds worse than it is, because of how macOS actually decides to block
things. Gatekeeper acts on the `com.apple.quarantine` attribute, which is applied
by the application that *downloads* a file. **Software you compile on your own
machine is never quarantined**, so Gatekeeper never runs, and an ad-hoc signature
is sufficient. You should not see a "damaged and can't be opened" warning.

The trade-off is real and worth stating: an Apple notarization ticket would mean
Apple had scanned the binary for known malware. RectZones has no such ticket. What
you get instead is the ability to read every line of what you are running, and to
prove your build matches the source.

## What is checked automatically, and what it catches

Every pull request runs these on a clean macOS machine before it can be merged.
The definitions live in [`.github/workflows/build.yml`](.github/workflows/build.yml)
— read them rather than trusting this summary.

| Check | What it actually catches |
|---|---|
| **build** | The app compiles, the bundle is well-formed, `plutil -lint` accepts the `Info.plist`, and `codesign --verify` accepts the signature. A broken or malformed bundle cannot merge. |
| **build → reproducibility** | The binary is built twice and the hashes compared. Catches any change that makes the output depend on something other than the source. |
| **static analysis** | Clang's static analyzer over the whole source, with any finding treated as an error. Catches memory errors, null dereferences, leaks, and dead logic. |

Two of these — `build` and `static analysis` — are **required**: `main` is
protected, force-pushing to it is blocked, and a pull request needs both checks
green plus a review from another maintainer before it merges.

One caveat we would rather state than have you discover: a repository
administrator can bypass those requirements. That is a property of GitHub, not a
setting we chose, and it is reserved here for unblocking a release rather than
routine work.

### Why there is no CodeQL

If you look at the Security tab expecting GitHub's code scanning and find nothing,
that is not an oversight. **CodeQL does not support Objective-C.** The language is
explicitly outside its `c-cpp` extractor, so enabling code scanning here would
produce an empty result set — the appearance of a security control with none of
the substance.

Clang's static analyzer is the honest substitute, and unlike an unconfigured
CodeQL it actually runs on every change.

### Dependencies

There are none to scan. RectZones is Objective-C compiled against Apple's own
system frameworks — no package manager, no vendored libraries, no third-party
code in the app itself. The only third-party code anywhere in the repository is
the GitHub Actions used by CI, and [Dependabot](.github/dependabot.yml) watches
those weekly.

This removes an entire class of risk: there is no supply chain to compromise.

## Scope

In scope: anything that lets RectZones be used to escalate privileges, exfiltrate
data, execute code the user did not intend, or that leaks sensitive information
into the config file or diagnostic log.

Out of scope: the Accessibility permission requirement itself (it is inherent to
what a window manager does), the absence of Developer ID signing and
notarization (documented above and intentional), and anything requiring an
attacker to already have code execution or admin rights on the machine.
