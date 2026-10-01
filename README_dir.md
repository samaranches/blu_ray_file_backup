# Blu-Ray Directory (Photo Library) Backup with PAR2 Recovery

> **TL;DR: this is a self-contained backup of a directory of files (e.g. a photo library).**
> ```bash
> ./restore_dir.sh /path/to/disc ~/where_to_restore   # needs the par2 package (apt install par2)
> ```
> The script sits in `recovery/` next to this file. Intact files can be read
> straight from the disc, without any restoration.

## What this data format is

The files (photos/videos) are stored **as is** — no compression, no splitting
into volumes, the subdirectory structure is preserved. Next to them sits the
service subdirectory `recovery/`:

| File | What it is |
|---|---|
| your files and subdirectories | the directory contents in its original form |
| `recovery/manifest.txt` | a per-file list: sha256, size, mtime and the relative path of every file (a `# KEY=VALUE` header holds the preparation parameters). **Included in the PAR2 set** — restored by `par2 repair` |
| `recovery/<name>.par2`, `recovery/*.vol*.par2` | PAR2 recovery data: redundant blocks against scratches (sized to use all the free space of the disc) |
| `recovery/restore_dir.sh`, `recovery/prepare_dir.sh`, `recovery/README.md` | the restore script, the prepare script (for making a new backup) and this documentation |

The files are not split into volumes: a set of thousands of small files is
“multi-volume” by itself — a scratch damages the blocks of particular files,
and `par2 repair` rebuilds them from the recovery blocks (including fully
lost files).

## How to get the saved files back

**Automatically** (Linux; needs the `par2` package):

```bash
./restore_dir.sh /path/to/mounted/disc ~/restored
```

The script copies the disc contents to the HDD, verifies and — if damaged —
restores the files, checks every file's sha256 against the manifest and
restores the modification times (mtime). The result is
`~/restored/<directory_name>/`. The source may be read-only.

**Manually** (if the scripts are unavailable; the commands are run from the
backup root, the paths inside the PAR2 set are relative):

```bash
# 1. Copy ALL disc contents (files + recovery/) into one folder, then:
cd <copied_folder>
par2 verify recovery/<directory_name>.par2   # check; if damaged:
par2 repair recovery/<directory_name>.par2   # restore the files and the manifest
```

If intact files are needed urgently — read them straight from the disc: the
restoration is only needed for the damaged ones.

### Scratched disc

If `cp` dies on an unreadable sector — copy manually: whatever is readable
with plain `cp`; unsalvageable files with `ddrescue --force <file> <where>`
(it fills the holes with zeros, preserving the size — for par2 these are
ordinary damaged blocks). A file that even ddrescue cannot save may simply be
skipped: a missing file is fully damaged for par2 and equally recoverable (at
the cost of a whole file's worth of recovery). Then run `restore_dir.sh` on
the local folder.

### Windows

`restore_dir.sh` is a bash script: use WSL, or natively
([par2cmdline for Windows](https://github.com/Parchive/par2cmdline/releases),
`...-win-x64.zip`; the commands are the same — from the root of the copied
folder: `par2 verify recovery\<name>.par2`, on damage `par2 repair …`).

---

## Script documentation

An addition to the `prepare_backup.sh`/`restore_backup.sh` pair (single-file
backup with volume splitting — see the repository README). This part covers
directory mode.

### prepare_dir.sh

```
prepare_dir.sh <directory> <disc_size_GB>
```

1. **Validations**: the directory exists; there is no `recovery/` inside yet
   (re-preparation is not supported — delete `recovery/` first); the disc
   size is a number; no tabs/newlines in the names; symlinks are skipped
   (with a warning).
2. **Calculation**: the `MARGIN_PERCENT` margin (default 2%, min 50MB), the
   PAR2 percentage — all the remaining space; the block size is chosen for
   ~2000 blocks over the total volume.
3. **Files**: `recovery/manifest.txt` (sha256/size/mtime/path of every
   file), `par2 create` over all the files + the manifest (**no splitting or
   copying** — recovery/ is created next to the data), a mandatory
   `par2 verify`, copies of the scripts and of the README into `recovery/`.

### restore_dir.sh

```
restore_dir.sh <backup_root> [destination_dir]
```

A free-space check (2× the backup size + slack) → copying into a work folder
on the HDD (the source is not modified) → `par2 verify` → `par2 repair` on
damage (fixes both the files and the manifest) → a per-file size and sha256
check against the manifest → publishing into
`<destination>/<directory_name>/` with mtime restoration. On error the work
folder is kept.

### Burning to disc

The directory contents (files + `recovery/`) are written to the Blu-Ray root
(UDF; ISO9660 — if all the names are compatible). After burning, mount the
disc and run `par2 verify recovery/<name>.par2` from the disc root.

### Limitations

- mtime is restored for files; directory mtimes are not preserved.
- Empty subdirectories (without files) do not get into the manifest and are
  not restored.
- Names with tabs/newlines are not supported; symlinks are skipped.
- Re-preparing a directory is possible only after deleting `recovery/`.

## Testing methodology

Directory mode was tested (par2cmdline 1.3.0, Linux, bash) on a copy of a
real photo library: 47 files (JPG/MP4), 154MB, a nested subdirectory with
Cyrillic and spaces in its name. All the runs were on copies in `/tmp`; the
source directory was never modified.

| # | Scenario | Expectation | Result |
|---|---|---|---|
| TC19 | prepare (a 0.25GB disc): a per-file manifest (sha256/size/mtime/path), PAR2 28%, verify OK, scripts+README in recovery/ | rc=0 | OK: recovery 44MB, total 0.20GB of 0.25GB |
| TC20 | happy restore: `diff -r` shows no differences, the mtimes of all files = the manifest | OK | OK: 47/47 |
| TC21 | 2 files corrupted with garbage + 1 deleted + the manifest overwritten + a read-only source → restore | the repair restored everything; the bytes are identical, the mtimes per the manifest | OK |
| TC22 | Negative: a re-prepare with an existing recovery/; a restore without recovery/; 30 of 47 files deleted (beyond the redundancy) | rc≠0, clear messages; on over-damage — a refusal, the work folder kept | OK (1/1/2) |

The restore success criterion is the byte-for-byte match of every file with
its sha256 from the manifest and the mtime match; the directory tree is
identical to the original.

### Bugs found and fixed

1. **The par2 basepath.** When the index `.par2` lives in a subdirectory
   (`recovery/`), par2 silently treats that subdirectory as the basepath and
   ignores all the files outside it (“Ignoring out of basepath source
   file”) — the set ended up consisting of manifest.txt only. Fix:
   `-B<absolute path to the backup root>` in all the calls (create, verify,
   repair). Found in TC19.
2. **A `.1`-file leak.** `par2 repair` renames the damaged originals to
   `<file>.1`; publishing the whole work directory with `cp -a` dragged them
   into the output (49 files instead of 47). Fix: publish strictly per the
   list from the manifest. Found in TC21.
3. **A relative destination.** After the `cd` into the work folder a
   relative `DEST` broke `-B` and the publishing paths (“0 out of N data
   blocks”). Fix: `DEST` is absolutized at startup. Found in TC21.
