# ntfs-tool — Project Context

## Mission

Build a Paragon-NTFS-style read/write NTFS driver for Apple Silicon Macs, distributed as a SwiftUI menu-bar app plus a `ntfsctl` CLI. Modern userspace approach (FSKit System Extension on macOS 15.4+ Sequoia) — no KEXT, no SIP changes.

Open-source / personal use. GPL'd reference code is acceptable for reference but the implementation is a clean-room Swift port from the on-disk format docs.

## Tech Stack

- **Language:** Swift 5.10+ (Swift 6 mode where stable). Some C interop only if vendoring a fixture-generation helper.
- **Filesystem extension:** FSKit (macOS 15.4+, Xcode 16.3+'s File System Extension template). Subclasses `FSUnaryFileSystem` + `FSVolume`.
- **App shell:** SwiftUI (menu-bar `MenuBarExtra`). Containing app activates the system extension via `OSSystemExtensionManager`.
- **CLI:** Swift ArgumentParser.
- **Build:**
  - `NTFSCore` is a SwiftPM library — `swift build` / `swift test`, no Xcode.
  - The FSKit extension + containing app + CLI live in an Xcode project that consumes `NTFSCore` as a local SwiftPM dependency. Xcode is required only for the extension target (FSKit / SystemExtensions targets cannot be built by SwiftPM alone).
- **Frameworks used:** FSKit, DiskArbitration, SystemExtensions, AppKit, SwiftUI.

## Repo Layout

```
ntfs-tool/
├── Packages/NTFSCore/                  Swift Package: pure NTFS parsing/writing (no FSKit, no UI)
│   ├── Sources/NTFSCore/               BootSector, MFT, Attribute, DataRun, Directory, Bitmap, LogFile, Security, UpCase, Volume, BlockDevice
│   └── Tests/NTFSCoreTests/            Drive disk-image fixtures via swift test
├── Apps/NTFSMountManager/              SwiftUI menu-bar app (containing app for the extension)
├── Extensions/NTFSFileSystem/          FSKit System Extension target
├── Tools/ntfsctl/                      Swift ArgumentParser CLI
├── Tests/Integration/                  End-to-end tests over generated NTFS images
└── scripts/                            Fixture generation (calls mkntfs via Linux container/VM)
```

## Architecture Principles

1. **NTFSCore is pure logic** — no FSKit, no AppKit, no system calls beyond a `BlockDevice` abstraction over a file descriptor. Drives off `.img` fixtures in unit tests with no Xcode and no privileged access.
2. **The FSKit extension is a thin adapter** — maps FSKit's operations onto NTFSCore. Contains no NTFS logic itself.
3. **CLI uses NTFSCore directly** — `ntfsctl info/list/verify` operate on raw devices without involving the system extension.
4. **GUI is the orchestration layer** — DiskArbitration for detection, OSSystemExtensionManager for activation, no NTFS knowledge of its own.

## Phased Delivery (v1)

Each phase produces something demonstrable. See `/Users/vikashruhil/.claude/plans/i-want-build-tool-enchanted-perlis.md` for the full plan.

| Phase | Scope | Deliverable |
|---|---|---|
| 1 | NTFSCore read-only | Unit tests list root, read file bytes from `.img` |
| 2 | FSKit extension scaffold | NTFS USB drive mounts read-only in Finder |
| 3 | `ntfsctl` CLI | `ntfsctl info /dev/disk4s1` works |
| 4 | Menu-bar GUI | Detect NTFS volumes, one-click mount/unmount |
| 5 | Write support | Copy to NTFS, eject, `chkdsk` clean on Windows |
| 6 | Hardening | Fuzz, stress, journal replay, power-loss recovery |

## NTFS Reference Sources (read-only — clean-room port)

- **Linux kernel `fs/ntfs3/*.c`** — Paragon's open-sourced driver. Cleanest reference.
- **NTFS-3G `libntfs-3g/*.c`** — mature C reference.
- **Linux-NTFS docs** — <https://flatcap.github.io/linux-ntfs/ntfs/>.
- **Microsoft's NTFS file system reference** — partial official docs.

## v1 Non-Goals

- LZNT1 compression read (deferred; write never)
- EFS encryption
- Reparse points / junctions / symlinks (enum only, no write)
- Volume Shadow Copy
- Defragmentation
- POSIX→NT ACL mapping (use a sane default SD inherited from volume root)

## Toolchain Requirements

- macOS 15.4+ Sequoia on Apple Silicon
- Xcode 16.3+
- Apple Developer Program account only for off-machine distribution; for personal-use signing, free signing + `systemextensionsctl developer on`
- Linux VM (UTM/lima) with `ntfs-3g`, `ntfsprogs`, `mkntfs`, `ntfsfix` for fixture generation and cross-validation

## Conventions

- **Files:** Swift filenames match the primary type (`BootSector.swift` → `struct BootSector`).
- **Tests:** XCTest. Fixtures live in `Tests/NTFSCoreTests/Fixtures/*.img` (Git LFS for anything >1 MB).
- **Errors:** Typed `NTFSError` enum, no `fatalError` in library code.
- **Endianness:** NTFS is little-endian on disk; always read via explicit `UInt32(littleEndian:)`-style accessors.
- **Async:** prefer `async`/`await`. `BlockDevice` ops are async.
- **No GPL code in the repo.** Reference NTFS-3G / `fs/ntfs3` for design ideas only; never copy code.
