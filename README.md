# ntfs-tool

Read/write NTFS support for Apple Silicon Macs, distributed as a SwiftUI menu-bar app plus a `ntfsctl` CLI. Built on Apple's modern FSKit framework (macOS 15.4+ Sequoia) — no kernel extension, no SIP changes, no reduced-security boot. Open-source / personal-use prototype.

## Status

Phase 1 (NTFSCore foundation) is in progress. Higher phases:

- **Phase 1** — `NTFSCore` Swift Package: boot sector, MFT, attributes, data runs, directories. Read-only parsing against disk images.
- **Phase 2** — FSKit System Extension scaffold. Mount an NTFS volume read-only.
- **Phase 3** — `ntfsctl` CLI: `info`, `list`, `mount`, `unmount`, `verify`.
- **Phase 4** — SwiftUI menu-bar GUI with DiskArbitration-driven mount manager.
- **Phase 5** — Write support: `$Bitmap` allocator, file create/extend/delete/rename, `$LogFile` synchronous journaling. Goal: `chkdsk` reports zero errors after macOS-side writes.
- **Phase 6** — Hardening: fuzz malformed images, stress, journal replay, power-loss simulation.

Project conventions and architecture live in [CLAUDE.md](CLAUDE.md).

## Building & testing

```bash
cd Packages/NTFSCore
swift build
swift test
```

Requires Swift 6.0+ (Xcode 16.3+) targeting macOS 15+.

## Generating test fixtures

`scripts/make_test_images.sh` regenerates the committed NTFS fixture used by the test suite. It runs `mkntfs` + `ntfs-3g` inside a Debian Docker container so the host doesn't need `ntfsprogs`:

```bash
./scripts/make_test_images.sh         # regenerate Packages/NTFSCore/Tests/NTFSCoreTests/Fixtures/small.img
./scripts/make_test_images.sh --check # verify Docker is reachable without generating
```

The output `small.img` (~4 MiB) is committed to the repo so CI does not need Docker — only the unit tests reading the fixture run there. Regenerate only when the fixture's contents need to change (new in-image test files, new sizes, etc) and commit the new `small.img` alongside the test code that depends on it. Requires Docker Desktop (`open -a Docker`) running on macOS.

**Fixture budget:** total committed fixture footprint must stay below **25 MiB**. The next fixture that would exceed this triggers migration of `Tests/NTFSCoreTests/Fixtures/` to Git LFS (`git lfs install && git lfs track "*.img"`). Until then inline commits are fine and avoid LFS quota / fork-pollution friction.

Hand-crafted 512-byte boot-sector literals in `BootSectorTests` continue to cover the parser's corruption-rejection cases — those tests never touch disk.

## Mounting an NTFS volume via the FSKit extension (Phase 2 manual smoke test)

The repository ships an FSKit System Extension plus a SwiftUI containing app. CI builds them via `xcodebuild`, but mounting an actual NTFS volume requires a one-time manual setup on the M4. (FSKit system extensions cannot be exercised in CI.)

### One-time machine setup

```bash
# Enable unsigned-extension developer mode (requires sudo, persistent across reboots).
sudo systemextensionsctl developer on

# Install xcodegen if not already installed; regenerate the Xcode project from project.yml.
brew install xcodegen
xcodegen generate
```

### Build and run the containing app

```bash
# From the repo root:
open NTFSMountManager.xcodeproj
```

Build & run the `NTFSMountManager` scheme in Xcode. When the app window appears, click **Activate Extension**. macOS will pop a prompt: open **System Settings → Privacy & Security**, scroll to the "Security" section, and click **Allow** next to the NTFSFileSystem extension. The app's status field will switch to "Extension activated."

### Mount procedure

1. **Format a USB stick or test image as NTFS.** On Windows: `Format-Volume -DriveLetter X -FileSystem NTFS`. On Linux (in the Docker fixture pipeline): `mkntfs --fast --label TEST <image>`.
2. **Plug the device into the M4** (or attach the disk image via `hdiutil attach -nomount -readonly <path>.img`).
3. **Check `diskutil list`** — the new device should appear, e.g. `/dev/disk6s1`. macOS may attempt to mount it via Apple's built-in read-only NTFS driver. To force ours, eject first with `diskutil unmount /dev/disk6s1`.
4. **Probe and mount via FSKit:**
   ```bash
   # Probe: is it recognized by our extension?
   /usr/sbin/fskit_admin probe /dev/disk6s1

   # Mount read-only via our extension:
   mkdir -p /tmp/ntfs-test
   mount -t ntfs -o rdonly /dev/disk6s1 /tmp/ntfs-test
   ls /tmp/ntfs-test    # should list the NTFS volume's contents
   ```
5. **Browse in Finder.** Once mounted, the volume appears in Finder's sidebar and `cd /Volumes/...` works.

### Block E v1 capabilities (what works, what doesn't)

- ✅ **Probe** — boot-sector signature check.
- ✅ **Mount read-only** — enumerate, lookup, read file bytes (resident + non-resident `$DATA`).
- ✅ **Directory listing** — Finder browses the volume.
- ✅ **File reads** — `cat`, `cp` from the mount, `Preview` opens images, etc.
- ❌ **Write** — every mutating operation returns `EROFS`. Land in Block G (Phase 5).
- ❌ **Files > 1 GiB** — eager-load cap; throws `NTFSError.unsupportedFeature`. Streaming read API lands in Block G.
- ❌ **Fragmented `$DATA` (`$ATTRIBUTE_LIST`)** — rejected with `NTFSError.unsupportedFeature` rather than silently truncating. Multi-record attribute traversal lands in Block G.
- ❌ **Free-space reporting** — `df -h` shows zeros because `$Bitmap` parsing isn't wired up yet.

### Troubleshooting

- **Extension stays "waiting for user approval."** Open System Settings → Privacy & Security, scroll all the way down — the approval row may take a few seconds to appear. macOS sometimes silently re-denies; if Activate fails again, run `systemextensionsctl list` and check the state.
- **`mount` returns `Operation not permitted`.** Ensure `systemextensionsctl developer on` was run AND the extension is in the "activated enabled" state in `systemextensionsctl list`.
- **`mount` returns "no recognized filesystem".** Our probe failed. Check Console.app filtered to subsystem `com.ntfs-tool.fskit` — the probe logs the reason.

## License

TBD (personal-use prototype; will be decided before any v1 release). NTFS implementation is a clean-room Swift port from public on-disk format documentation; no GPL'd code is copied into this repo.
