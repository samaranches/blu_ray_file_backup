#!/usr/bin/env bash
# Restore a directory (photo library) from a backup: the files + recovery/ with the PAR2 set.
# Usage: restore_dir.sh <backup_root> [destination_dir]
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat >&2 <<EOF
Usage: $0 <backup_root> [destination_dir]

  backup_root      directory with the backup files and the recovery/ subdirectory
  destination_dir  where to restore (default: the current folder);
                   the result is <destination>/<directory_name>/

Algorithm: space check -> copy from the disc -> par2 verify ->
par2 repair on damage (fixes both the files and manifest.txt) ->
per-file sha256 verification -> publishing with mtime restoration.
EOF
}

[[ $# -ge 1 && $# -le 2 ]] || { usage; exit 1; }

SRC=$1
DEST=${2:-.}

for tool in par2 sha256sum find stat awk du df cp; do
    command -v "$tool" >/dev/null 2>&1 || die "utility not found: $tool"
done

[[ -d $SRC ]] || die "backup directory not found: $SRC"
[[ -d $SRC/recovery ]] || die "no recovery/ subdirectory in $SRC (is this a directory backup?)"
[[ -f $SRC/recovery/manifest.txt ]] || die "no $SRC/recovery/manifest.txt"

shopt -s nullglob
pars=("$SRC"/recovery/*.par2)
shopt -u nullglob
(( ${#pars[@]} >= 1 )) || die "no PAR2 files in recovery/"

IDX=""
for p in "${pars[@]}"; do
    [[ $(basename -- "$p") != *.vol*.par2 ]] && { IDX=$p; break; }
done
[[ -n $IDX ]] || IDX=${pars[0]}

mkdir -p -- "$DEST"
[[ -w $DEST ]] || die "the destination is not writable: $DEST"
DEST=$(CDPATH= cd -- "$DEST" && pwd)

SRC_SIZE=$(du -sb -- "$SRC" | awk '{print $1}')
SLACK=$(( SRC_SIZE / 20 + 100000000 ))
NEEDED=$(( 2 * SRC_SIZE + SLACK ))
FREE_DEST=$(df -B1 -P -- "$DEST" | awk 'NR==2{print $4}')
if (( FREE_DEST < NEEDED )); then
    die "not enough space in '$DEST': available $(awk -v b="$FREE_DEST" 'BEGIN{printf "%.2f", b/1000000000}')GB, needed ~$(awk -v b="$NEEDED" 'BEGIN{printf "%.2f", b/1000000000}')GB (a copy of the backup + the restoration + slack)"
fi

WORK=$(mktemp -d -- "$DEST/.restore_work.XXXXXX")
trap 'echo "The work folder is kept for manual recovery: $WORK" >&2' ERR

echo "==> Copying the backup from the disc into the work folder..."
cp -r -- "$SRC"/. "$WORK"/
chmod -R u+rwX -- "$WORK"

IDXB=$(basename -- "$IDX")
echo "==> Integrity check (par2 verify)..."
if ! (cd -- "$WORK" && par2 verify -B"$WORK" "recovery/$IDXB"); then
    echo "==> Damage detected, restoring (par2 repair)..."
    (cd -- "$WORK" && par2 repair -B"$WORK" "recovery/$IDXB")
    (cd -- "$WORK" && par2 verify -B"$WORK" "recovery/$IDXB") || die "verify failed after repair — not enough recovery data"
fi

declare -A M_SHA M_SIZE M_MTIME
ROOT_NAME= FILE_COUNT=0 LINE_COUNT=0 BAD=()
while IFS=$'\t' read -r sha size mtime rel || [[ -n ${sha:-} ]]; do
    if [[ $sha == \#* ]]; then
        line=${sha#'#'}
        line=${line#"${line%%[![:space:]]*}"}
        k=${line%%=*}; v=${line#*=}
        case $k in
            ROOT_NAME)  ROOT_NAME=$v ;;
            FILE_COUNT) FILE_COUNT=$v ;;
        esac
        continue
    fi
    [[ -z ${sha:-} ]] && continue
    LINE_COUNT=$(( LINE_COUNT + 1 ))
    M_SHA[$rel]=$sha
    M_SIZE[$rel]=$size
    M_MTIME[$rel]=$mtime
done < "$WORK/recovery/manifest.txt"

[[ -n $ROOT_NAME ]] || ROOT_NAME=$(basename -- "$(CDPATH= cd -- "$SRC" && pwd)")
[[ $ROOT_NAME != */* && $ROOT_NAME != -* && $ROOT_NAME != recovery* ]] || die "incorrect directory name: $ROOT_NAME"
[[ $FILE_COUNT =~ ^[0-9]+$ ]] || die "no valid FILE_COUNT in manifest.txt"
(( LINE_COUNT == FILE_COUNT )) || die "files in manifest.txt: $LINE_COUNT, but FILE_COUNT = $FILE_COUNT (the manifest was not restored?)"

echo "==> Verifying ${LINE_COUNT} files (size + sha256)..."
cd -- "$WORK"
for rel in "${!M_SHA[@]}"; do
    if [[ ! -f $rel ]]; then
        BAD+=("missing: $rel")
    elif [[ $(stat -c%s -- "$rel") != "${M_SIZE[$rel]}" ]]; then
        BAD+=("size: $rel")
    elif [[ $(sha256sum -- "$rel" | awk '{print $1}') != "${M_SHA[$rel]}" ]]; then
        BAD+=("sha256: $rel")
    fi
done
if (( ${#BAD[@]} > 0 )); then
    printf 'ERROR: %d file(s) not restored:\n' "${#BAD[@]}" >&2
    printf '  %s\n' "${BAD[@]:0:10}" >&2
    (( ${#BAD[@]} > 10 )) && echo "  … and $(( ${#BAD[@]} - 10 )) more" >&2
    die "par2 repair failed to restore some of the files (not enough recovery data)"
fi

OUT="$DEST/$ROOT_NAME"
[[ -e $OUT ]] && die "directory already exists: $OUT"

echo "==> Publishing $FILE_COUNT files into $OUT with mtime restoration..."
mkdir -- "$OUT"
cd -- "$WORK"
for rel in "${!M_SHA[@]}"; do
    d=${rel%/*}
    [[ $d != "$rel" ]] && mkdir -p -- "$OUT/$d"
    cp -p -- "$rel" "$OUT/$rel"
    touch -d "@${M_MTIME[$rel]}" -- "$OUT/$rel" || echo "WARNING: failed to restore mtime: $rel" >&2
done

GOT_COUNT=$(find "$OUT" -type f | wc -l)
(( GOT_COUNT == FILE_COUNT )) || die "files restored: $GOT_COUNT, expected $FILE_COUNT"

rm -rf -- "$WORK"
trap - ERR

echo "==> Done: $OUT ($FILE_COUNT files, sha256 of all files OK, mtime restored)"
