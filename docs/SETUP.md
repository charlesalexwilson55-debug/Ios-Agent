# Building and installing Conduit from Windows

You have no Mac and no Xcode. That is fine — nothing in this repo needs them
locally. The project is text-authored (`project.yml`, not a `.xcodeproj`), and
a GitHub Actions macOS runner does the compiling.

## 1. Build

```bash
git add -A && git commit -m "Conduit" && git push
```

The workflow in `.github/workflows/ios.yml` runs on **`macos-26`**, which is
the runner label that carries Xcode 26 and therefore the iOS 26 SDK. That is a
hard requirement, not a preference: `glassEffect` and `GlassEffectContainer`
only exist in the iOS 26 SDK, and on `macos-15` the build fails with "cannot
find glassEffect in scope".

The run produces two artifacts:

- `Conduit-unsigned-ipa` — the app
- `Conduit-entitlements` — the entitlements plist you will need in step 3

To build locally if you ever do get a Mac: `bash scripts/build-ios.sh`.

### If the build fails

The first build almost certainly will, because none of the Swift has ever been
through a compiler. Most likely causes, in order:

1. **An MLX API has moved.** Everything MLX touches is in
   `App/Model/ModelRunner.swift` — deliberately, so this is a single-file fix.
   Check the current signatures at
   `github.com/ml-explore/mlx-swift-lm/tree/main/skills/mlx-swift-lm/references`.
2. **A Liquid Glass modifier signature differs.** Confined to `App/UI/`.
3. **Swift 6 concurrency complaints.** `project.yml` pins
   `SWIFT_VERSION: 5.0` to avoid strict concurrency on a first build. Leave it
   there until the build is green.

The archive step pipes through `xcbeautify`, which swallows the real error. To
see it, re-run the `xcodebuild archive` command that `build-ios.sh` prints in
its failure message, without the pipe.

## 2. Install on the phone

You are on Windows, so **Sideloadly** is the path.

1. Install [Sideloadly](https://sideloadly.io/) and iTunes (it needs Apple's
   device drivers).
2. Plug the iPhone in, trust the computer.
3. Drag `Conduit-unsigned.ipa` into Sideloadly.
4. Enter your Apple ID. A free one is fine.
5. **Before clicking Start**, see step 3 — the entitlements matter.

On the phone, the first launch needs: Settings → General → VPN & Device
Management → your Apple ID → Trust.

### Free Apple ID vs the $99 Developer Program

| | Free | Paid ($99/yr) |
|---|---|---|
| App expires after | **7 days** | 1 year |
| Apps installed at once | 3 | unlimited |
| Re-signing | every week, cable attached | annually |

You said you want to use this daily. Seven-day re-signing gets old fast — it
means plugging into this laptop every week or the app stops opening. If Conduit
turns out to be something you actually reach for, the $99 is the difference
between a toy and a tool. Start free, decide after a fortnight.

## 3. Entitlements — the step that makes an 8B model possible

`Support/Conduit.entitlements` requests two things:

```
com.apple.developer.kernel.increased-memory-limit
com.apple.developer.kernel.extended-virtual-addressing
```

Without them, iOS caps the app well below what a 4.6GB model plus KV cache
needs, and the process is **jetsammed mid-generation** — it looks like a random
crash halfway through an answer, not like an out-of-memory error.

AltStore Classic (2.2+) and Sideloadly both preserve these when re-signing with
a free Apple ID. In Sideloadly, the entitlements file goes in the advanced
options; the IPA also carries a copy at its root so it travels with the build.

This raises the ceiling — it does not create memory. On a 12GB iPhone 17 Pro,
a 4-bit 8B fits with the entitlement and does not without. A 4B fits either
way, which is one more reason to start there.

## 4. Grant permissions

Conduit asks for each permission the first time it needs it, not at launch —
five modal dialogs before you have typed anything earns five reflexive
"Don't Allow"s.

- **Calendar** — full access. Write-only cannot answer "am I free at 3?", which
  is half of what you want from it.
- **Reminders** — full access (there is no write-only tier).
- **Contacts** — needed for "text Mum". Grant all, or use the iOS 18 selected-
  contacts mode; Conduit detects the limited grant and says "this person may
  not be shared with me" instead of "no such person".
- **Notifications** — only for `schedule_notification`.

Denied permissions can only be changed in Settings; iOS shows each dialog once.
Current status is listed in the app under Model → Permissions.

## 5. Teach it your Shortcuts

This is the highest-value ten minutes you will spend on setup. Anything iOS
won't let an app do, Shortcuts usually can. Build one, give it a plain name,
and the model can run it by name from then on.

Worth making:

| Shortcut name | What it does |
|---|---|
| `Morning alarm` | Sets a 6am alarm |
| `Focus on` | Turns on Do Not Disturb |
| `Wind down` | Dims, DND, plays something quiet |
| `Arrive home` | Lights, heating |

Then: "run my Morning alarm shortcut". Conduit switches to Shortcuts and asks
it to run. Note that Conduit cannot see the result — if the name doesn't match,
Shortcuts shows the error and the app never hears about it, so the model is
instructed to say "asked Shortcuts to run it" rather than claiming success.

The reverse works too: Conduit exposes an "Ask Conduit" App Intent, so you can
put Conduit inside your own shortcuts, or say "Hey Siri, ask Conduit to…".
