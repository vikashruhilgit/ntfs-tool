# ntfs-tool

Read/write NTFS support for Apple Silicon Macs. Open-source / personal-use project. Three surfaces in one repo:

- **`ntfsctl` CLI** — full read + write against any NTFS device or disk image. **Shippable today.** No FSKit extension or signing required.
- **`NTFSCore` Swift library** — embeddable NTFS reader/writer. 87 unit tests, validated against `ntfs-3g` + a real Windows-formatted 4 TB drive.
- **FSKit System Extension + SwiftUI menu-bar app** — drag-and-drop write in Finder via Apple's modern filesystem framework. Code complete, builds clean; mount UX needs validation against real hardware (see [`docs/STATUS.md`](docs/STATUS.md)).

Built for macOS 15.4+ (Sequoia) on Apple Silicon. Swift 6.0+ / Xcode 16.3+.

## Status (one-line summary)

**v0.1-ready for CLI use; FSKit mount needs SIP-off-or-entitlement validation.** Full status, what's done, what's pending, and the roadmap to v1.0 live in **[`docs/STATUS.md`](docs/STATUS.md)**.

## Quick start — CLI

### Build

```bash
cd Tools/ntfsctl
swift build
# Optional: put it on your PATH
ln -s "$(pwd)/.build/debug/ntfsctl" /usr/local/bin/ntfsctl
```

### Read an NTFS drive

```bash
diskutil list                                            # find a "Microsoft Basic Data" slice
diskutil unmount /dev/disk10s1                           # release Apple's auto-mount
sudo ntfsctl info /dev/disk10s1                          # volume metadata
sudo ntfsctl list --long /dev/disk10s1                   # root directory with MFT record numbers
sudo ntfsctl list --long /dev/disk10s1 /Photos          # list a directory by path
sudo ntfsctl cat /dev/disk10s1 /Photos/vacation.jpg > out.jpg  # by path; streams (no 1 GiB cap)
diskutil mount /dev/disk10s1                             # re-mount via Apple's read-only driver
```

### Write to an NTFS drive

```bash
diskutil unmount /dev/disk10s1
sudo ntfsctl create /dev/disk10s1 hello.txt --parent 44  # parent dir's MFT recnum
echo "Hello from macOS." | sudo ntfsctl write /dev/disk10s1 <new-recnum>
sudo ntfsctl setdirty /dev/disk10s1 0                    # mark clean
diskutil mount /dev/disk10s1                             # Apple's driver now sees the new file
```

### Copy a directory tree (e.g. phone backup) onto NTFS

```bash
diskutil unmount /dev/disk10s1
sudo ntfsctl cp -r ~/PhoneBackup /dev/disk10s1 /Backups/MyPhone   # recursive, streams big files
diskutil mount /dev/disk10s1
```

**Full CLI guide with all subcommands, constraints, and troubleshooting:** **[`docs/CLI.md`](docs/CLI.md)**.

## Quick start — library

`NTFSCore` is a SwiftPM-buildable library. Use it from any Swift project:

```swift
import NTFSCore

let device = try FileHandleBlockDevice(openingFileForUpdateAt: "/dev/disk10s1")
let volume = try await Volume(device: device)

// Read
let entries = try await volume.enumerate(directory: 5)  // root
let bytes = try await volume.readFile(at: someRecordNumber)

// Write
let recnum = try await volume.createFile(named: "new.txt", inDirectory: 5)
try await volume.write(at: recnum, offset: 0, bytes: Data("hi".utf8))
try await volume.setDirty(false)
```

API surface and constraints documented inline in the source.

## Quick start — FSKit extension (manual smoke test)

The FSKit extension lets macOS mount NTFS volumes via our code instead of Apple's read-only driver, exposing write through Finder. Activation requires either:

- **SIP-off + developer mode** (free, ~15 min, fully reversible), or
- **Apple Developer Program + FSKit entitlement request** ($99/yr, 2-14 day wait)

Full procedure (one-time setup, build, activation, mount test) is in **[`docs/STATUS.md`](docs/STATUS.md#1-fskit-mount-validation-on-the-m4-high-value)**.

## Repo layout

```
ntfs-tool/
├── Packages/NTFSCore/                  Swift library — pure NTFS read/write logic
├── Extensions/NTFSFileSystem/          FSKit System Extension target
├── Apps/NTFSMountManager/              SwiftUI menu-bar app
├── Tools/ntfsctl/                      Command-line tool
├── docs/
│   ├── CLI.md                          Detailed ntfsctl walkthrough
│   └── STATUS.md                       What's done, what's pending, roadmap
├── scripts/make_test_images.sh         Docker + mkntfs fixture pipeline
├── project.yml                         xcodegen spec for the Xcode project
└── CLAUDE.md                           Architecture + project conventions
```

## Building everything

```bash
# NTFSCore (no Xcode needed)
cd Packages/NTFSCore && swift build && swift test
# → 87 tests pass

# ntfsctl CLI (no Xcode needed)
cd Tools/ntfsctl && swift build
.build/debug/ntfsctl info ../../Packages/NTFSCore/Tests/NTFSCoreTests/Fixtures/small.img

# FSKit extension + menu-bar app (require Xcode)
brew install xcodegen   # if not installed
xcodegen generate
xcodebuild -project NTFSMountManager.xcodeproj -scheme NTFSMountManager build
xcodebuild -project NTFSMountManager.xcodeproj -scheme NTFSFileSystem build
xcodebuild -project NTFSMountManager.xcodeproj -scheme ntfsctl build
```

## Test fixtures

`scripts/make_test_images.sh` regenerates the committed 4 MiB NTFS test fixture via `mkntfs` in a Debian Docker container. The output `small.img` is committed to the repo so CI doesn't need Docker — only the unit tests reading the fixture run there.

```bash
./scripts/make_test_images.sh         # regenerate the fixture
./scripts/make_test_images.sh --check # verify Docker is reachable
```

**Fixture budget:** total committed fixture footprint must stay below **25 MiB**. The next fixture that would push past 25 MiB triggers migration of `Tests/NTFSCoreTests/Fixtures/` to Git LFS.

## Validation status

| Layer | Validation |
|---|---|
| NTFSCore parsers | ✅ 87 unit tests + real 4 TB Windows-formatted drive |
| Read pipeline (raw block device → bytes) | ✅ Byte-identical to Apple's NTFS driver on real files |
| Write pipeline | ✅ Tests pass + `ntfs-3g` reads back our writes byte-exact via Docker integration test |
| FSKit extension build | ✅ All three Xcode schemes build clean in CI |
| FSKit mount in Finder | ❌ Requires SIP-off or entitlement (see STATUS.md) |
| Windows `chkdsk /f` | ❌ Requires a Windows machine (only you can do) |

Full validation breakdown in [`docs/STATUS.md`](docs/STATUS.md#whats-validated-and-how).

## Project conventions

Architecture, error-handling rules, endianness conventions, etc. live in **[`CLAUDE.md`](CLAUDE.md)**.

## License

**TBD.** This is a personal-use prototype awaiting a license decision (MIT and Apache 2.0 are both viable — the NTFS implementation is a clean-room Swift port from public on-disk format documentation, no GPL code is incorporated). See [`docs/STATUS.md`](docs/STATUS.md#3-license-decision) for the recommendation.
