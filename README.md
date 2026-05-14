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

Phase 1.5 will use [`scripts/make_test_images.sh`](scripts/make_test_images.sh) to call `mkntfs` inside a Linux container/VM and emit NTFS `.img` fixtures into `Packages/NTFSCore/Tests/NTFSCoreTests/Fixtures/`. For Phase 1 boot-sector tests, fixtures are not yet required — tests use hand-crafted 512-byte byte literals in source.

## License

TBD (personal-use prototype; will be decided before any v1 release). NTFS implementation is a clean-room Swift port from public on-disk format documentation; no GPL'd code is copied into this repo.
