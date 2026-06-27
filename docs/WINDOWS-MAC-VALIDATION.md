# Windows + macOS Validation Runbook (fix/mft-overgrow → main)

**Status:** the corruption fix is merged to `main` (merge commit `a5815ff`). All
automated checks pass on macOS. The **one remaining gate is manual hardware
validation on a real Windows PC** — this doc is the step-by-step to close it,
plus the macOS-side checks to confirm the volume is still good there.

**Read this first — the test spans two machines:**

- `ntfsctl` is a **macOS / Apple-Silicon** tool. It does **not** run on Windows.
- So the flow is always: **a Mac writes** files to the Windows-formatted drive
  with the new build → **eject cleanly** → **plug into Windows** → `chkdsk` +
  Explorer checks.
- The Windows PC is the *judge*, not the writer.

---

## 0. What was broken and what changed

Files copied to a real Windows-formatted 4 TB drive showed as **0 KB**, refused
to open (**"you do not have permission"**), or **corrupted the whole volume**.
That was **three independent bugs** — fixing any one alone still left the
symptom, which is why earlier retries failed. All three are fixed on `main`:

| # | Symptom | Root cause | Fix |
|---|---------|-----------|-----|
| 1 | Volume corrupted; file bytes land inside MFT records; MFT ~11× too big | `growMFTDataByClusters` allocated MFT growth from the global low cluster hint (shared with file data). On a Windows layout (`$MFT` at ~3 GiB with a reserved MFT zone) growth landed far from the base, never merged, fragmented down into the file-data region. | New `allocateMFTGrowthClusters(count:near:)` allocates at the `$MFT.$DATA` runlist tail — its own lane, like ntfs-3g's MFT_ZONE policy. `Volume.swift` |
| 2 | Files show **0 KB** in Explorer and won't open | Windows reads file size from the parent's `$I30` index entry; `cp -r` bulk-insert mode skipped the size refresh. | `createFile(dataSize:)` stamps real/allocated size into **both** `$FILE_NAME` copies (the file's record **and** the `$I30` entry) at create time; `cp` passes the source size. `Volume.swift`, `MFTRecordBuilder.swift`, `Cp.swift` |
| 3 | **"You do not have permission to open this file"** | Created records carried no security info. A Windows v3.x volume denies all access to a file with no `security_id`. | `createFile` inherits the parent directory's `security_id` (falling back to the volume root's) into a 72-byte v3 `$STANDARD_INFORMATION`; inline `$SECURITY_DESCRIPTOR` fallback for volumes with no id to inherit. `Volume.swift`, `MFTRecordBuilder.swift` |
| + | Tooling fails on real 4 TB drives (`EINVAL`) | A single `read(2)`/`write(2)` to a raw device (`/dev/rdiskN`) is capped at MAXPHYS (~1 MiB) and must be block-aligned. The 122 MB `$Bitmap` read and 8-byte `$MFT $BITMAP` writes violated this. | `FileHandleBlockDevice` now chunks under 1 MiB and block-aligns, with sub-block read-modify-write. `BlockDevice.swift` |

**Verified on macOS (automated):** full NTFSCore suite + 24 `ntfsctl` tests pass;
the ntfs-3g Docker oracle passes including a 3,000-file run that forced 12 MFT
growth rounds — every round allocated at the tail and merged into a
single-extent runlist, `ntfsfix` clean, byte-exact read-back.

---

## 1. The Format feature — why it's still disabled (and the one thing to fix)

The user-facing `ntfsctl mkntfs` was **removed** in v0.7.2 because its volumes
were rejected by both Windows and macOS. The internal `Volume.formatNTFS`
remains only as a test-fixture builder.

**New finding (measured against real ntfs-3g):** the earlier formatter blockers
(boot sector, backup boot sector, `$MFT`/`$MFTMirr`) are now **clean**. The
**only remaining mount blocker is one missing metafile:**

```
ntfsfix -n  →  Failed to open $Secure: No such file or directory
```

We declare the volume as NTFS 3.1 but never create the **`$Secure`** metafile
(MFT record 9: a `$SDS` data stream + `$SDH`/`$SII` index B-trees). Every real
NTFS driver hard-requires `$Secure` on a v3.x volume.

**To bring the format feature back (future work, not required for the fix above):**
1. Build a minimal valid `$Secure` (real `mkntfs` writes ~4 canned security
   descriptors in `$SDS` with matching `$SDH`/`$SII` B-trees — clean-room from
   the flatcap/linux-ntfs layout docs).
2. Re-run the Docker oracle: `scripts/ntfs-oracle.sh` style `ntfsfix -n`.
3. Validate **once** on real Windows `chkdsk` before re-exposing any CLI.

**Until then: format drives on Windows** (right-click → Format → NTFS) or with
real `mkntfs` on Linux. `ntfsctl` operates on an **existing** NTFS volume.

---

## 2. macOS side — write to the drive (the "writer" role)

Do this on whichever Mac has the drive attached. (Your other open session can
be the writer if the drive is on that Mac; otherwise do it here.)

```bash
# 1. Get the fix
cd /path/to/ntfs-tool
git checkout main
git pull origin main          # must include merge commit a5815ff

# 2. Build the CLI (release)
swift build -c release --package-path Tools/ntfsctl
BIN="$(pwd)/Tools/ntfsctl/.build/release/ntfsctl"

# 3. Find the NTFS drive (DO NOT guess the disk number)
"$BIN" scan                   # or: diskutil list
#   note the partition, e.g. /dev/disk4s1

# 4. IMPORTANT: the drive must NOT be mounted read-write by macOS while
#    ntfsctl writes to the raw device. Unmount the volume (keep the disk):
diskutil unmount /dev/disk4s1   # unmounts the filesystem, leaves device

# 5. Sanity-read first (non-destructive)
"$BIN" info /dev/disk4s1
"$BIN" list /dev/disk4s1

# 6. Copy a test corpus onto the drive
#    Use a folder with MANY files (forces MFT auto-grow — the bug path) and a
#    mix of small + large files. A few thousand files is ideal.
"$BIN" cp -rT /path/to/test-corpus /dev/disk4s1 /validation --progress

# 7. Verify before ejecting (cp already clears the dirty bit on success)
"$BIN" verify --deep /dev/disk4s1     # expect 0 orphans / 0 overlaps / clean
"$BIN" setdirty /dev/disk4s1 0        # only if something left it dirty (0 = clean)

# 8. Eject cleanly (flush) before moving the drive to Windows
diskutil eject /dev/disk4s1
```

**What "good" looks like on macOS here:** `verify --deep` reports 0 orphans,
0 leaked extensions, 0 dangling `$I30`, 0 free-but-referenced, 0 double-allocated,
0 overlap; all runlist clusters audited clean.

---

## 3. macOS side — confirm it still reads back on Mac (the "Mac works" check)

Two layers:

**(a) Our own reader / CLI (authoritative for our bytes):**
```bash
"$BIN" list /dev/disk4s1 /validation                  # files present, real sizes
"$BIN" cat /dev/disk4s1 /validation/<somefile> | shasum   # matches the source
```

**(b) Apple's native driver (`livefiles_ntfs`) — read-only mount in Finder:**
- Re-plug the drive; macOS auto-mounts NTFS **read-only**.
- It should appear in Finder, list folders, and open small files.
- **Known Apple bug, not ours:** `livefiles_ntfs` mis-reads files **> 4 GiB**.
  If a large file looks wrong in Finder but `ntfsctl cat … | shasum` matches the
  source, that's Apple's driver, not our data. (Proven previously via raw `dd`.)

> macOS **write** via Finder needs the FSKit System Extension (`NTFSMountManager`
> app + `systemextensionsctl developer on`). That path is separate and not
> required to validate this fix — the CLI is the supported writer today.

---

## 4. Windows side — validate (the "judge" role)

Plug the ejected drive into the Windows PC.

### 4.1 Filesystem integrity — `chkdsk`
Open **Command Prompt / PowerShell as Administrator**:
```
chkdsk X: /f
```
(replace `X:` with the drive letter)

**PASS:** "Windows has scanned the file system and found no problems," or it
fixes only trivial/cosmetic items. **FAIL:** it reports cross-linked clusters,
bad MFT, security-descriptor errors, or "corrected" file sizes in bulk.

> Capture the **full chkdsk output** (copy the console text) on any failure.

### 4.2 Explorer — the user-visible symptoms
1. Open the drive in File Explorer → the `\validation` folder.
2. **Sizes:** files show their **real size**, not 0 KB. (This was bug #2.)
3. **Open:** double-click a file — it opens, **no "you do not have permission"**
   dialog. (This was bug #3.)
4. **Content:** open a known file and confirm contents are intact (or compare a
   hash — see 4.3). (This was bug #1.)
5. **Properties → Security tab:** the file has an owner/permissions entry (the
   inherited `security_id` resolved).

### 4.3 Content integrity (strongest check)
In PowerShell:
```powershell
Get-FileHash X:\validation\<somefile> -Algorithm SHA1
```
Compare to the source hash you recorded on the Mac (`shasum <source>`). They
must match byte-for-byte.

### 4.4 Round-trip (optional but recommended)
- Copy a new file **onto** the drive from Windows, eject, re-plug into Mac,
  `ntfsctl list` / `cat` it. Confirms Windows-written + Mac-read still agree.

---

## 5. Pass / fail criteria (the gate)

**PASS — the fix is validated, close the gate:**
- `chkdsk /f` clean (or trivial-only).
- Explorer shows real sizes, opens files, no permission error.
- SHA1 of read-back files matches the source.

**FAIL — capture and report:**
- Save full `chkdsk` output, a screenshot of Explorer (sizes / error dialog),
  and the exact `ntfsctl cp`/`verify` console from the Mac.
- Note the corpus shape (file count, smallest/largest sizes).

### Known caveat to watch — small files
Files ≤ 700 bytes are stored **resident** (inside the MFT record). Their
`$FILE_NAME`/`$I30` **allocated-size** hint is rounded up to a cluster, which
real drivers compute differently for resident data. If `chkdsk` reports **minor
size inconsistencies** that it "corrects," this is the most likely source —
note it and we adjust the resident-file size stamping. It is cosmetic, not data
loss, but we want a fully clean `chkdsk`.

---

## 6. Quick reference — your other open session

That session was an `ai-agent-manager` Supervisor run on
`feature/move-and-conflict-semantics` (older work, pre-this-fix). It is **not**
related to this validation. For this task on the other system, just:

```bash
git checkout main && git pull origin main   # gets the fix + this doc
# then follow §2–§4 above for whichever role (Mac writer / Windows judge)
```

Nothing to resume from the Supervisor state for this validation.
