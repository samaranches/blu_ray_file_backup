# Blu-Ray Archive Backup with PAR2 Recovery

> **TL;DR: this is a self-contained backup of a single file. Restore it with one command:**
> ```bash
> ./restore_backup.sh /path/to/disc ~/where_to_restore   # needs the par2 package (apt install par2)
> ```
> The script sits next to this file. Below is what this data format is, plus the
> manual way, should the scripts be unavailable.

## What this data format is

A self-contained backup of a **single file** (an archive), prepared for burning
to Blu-Ray (it works for storage on any other medium just as well). Files in
the directory:

| File | What it is |
|---|---|
| `<archive_name>.part.000 … .part.NNN` | The file being backed up, split into volumes (~512MB each). Concatenating the volumes in numeric order reproduces the original file byte-for-byte |
| `<archive_name>.par2`, `*.vol*.par2` | PAR2 recovery data: redundant blocks that can rebuild damaged volumes (sized to use all the free space of the disc, ~20–30%) |
| `manifest.txt` | Metadata: name, size, sha256, mtime of the archive, volume count and size. **Included in the PAR2 set**: a damaged/lost manifest is restored by `par2 repair` along with the volumes |
| `restore_backup.sh`, `prepare_backup.sh`, `README.md` | The restore script, the prepare script (for making a new backup) and this documentation |

## How to get the saved file back

**Automatically** (Linux; needs the `par2` package, e.g. `sudo apt install par2`):

```bash
./restore_backup.sh /path/to/mounted/disc ~/restored
```

The script checks integrity, repairs damaged volumes when necessary, rejoins
the file and verifies its sha256. The source may be read-only.

**Manually** (if the scripts are unavailable):

```bash
# 1. Copy ALL disc contents into one folder on the HDD, then inside it:
par2 verify <archive_name>.par2        # check; if damaged:
par2 repair <archive_name>.par2        # rebuild the volumes from recovery blocks
cat <archive_name>.part.* > <archive_name>   # rejoin (zero-padded suffixes keep the order correct)
sha256sum <archive_name>               # compare with ARCHIVE_SHA256 from manifest.txt
```

If `par2 repair` reports a lack of recovery blocks — more is damaged than the
built-in redundancy covers; restore the files from another copy of the disc.

### Scratched disc

`restore_backup.sh` copies the disc contents with plain `cp`. If a sector is
unreadable (an I/O error), the copy aborts — in that case copy the contents
to the HDD manually:

- readable files — with plain `cp`;
- unreadable volumes — with `ddrescue --force <volume> <where>/<volume>`
  (the `gddrescue` package; optional, not a dependency of the scripts): it
  fills unreadable gaps with zeros, preserving size and offsets. For par2
  these are ordinary damaged blocks — `par2 repair` will rebuild them from
  the recovery data; the fewer "holes" ddrescue leaves, the less recovery
  is consumed;
- if a volume cannot be salvaged even by ddrescue — simply do not copy it:
  a missing file is equivalent to a fully damaged one for par2 and is
  recoverable too (at the cost of a whole volume's worth of recovery).

Then run the restore on the local folder:

```bash
./restore_backup.sh ~/copied_from_disc ~/restored
```

### Windows

Bash scripts do not run natively on Windows. Two routes:

1. **WSL** — `restore_backup.sh` runs as is, including `par2`
   (`sudo apt install par2` inside WSL; the disc is mounted under `/mnt/<letter>`).
2. **Natively, without the scripts**. Distributions and commands differ from
   Linux:

   | Task | Linux | Windows |
   |---|---|---|
   | PAR2 (console) | the `par2` package | official par2cmdline binaries from [GitHub Releases](https://github.com/Parchive/par2cmdline/releases) (`...-win-x64.zip`; same commands: `par2 verify`, `par2 repair`) |
   | Rejoining volumes | `cat <name>.part.* > <name>` | `cmd /c copy /b <name>.part.* <name>` (zero-padded suffixes — alphabetical order matches numeric) |
   | Hash | `sha256sum <file>` | `certutil -hashfile <file> SHA256` |

   Compare the hash with the `ARCHIVE_SHA256` value from `manifest.txt`.

---

Below is the repository documentation for the scripts.

**Single-file backup** (splitting into volumes + PAR2) — this README and the
`prepare_backup.sh` / `restore_backup.sh` pair. **Directory (photo library)
backup without splitting** — see `prepare_dir.sh` / `restore_dir.sh` and
`README_dir.md`.

A pair of Linux scripts: preparing a large archive for Blu-Ray burning
(splitting into volumes + PAR2 recovery data that fills the remaining disc
space) and restoring the original archive from a mounted (including
scratched) disc.

## Requirements

- Linux, bash
- `par2` / `par2create` / `par2verify` (tested on par2cmdline 1.3.0 and 1.4.0)
- coreutils: `split`, `sha256sum`, `stat`, `awk`, `du`, `df`
- `zip` is NOT needed

## prepare_backup.sh

```
prepare_backup.sh <file_to_backup(archive)> <disc_size_GB> [output_dir]
```

| Parameter | Required | Default |
|---|---|---|
| the file to back up (an archive, e.g. `backup.zip`) | yes | — |
| target disc size in GB (e.g. `25`) | yes | — |
| output directory | no | `./backup_folder` |

The `VOLUME_MB` environment variable overrides the volume size in MB (used in
tests; by default volumes are ~512MB). The `MARGIN_PERCENT` variable sets the
safety margin as a % of the disc capacity (default 2%, but at least 50MB —
kept in mind for a 700MB CD).

### Algorithm

1. **Validations**: tools are available; the file exists and is readable; the
   disc size is a number > 0; the output directory is empty; the file size is
   smaller than the target size at least by the margin (2% of the disc,
   minimum 50MB).
2. **Redundancy calculation**: the PAR2 percentage = all the space left after
   the margin, rounded down by 1% (so that the PAR2 index files do not exceed
   the limit). A final check: the resulting size does not exceed the disc
   capacity.
3. **File operations**: `split` into ~512MB volumes, balanced (names
   `<file>.part.NNN`), `sha256sum` and the mtime of the file →
   `manifest.txt`, `par2 create -r<percent> -s<block>` (the block size is
   chosen so that there are ≥ 2000 source blocks), then a mandatory
   `par2 verify`.
4. **Disc self-sufficiency**: both scripts and the documentation are copied
   into the root of the output directory: `prepare_backup.sh`,
   `restore_backup.sh` and `README.md`.

### Examples

```bash
./prepare_backup.sh backup.zip 25              # 25GB disc → ./backup_folder
./prepare_backup.sh backup.zip 50 /mnt/out    # 50GB disc → /mnt/out
VOLUME_MB=100 ./prepare_backup.sh data.img 0.7     # 700MB CD: 100MB volumes
MARGIN_PERCENT=5 ./prepare_backup.sh backup.zip 25 # a 5% margin instead of 2%
```

## restore_backup.sh

```
restore_backup.sh <path_to_backup> [destination_dir]
```

| Parameter | Required | Default |
|---|---|---|
| path to the mounted Blu-Ray contents | yes | — |
| folder for the restored archive | no | current dir |

### Algorithm

1. **Discovery**: the volumes `*.part.NNN` and the PAR2 files; the entry point
   into the set is the index `*.par2`, or any `.vol*` file of the set if the
   index is lost. `manifest.txt` is not required to start.
2. **Checks**: the destination is writable; the free space is sufficient
   including intermediate operations:
   `backup_size + archive_size + slack` (5% + 100MB).
3. **Copying** the whole backup content into the work folder
   `.restore_work.XXXXXX` inside the destination (the source may be read-only,
   like a mounted disc; nothing is ever written there). On unreadable sectors
   the copy aborts — see the “Scratched disc” section above.
4. `par2 verify`; on damage — `par2 repair` and a repeated verify. The repair
   fixes `manifest.txt` too (it is part of the PAR2 set). If the manifest is
   still invalid after the repair — a clear refusal (the old backup format
   without the manifest in the PAR2 set is not supported).
5. **Rejoining** the volumes (only files with a purely numeric suffix
   `.part.NNN` — the `.part.NNN.1` backups of damaged files left by par2 are
   discarded). Before rejoining, the size of every volume is checked against
   `VOLUME_SIZE` from the manifest (the last one by the formula
   `ARCHIVE_SIZE − (N−1)×VOLUME_SIZE`): truncation is caught before the
   rejoin.
6. **Verification** of the size and sha256 against `manifest.txt`, restoring
   the mtime (`touch -d @ARCHIVE_MTIME`). The work folder is removed.
   On any error the work folder is kept — the restore can be finished
   manually with `par2 repair`.

### Example

```bash
./restore_backup.sh /media/$USER/BLURAY_BACKUP ~/restored
```

## Burning to disc

The output directory contents are written to the Blu-Ray as is (the disc
root). For files > 4GB use UDF (the default volumes are ≤ 512MB, so ISO9660
works too). After burning, mount the disc and run
`par2 verify <archive_name>.par2` — only then is the backup considered ready.

## Multi-disc spanning (manual)

An archive larger than one disc can be spread across several media without
any script changes — the backup consists of many equal small files, and their
placement order does not matter. Example: a 60GB archive across three 25GB
discs.

1. **Prepare** — specify a “virtual disc” equal to the total capacity of the
   media:
   ```bash
   ./prepare_backup.sh big.zip 75 out     # 3 × 25GB: 2% margin (~1.5GB), PAR2 ~21%
   ```
2. **Distribution** — spread the files from `out` across the blanks in any
   order. Recommendation: distribute the `*.vol*.par2` recovery files evenly
   (round-robin), and put `manifest.txt`, the index `big.zip.par2`, the
   scripts and `README.md` on the first disc. Make sure each disc stays below
   its limit (the margin is already accounted for in the calculation).
3. **Restore** — merge the contents of all discs into one folder and run the
   restore on it:
   ```bash
   mkdir merged && cp -r /media/disc1/. /media/disc2/. /media/disc3/. merged/
   ./restore_backup.sh merged ~/restored
   ```

Verified by test TC18: a set spread across two “discs” (the manifest and the
index par2 only on the first one) restores from the consolidated folder
bit-for-bit, including the mtime.

**Limitation**: the complete loss of one of the N discs loses ~1/N of the
data along with its share of the recovery blocks — with round-robin
distribution the recovery is impossible if the redundancy is < ~100/N %
(for 3 discs — 34%). Local damage (scratches) within the total PAR2 volume is
repaired as usual. Also mind the HDD space: the restore needs ~2× the backup
size + the archive size (a copy of the set + the work folder + the rejoin).

## Testing methodology

The testing was performed on the developer's machine (par2cmdline 1.3.0,
Linux, bash) on two data sets:

- **synthetic**: 20MB from `/dev/urandom`, a 0.6GB disc, `VOLUME_MB=5`
  → 4 volumes, 399% redundancy (checking extreme values);
- **real**: a 1.75GB tarball (`CLion-2026.1.2.tar.gz`), a 2.5GB disc,
  `VOLUME_MB=500` → 4 volumes, 13% redundancy.

| # | Scenario | Expectation | Result |
|---|---|---|---|
| TC1 | Negative checks of prepare/restore: no arguments, missing file, non-numeric disc size, file larger than the disc, non-empty output dir, restore with a non-existing dir | A clear error, exit code 1 | OK (a missing manifest.txt is no longer an error — see TC13) |
| TC2 | prepare on the synthetic set: splitting, manifest, par2 create+verify, copies of the scripts, the total within the disc | rc=0, `par2 verify` OK | OK, 4 volumes, total 0.10GB of 0.6GB |
| TC3 | 2MB of damage in the middle of a volume + a read-only source (a mounted-disc emulation) → restore | the volume repaired, sha256 equals the original | OK (114 recovery blocks used, sha256 matched) |
| TC4 | restore of an undamaged backup (synthetic set) | verify without repair, sha256 OK | OK |
| TC5 | prepare of the real 1.75GB archive for a 2.5GB “disc” | total ≤ 2.5GB, verify OK | OK: 4 volumes × 500MB, PAR2 13% (~0.25GB), total 1.98GB, 26 s |
| TC6 | 30MB of damage in a volume of the real backup (2% of the disc) → restore | repair, sha256 equals the original archive | OK, 19 s, sha256 matched |
| TC7 | A failed validation must leave no artifacts (the default directory) | the directory is not created | OK (after moving `mkdir` past the validation block) |
| TC8 | mtime preservation: “2020-05-17 13:45:12 UTC” set, prepare → restore | the mtime restored bit-for-bit (second precision) | OK: 1589723112 → 1589723112 |
| TC9 | Old format: a manifest without ARCHIVE_MTIME → restore | a clear refusal: the old format is not supported | OK: rc=1, a clear message |
| TC10 | `manifest.txt` overwritten with garbage (150 bytes) → restore | the manifest healed by `par2 repair`, sha256+mtime verified | OK: the bytes and mtime are identical |
| TC11 | `manifest.txt` deleted → restore | the manifest recreated by `par2 repair` (it is in the PAR2 set) | OK, sha256 OK |
| TC12 | The manifest and volume 001 damaged simultaneously → restore | both restored by the repair | OK, the bytes are identical |
| TC13 | Old format: a PAR2 set without the manifest, the manifest deleted → restore | a clear refusal: the old format is not supported | OK: rc=1, a clear message |
| TC14 | The index `<name>.par2` deleted (`.vol*` remain) → restore | entering the PAR2 set via a vol file | OK, sha256 OK |
| TC15 | CD scenario: a 600MB archive, a 0.7GB disc, `VOLUME_MB=100`, a 2% margin (min 50MB) | 6 volumes × 100MB, PAR2 7%, the total within the disc; restore: sha256+mtime OK | OK: 0.64GB of 0.7GB |
| TC16 | After the defaults change (a 2% margin, 512MB volumes): the manifest and volume 002 of the real archive damaged simultaneously → restore | both healed by the repair, the bytes and mtime are identical | OK |
| TC17 | A volume truncated by 1000 bytes → restore | the truncation fixed by `par2 repair` before the rejoin; the result is byte-for-byte | OK (the `VOLUME_SIZE` check is extra insurance; with a live PAR2 it does not trigger) |
| TC18 | Span across 2 media: prepare 80MB for a 0.15GB “virtual disc” (PAR2 24%), spread across two folders (the manifest+index only on the first one, read-only), consolidation, restore | entry via the vol file from the “second disc”, the bytes and mtime are identical | OK: sha256 matched, the mtime restored |

The success criterion for the restore is in all cases the byte-for-byte match
of the restored file's sha256 with the original archive's hash from
`manifest.txt`.

Note: TC1–TC14 were run under the previous defaults (a 0.5GB margin, ~2GiB
volumes); TC15–TC17 — under the current ones (a 2% margin, min 50MB, ~512MB
volumes). TC9 was run before backward compatibility was dropped (the
ARCHIVE_MTIME key was optional back then, and restore simply skipped the mtime
restoration); the current expectation is a refusal, as reflected in the
table. The current full cycle (prepare → happy restore → damage restore) on
the real 1.75GB archive was re-run after the defaults change — green. The
happy paths of both modes were re-verified on par2cmdline 1.4.0 (2026-10).

### A bug found and fixed

Found in TC3: `par2 repair` saves the damaged volume as
`<name>.part.002.1`, and the `.part.*` glob in the restore picked it up as a
fifth volume. Fixed — only files with a numeric suffix (`.part.[0-9]+`) are
selected now. A re-run of TC3/TC6 is green.

### Testing limitations

- No real BD-R burning/reading was performed (no drive); scratches were
  emulated by overwriting random bytes and by read-only permissions on the
  source.
- The “not enough space” check in the restore (the `NEEDED` formula) was
  verified logically only; filling a disk to capacity was not performed.
- Damage was tested in one volume per run; simultaneous damage of several
  volumes was not tested (PAR2 restores up to the total volume of recovery
  data across all volumes, which follows from the mechanics of the format).

## Notes

- **A damaged `manifest.txt` is not fatal**: it is included in the PAR2 set
  and is restored by the same `par2 repair` (it is even recreated after a
  complete deletion). Backups of the old format (without the manifest in the
  PAR2 set) are not supported. A second copy of the file is not required.
- The redundancy margin: 2% of the disc capacity, minimum 50MB (overridden
  by `MARGIN_PERCENT`).
- At most 999 volumes (a limitation of the digit count in `split` names).
- `par2` versions ≥ 1.3 are multi-threaded: preparing 1.75GB with 13%
  redundancy takes ~26 seconds.

## Fun fact: what “Computing Reed Solomon matrix” is

When `par2 repair` prints `Computing Reed Solomon matrix … Solving …`, it is
solving a linear system — that is where all the recovery magic happens. Our
scripts do not implement this math: they merely pick the `-s<block>` and
`-r<percent>` parameters for `par2`.

- **Data → vectors.** Everything under protection (the volumes +
  `manifest.txt`) is cut into `k` equal-size blocks (here 64KB–16MB, targeting
  ~2000 blocks).
- **The matrix is the mixing recipe.** Every recovery block is a linear
  combination of the source ones: `c_j = Σ a_ji·s_i` over the finite field
  GF(2¹⁶) (addition = XOR, multiplication is table-based). The coefficients
  `a_ji` form the Reed–Solomon `r×k` matrix, where `r` is the number of
  recovery blocks.
- **The key property of the field**: any `k` of the `k+r` equations are
  linearly independent. The loss of **any** ≤ r blocks — whether pieces of one
  volume, or the manifest together with a volume (TC12) — is always
  recoverable: from the surviving `k` equations the system is solved uniquely
  (Gaussian elimination, which is exactly the “Solving”).

Hence the design decisions of this backup:

- **Recovery granularity = the block size, not the volume size.** An X MB
  scratch consumes ≈ X/block_size recovery blocks — that is why choosing
  512MB vs 100MB barely affects survivability; the volume matters only for
  the worst case of “the file is unreadable at the filesystem level”.
- **`-r` = the height of the matrix.** We give the recovery data all the free
  space of the disc — this is the maximum r.
- **The death limit**: when spanning across N media, the death of a whole
  disc eats ~1/N of the system's rows; the recovery is possible only if
  1/N < r/(k+r) — the same “redundancy ≥ ~100/N %” boundary from the
  multi-disc section.

Formally, the construction of the matrix (Vandermonde bases reduced to the
systematic form with an identity upper part) is described in the PAR2.0
specification — `par2spec.pdf` of the Parchive project.
