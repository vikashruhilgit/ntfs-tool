# Packaging, signing & distribution

How to build the **NTFSMountManager** menu-bar app (with its embedded
**NTFSFileSystem** FSKit system extension) into a runnable `.app`, sign it for
personal use, activate the extension on your own machine, and — for off-machine
distribution — notarize it.

> **Scope.** This document covers three things, in increasing order of cost and
> ceremony:
> 1. **Local packaging** — a reproducible `.app` you can run on the machine that
>    built it. Ad-hoc signed, no Apple account. (`scripts/package.sh`)
> 2. **Free personal-use signing** — sign with your own Apple ID so the FSKit
>    system extension can activate on *your* Mac (developer mode + free signing).
> 3. **Notarization** — required only to hand the `.app` to *other* machines.
>    Needs a paid Apple Developer account. Documented here but **not run in CI**.

---

## 1. Local packaging (`scripts/package.sh`)

The one command that produces a runnable bundle from a clean checkout:

```bash
./scripts/package.sh --release
```

What it does:

1. `xcodegen generate` — regenerates `NTFSMountManager.xcodeproj` from
   `project.yml` (the source of truth).
2. `xcodebuild -scheme NTFSMountManager -configuration Release` — builds the
   app. Because `project.yml` declares the extension as a dependency with
   `embed: true`, building the app also builds and **embeds** the
   `NTFSFileSystem.systemextension` inside the app bundle.
3. Stages the built `NTFSMountManager.app` into `dist/` (gitignored).
4. **Verifies** the extension is embedded at
   `Contents/Library/SystemExtensions/NTFSFileSystem.systemextension` — and
   fails loudly if it is not.

Options:

| Flag | Effect |
|---|---|
| `--release` | Release build (default). |
| `--debug` | Debug build (faster, for iteration). |
| `--zip` | Also produce `dist/NTFSMountManager.zip` (Finder-compatible, via `ditto -c -k`). |

**Signing in the script.** By default the build is **ad-hoc signed**
(`CODE_SIGN_IDENTITY="-"`, `CODE_SIGNING_ALLOWED=NO`) so it builds with no Apple
Developer account. An ad-hoc-signed app *runs*, but its system extension will
only *activate* after you enable developer mode (section 2). To sign with your
free personal team instead, export `DEVELOPMENT_TEAM` (and optionally
`CODE_SIGN_IDENTITY`) before running:

```bash
DEVELOPMENT_TEAM=ABCDE12345 ./scripts/package.sh --release
```

The produced bundle layout:

```
dist/NTFSMountManager.app/
└── Contents/
    ├── MacOS/NTFSMountManager
    ├── Resources/
    └── Library/
        └── SystemExtensions/
            └── NTFSFileSystem.systemextension   ← the embedded FSKit extension
```

---

## 2. Free personal-use signing + on-machine activation

FSKit system extensions must be signed and approved before macOS will load them.
You do **not** need the paid Apple Developer Program to run the extension on your
own Mac — a free Apple ID plus developer mode is enough. This is the path
referenced in `CLAUDE.md` ("free signing + `systemextensionsctl developer on`").

### 2a. Add your Apple ID as a free signing team

In Xcode: **Settings → Accounts → +** and sign in with your Apple ID. Xcode
creates a free "Personal Team". Find its 10-character Team ID at
<https://developer.apple.com/account> (Membership), or list local identities:

```bash
security find-identity -v -p codesigning
```

Then build signed with that team:

```bash
DEVELOPMENT_TEAM=YOURTEAMID ./scripts/package.sh --release
```

(Equivalently, open `NTFSMountManager.xcodeproj` in Xcode and set **Signing &
Capabilities → Team** to your personal team for both the `NTFSMountManager` and
`NTFSFileSystem` targets, then Product → Archive / Build.)

The entitlements are already declared in the repo and required for activation:

- App: `Apps/NTFSMountManager/NTFSMountManager.entitlements`
  (`com.apple.developer.system-extension.install`, app-sandbox).
- Extension: `Extensions/NTFSFileSystem/NTFSFileSystem.entitlements`
  (`com.apple.developer.fskit.fsmodule`, app-sandbox).

### 2b. Enable system-extension developer mode

A locally-signed (non-notarized, non-App-Store) extension only loads when
developer mode for system extensions is on:

```bash
systemextensionsctl developer on
```

This is reversible (`systemextensionsctl developer off`) and is the supported
path for testing your own extension. You can inspect installed extensions with:

```bash
systemextensionsctl list
```

> On a stock Mac you should not need to disable SIP for the free-signing +
> developer-mode path. (Some setups additionally lower SIP; that is broader than
> required and out of scope here.)

### 2c. Activate the extension and mount a volume

1. Copy `dist/NTFSMountManager.app` to `/Applications` (or run it in place).
2. Launch the app. On first run it asks macOS to activate the bundled system
   extension (`OSSystemExtensionManager`).
3. Approve it: **System Settings → General → Login Items & Extensions** (on
   macOS 15 Sequoia) — find the extension under **File System Extensions** /
   **Endpoint/Driver Extensions** and toggle it on. (You may also be prompted
   under **Privacy & Security**.) Approval requires an admin password.
4. Plug in or attach an NTFS volume. The app's menu-bar UI lists detected NTFS
   volumes; click **Mount**. The volume appears in Finder, read/write.

If activation is silently refused, re-check: developer mode is on (2b), the app
is signed with a team Xcode trusts (2a), and the extension was approved in
System Settings (step 3). `log stream --predicate 'subsystem == "com.apple.sysextd"'`
surfaces activation errors.

---

## 3. Clean-machine activation walkthrough (recap)

For someone receiving the built app on a Mac that has never run it:

1. Obtain the bundle: build it (section 1) or unzip `dist/NTFSMountManager.zip`.
2. Move `NTFSMountManager.app` to `/Applications`.
3. If the app is only ad-hoc / personal-signed (not notarized), the receiving
   machine must also run `systemextensionsctl developer on` (section 2b). A
   notarized build (section 4) does **not** require developer mode.
4. Launch the app, approve the extension in **System Settings → General → Login
   Items & Extensions**, enter the admin password.
5. Attach an NTFS volume → **Mount** from the menu-bar UI → read/write in Finder.

---

## 4. Notarization for off-machine distribution (documented, not run here)

To give the `.app` to *other people's* Macs without each of them enabling
developer mode, the build must be signed with a **paid** Apple Developer
account ("Developer ID Application" identity) and **notarized** by Apple. These
steps require credentials this repo's CI does not have, so they are **documented
but not executed in CI**.

```bash
# 0. Prereqs: paid Apple Developer Program membership, a "Developer ID
#    Application" certificate in your keychain, and an app-specific password or
#    an App Store Connect API key for notarytool.

# 1. Archive a Developer-ID-signed, hardened-runtime build.
xcodebuild \
  -project NTFSMountManager.xcodeproj \
  -scheme NTFSMountManager \
  -configuration Release \
  -archivePath build/NTFSMountManager.xcarchive \
  DEVELOPMENT_TEAM=YOURTEAMID \
  archive

# 2. Export the .app from the archive (Developer ID method).
#    ExportOptions.plist must contain: method = developer-id,
#    teamID = YOURTEAMID, signingStyle = automatic (or manual).
xcodebuild \
  -exportArchive \
  -archivePath build/NTFSMountManager.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath build/export

# 3. Zip the exported app for submission.
ditto -c -k --sequesterRsrc --keepParent \
  build/export/NTFSMountManager.app \
  build/NTFSMountManager.zip

# 4. Submit to Apple's notary service and wait for the result.
xcrun notarytool submit build/NTFSMountManager.zip \
  --apple-id "you@example.com" \
  --team-id YOURTEAMID \
  --password "app-specific-password" \
  --wait

# 5. Staple the notarization ticket onto the app so it validates offline.
xcrun stapler staple build/export/NTFSMountManager.app

# 6. Re-zip the stapled app for distribution.
ditto -c -k --sequesterRsrc --keepParent \
  build/export/NTFSMountManager.app \
  dist/NTFSMountManager-notarized.zip
```

A notarized + stapled, hardened-runtime, Developer-ID-signed build activates its
system extension on any Mac **without** `systemextensionsctl developer on`.

> **Not done in this repo.** CI on `macos-15` builds both schemes ad-hoc only
> (no signing identity), and no notarization is performed — there is no paid
> Apple account or stored credentials available. The commands above are the
> reference procedure for whoever does have those credentials.

---

## 5. Privileged helper (SMAppService root daemon) — REAL signing required

The app ships a second embedded executable: **`NTFSPrivilegedHelper`**, a root
LaunchDaemon installed at runtime via `SMAppService`. It exists so the
unprivileged, sandboxed GUI can read (and later write) the raw NTFS device node,
which macOS creates as `root:operator 0640` — unreadable by the user-level app.
The GUI talks to the daemon over XPC; the daemon opens the device as root and
returns volume facts / verify results.

### 5a. What's embedded (verify in any build)

Building the app scheme (section 1) also builds and embeds the helper via
`project.yml` copy phases. In the built `.app`:

- `Contents/MacOS/NTFSPrivilegedHelper` — the daemon executable. Its path must
  match `BundleProgram` in the plist below.
- `Contents/Library/LaunchDaemons/com.ntfs-tool.NTFSMountManager.PrivilegedHelper.plist`
  — the LaunchDaemon plist `SMAppService.daemon(plistName:)` reads.

```bash
APP=dist/NTFSMountManager.app   # or the DerivedData build products path
ls -la "$APP/Contents/MacOS/NTFSPrivilegedHelper"
ls -la "$APP/Contents/Library/LaunchDaemons/com.ntfs-tool.NTFSMountManager.PrivilegedHelper.plist"
```

The **default ad-hoc build succeeds** (it compiles and embeds correctly), but
the daemon will **not register** ad-hoc: `SMAppService` and the XPC
code-signature gate both require real, team-consistent signing.

### 5b. Signing requirements (both binaries, same team)

`SMAppService` requires that the app **and** the embedded daemon are signed by
the **same** Apple Developer team, and the daemon's client-authentication gate
pins that team's OU. For this project the team OU is **`JT8YU25ABP`** (see
`ntfsHelperClientRequirement` in
`Extensions/NTFSPrivilegedHelper/Sources/NTFSHelperProtocol.swift`; change both
if you sign under a different team).

Build signed (both targets inherit the project-level signing settings, so one
invocation signs the app, the FSKit extension, and the helper together):

```bash
xcodegen generate
xcodebuild \
  -project NTFSMountManager.xcodeproj \
  -scheme NTFSMountManager \
  -configuration Release \
  DEVELOPMENT_TEAM=JT8YU25ABP \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="Apple Development" \
  build
```

Or, once you have a "Developer ID Application" identity, use the notarization
flow in section 4 (which passes `DEVELOPMENT_TEAM` and produces a
Developer-ID-signed, notarized build — the ideal state for the helper).

> The default (`scripts/package.sh` / CI) stays **ad-hoc** — no `DEVELOPMENT_TEAM`,
> `CODE_SIGN_IDENTITY="-"`. The signed invocation above is opt-in and only needed
> to exercise the helper at runtime.

### 5c. Bring-up (register → approve → use)

Runtime enablement is **interactive** and cannot be scripted headlessly:

1. Launch the signed app.
2. Open **Settings → Admin Access → "Install / Enable Helper…"**. This calls
   `SMAppService.daemon(plistName:).register()`. The status transitions to
   *"Awaiting approval in System Settings"* (`.requiresApproval`) on first run.
3. Approve the daemon in **System Settings ▸ General ▸ Login Items & Extensions**
   (under *Allow in the Background* / the app's daemons). The status becomes
   `.enabled`.
4. Select a mounted NTFS volume. When the direct device read fails (root-owned
   node), the loader now falls back to the helper over XPC and shows the full
   NTFS-internal facts instead of degrading to `statfs`.

To remove it: the app can call `unregister()` (or
`sudo sfltool resetbtm` / toggle it off in System Settings).

### 5d. Troubleshooting

- **`register()` throws / status stays `.notFound`** — almost always a signing
  mismatch: the app and daemon aren't signed by the same team, or the build is
  ad-hoc. Rebuild with section 5b.
- **XPC connection rejected** — the daemon's code-signature gate
  (`SecCodeCheckValidity` against `ntfsHelperClientRequirement`) is refusing the
  client. Confirm the app's bundle id is `com.ntfs-tool.NTFSMountManager` and its
  leaf cert OU matches the pinned team.
- **Inspect the daemon** — `sudo launchctl print system/com.ntfs-tool.NTFSMountManager.PrivilegedHelper`
  after approval; `log stream --predicate 'process == "NTFSPrivilegedHelper"'`
  for the `NSLog` gate messages.

---

## See also

- `scripts/package.sh` — the local packaging script described in section 1.
- `project.yml` — target definitions; `embed: true` on the extension dependency
  is what places it inside the app bundle; the `NTFSPrivilegedHelper` target +
  the app's copy phases place the daemon executable in `Contents/MacOS/` and its
  plist in `Contents/Library/LaunchDaemons/`.
- `Extensions/NTFSPrivilegedHelper/` — the root daemon, its XPC protocol/DTOs,
  and the LaunchDaemon plist.
- `CLAUDE.md` — toolchain requirements and the personal-use signing policy.
- `docs/STATUS.md` — current validation state (FSKit mount validation gate).
