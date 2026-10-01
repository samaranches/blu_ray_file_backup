#!/usr/bin/env bash
# Restore the original archive from a backup (the contents of a mounted Blu-Ray).
# Usage: restore_backup.sh <path_to_backup> [destination_dir]
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat >&2 <<EOF
Usage: $0 <path_to_backup> [destination_dir]

  path_to_backup    directory with the backup contents (volumes, .par2, manifest.txt)
  destination_dir   where to save the archive (default: the current folder)

Algorithm: space check -> copy from the disc -> par2 verify ->
par2 repair on damage (fixes both manifest.txt and the volumes) ->
rejoining the volumes -> size, sha256 and mtime verification per manifest.txt.
A damaged or lost manifest.txt is restored by par2 repair, because it is
part of the PAR2 set.
EOF
}

[[ $# -ge 1 && $# -le 2 ]] || { usage; exit 1; }

SRC=$1
DEST=${2:-.}

for tool in par2 sha256sum stat cat du df awk; do
    command -v "$tool" >/dev/null 2>&1 || die "utility not found: $tool"
done

[[ -d $SRC ]] || die "backup directory not found: $SRC"

shopt -s nullglob
src_volumes=()
for f in "$SRC"/*.part.*; do
    [[ $f =~ \.part\.[0-9]+$ ]] && src_volumes+=("$f")
done
src_pars=("$SRC"/*.par2)
shopt -u nullglob

(( ${#src_volumes[@]} >= 1 )) || die "no volumes (*.part.NNN) found in $SRC"
(( ${#src_pars[@]} >= 1 )) || die "no PAR2 files (*.par2) found in $SRC"

IDX=""
for p in "${src_pars[@]}"; do
    [[ $(basename -- "$p") != *.vol*.par2 ]] && { IDX=$p; break; }
done
[[ -n $IDX ]] || IDX=${src_pars[0]}

read_manifest() {
    local d=$1 k v
    M_NAME= M_SIZE= M_SHA= M_MTIME= M_COUNT= M_VSIZE=
    [[ -f $d/manifest.txt ]] || return 1
    while IFS='=' read -r k v || [[ -n ${k:-} ]]; do
        case $k in
            ARCHIVE_NAME)   M_NAME=$v ;;
            ARCHIVE_SIZE)   M_SIZE=$v ;;
            ARCHIVE_SHA256) M_SHA=$v ;;
            ARCHIVE_MTIME)  M_MTIME=$v ;;
            VOLUME_COUNT)   M_COUNT=$v ;;
            VOLUME_SIZE)    M_VSIZE=$v ;;
        esac
    done < "$d/manifest.txt"
    [[ -n $M_NAME && -n $M_SIZE && -n $M_SHA && -n $M_COUNT && -n $M_VSIZE ]] || return 1
    [[ $M_SIZE =~ ^[0-9]+$ && $M_COUNT =~ ^[0-9]+$ && $M_VSIZE =~ ^[0-9]+$ ]] || return 1
    [[ $M_SHA =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ $M_NAME != */* && $M_NAME != -* ]] || return 1
    [[ $M_MTIME =~ ^[0-9]+$ ]] || return 1
    return 0
}

if ! read_manifest "$SRC"; then
    echo "WARNING: manifest.txt is missing or damaged — it will be restored via par2 repair" >&2
    fb=$(basename -- "${src_volumes[0]}")
    [[ $fb =~ ^(.*)\.part\.[0-9]+$ ]] || die "failed to derive the archive name from the volume name: $fb"
    M_NAME=${BASH_REMATCH[1]}
fi

mkdir -p -- "$DEST"
[[ -w $DEST ]] || die "the destination is not writable: $DEST"
FINAL="$DEST/$M_NAME"
[[ -e $FINAL ]] && die "file already exists: $FINAL"

VOL_BYTES=0
for f in "${src_volumes[@]}"; do
    VOL_BYTES=$(( VOL_BYTES + $(stat -c%s -- "$f") ))
done
EST_SIZE=${M_SIZE:-$VOL_BYTES}
SRC_SIZE=$(du -sb -- "$SRC" | awk '{print $1}')
SLACK=$(( EST_SIZE / 20 + 100000000 ))
NEEDED=$(( SRC_SIZE + EST_SIZE + SLACK ))
FREE_DEST=$(df -B1 -P -- "$DEST" | awk 'NR==2{print $4}')
if (( FREE_DEST < NEEDED )); then
    die "not enough space in '$DEST': available $(awk -v b="$FREE_DEST" 'BEGIN{printf "%.2f", b/1000000000}')GB, needed ~$(awk -v b="$NEEDED" 'BEGIN{printf "%.2f", b/1000000000}')GB (a copy of the backup + the rejoin + slack)"
fi

WORK=$(mktemp -d -- "$DEST/.restore_work.XXXXXX")
trap 'echo "The work folder is kept for manual recovery: $WORK" >&2' ERR

echo "==> Copying the backup from the disc into the work folder..."
cp -r -- "$SRC"/. "$WORK"/
chmod -R u+rwX -- "$WORK"

IDXB=$(basename -- "$IDX")
echo "==> Integrity check (par2 verify)..."
if ! (cd -- "$WORK" && par2 verify "$IDXB"); then
    echo "==> Damage detected, restoring (par2 repair)..."
    (cd -- "$WORK" && par2 repair "$IDXB")
    (cd -- "$WORK" && par2 verify "$IDXB") || die "verify failed after repair — not enough recovery data"
fi

read_manifest "$WORK" \
    || die "manifest.txt is not valid after par2 repair (old-format backups without the manifest in the PAR2 set are not supported)"

FINAL="$DEST/$M_NAME"
[[ -e $FINAL ]] && die "file already exists: $FINAL"

shopt -s nullglob
work_volumes=()
for f in "$WORK"/*.part.*; do
    [[ $f =~ \.part\.[0-9]+$ ]] && work_volumes+=("$f")
done
shopt -u nullglob

(( ${#work_volumes[@]} == M_COUNT )) || die "found ${#work_volumes[@]} volumes, but manifest.txt says $M_COUNT"

NV=${#work_volumes[@]}
for (( i=0; i<NV-1; i++ )); do
    vsz=$(stat -c%s -- "${work_volumes[i]}")
    (( vsz == M_VSIZE )) || die "volume $(basename -- "${work_volumes[i]}"): size $vsz, but VOLUME_SIZE from the manifest is $M_VSIZE"
done
LAST_EXPECT=$(( M_SIZE - (NV-1)*M_VSIZE ))
LAST_GOT=$(stat -c%s -- "${work_volumes[NV-1]}")
(( LAST_GOT == LAST_EXPECT )) || die "last volume: size $LAST_GOT, expected $LAST_EXPECT (ARCHIVE_SIZE − (N−1)×VOLUME_SIZE)"

TMP_OUT="$DEST/.restoring.$$.${M_NAME##*.}"
echo "==> Rejoining ${#work_volumes[@]} volumes into $M_NAME..."
cat -- "${work_volumes[@]}" > "$TMP_OUT"
mv -- "$TMP_OUT" "$FINAL"

FS=$(stat -c%s -- "$FINAL")
[[ $FS == "$M_SIZE" ]] || die "restored file size ($FS) does not match the manifest ($M_SIZE)"
GOT=$(sha256sum -- "$FINAL" | awk '{print $1}')
[[ $GOT == "$M_SHA" ]] || die "sha256 mismatch! The file $FINAL is damaged"
touch -d "@$M_MTIME" -- "$FINAL" || echo "WARNING: failed to restore the file modification time" >&2

rm -rf -- "$WORK"
trap - ERR

echo "==> Done: $FINAL ($(awk -v b="$FS" 'BEGIN{printf "%.2f", b/1000000000}')GB, sha256 OK, mtime restored)"
