#!/usr/bin/env bash
# Prepare a directory (photo library) for Blu-Ray backup: PAR2 recovery data
# is created in the recovery/ subdirectory next to the files, without splitting
# or copying.
# Usage: prepare_dir.sh <directory> <disc_size_GB>
set -euo pipefail

MARGIN_PERCENT=${MARGIN_PERCENT:-2}

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat >&2 <<EOF
Usage: $0 <directory> <disc_size_GB>

  directory        directory with files (recursive; the structure is preserved)
  disc_size_GB     target disc size in GB (e.g. 25)

A recovery/ subdirectory is created inside the directory: manifest.txt, the
PAR2 set, copies of both scripts and README.md. The files are not split and
not copied (in-place).
The MARGIN_PERCENT environment variable is the safety margin as a % of the
disc capacity (default 2%, but at least 50MB).
EOF
}

[[ $# -eq 2 ]] || { usage; exit 1; }

DIR=$1
DISC_GB=${2//,/.}

[[ $DISC_GB =~ ^[0-9]+([.][0-9]+)?$ ]] || die "invalid disc size: '$2' (a number in GB expected)"
awk -v g="$DISC_GB" 'BEGIN{exit !(g>0)}' || die "disc size must be greater than zero"

for tool in par2 sha256sum find stat awk sort du; do
    command -v "$tool" >/dev/null 2>&1 || die "utility not found: $tool"
done

[[ -d $DIR ]] || die "directory not found: $DIR"
[[ -r $DIR ]] || die "directory not readable: $DIR"
DIR_ABS=$(CDPATH= cd -- "$DIR" && pwd)
ROOT_NAME=$(basename -- "$DIR_ABS")
[[ $ROOT_NAME != -* ]] || die "the directory name must not start with '-'"

[[ -e $DIR_ABS/recovery ]] && die "recovery/ already exists in $DIR_ABS (re-preparation is not supported — delete recovery/)"

NSYM=$(find "$DIR_ABS" -type l | wc -l)
(( NSYM > 0 )) && echo "WARNING: symlinks skipped: $NSYM (only regular files are included in the set)" >&2

mapfile -d '' files < <(find "$DIR_ABS" -type f -print0 | sort -z)
(( ${#files[@]} >= 1 )) || die "no regular files in $DIR_ABS"

TOTAL_SIZE=0
for f in "${files[@]}"; do
    rel=${f#"$DIR_ABS"/}
    [[ $rel != *$'\t'* && $rel != *$'\n'* ]] || die "a name with a tab/newline is not supported by the manifest: $rel"
    TOTAL_SIZE=$(( TOTAL_SIZE + $(stat -c%s -- "$f") ))
done

DISC_BYTES=$(awk -v g="$DISC_GB" 'BEGIN{printf "%.0f", g*1000000000}')
MARGIN_BYTES=$(awk -v p="$MARGIN_PERCENT" -v d="$DISC_BYTES" 'BEGIN{m=int(d*p/100); if (m<50000000) m=50000000; printf "%d", m}')

FREE=$(( DISC_BYTES - MARGIN_BYTES - TOTAL_SIZE ))
if (( FREE <= 0 )); then
    die "the files ($TOTAL_SIZE bytes) do not fit into ${DISC_GB}GB with a $(awk -v b="$MARGIN_BYTES" 'BEGIN{printf "%.2f", b/1000000000}')GB margin (free: $FREE bytes)"
fi

PERCENT=$(awk -v f="$FREE" -v s="$TOTAL_SIZE" 'BEGIN{printf "%d", int(f*100/s)-1}')
if (( PERCENT < 1 )); then
    die "too little space left for PAR2 data: ${FREE} bytes (~$(awk -v f="$FREE" -v s="$TOTAL_SIZE" 'BEGIN{printf "%.1f", f*100/s}')% of the file volume)"
fi

BS=4096
while (( BS * 2000 < TOTAL_SIZE )); do BS=$(( BS * 2 )); done

echo "==> Directory: $ROOT_NAME (${#files[@]} files, $(awk -v b="$TOTAL_SIZE" 'BEGIN{printf "%.2f", b/1000000000}')GB)"
echo "==> Disc: ${DISC_GB}GB, margin ${MARGIN_PERCENT}% (min 50MB) = $(awk -v b="$MARGIN_BYTES" 'BEGIN{printf "%.2f", b/1000000000}')GB, for PAR2: ${PERCENT}% (~$(awk -v f="$FREE" 'BEGIN{printf "%.2f", f/1000000000}') GB)"
echo "==> PAR2 block: ${BS} bytes, the files are not split"

mkdir -- "$DIR_ABS/recovery"

echo "==> Computing sha256 and building manifest.txt..."
{
    printf '# FORMAT=dir-v1\n'
    printf '# ROOT_NAME=%s\n' "$ROOT_NAME"
    printf '# FILE_COUNT=%s\n' "${#files[@]}"
    printf '# TOTAL_SIZE=%s\n' "$TOTAL_SIZE"
    printf '# DISC_GB=%s\n' "$DISC_GB"
    printf '# PAR2_PERCENT=%s\n' "$PERCENT"
    printf '# BLOCK_SIZE=%s\n' "$BS"
    printf '# CREATED_UTC=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for f in "${files[@]}"; do
        rel=${f#"$DIR_ABS"/}
        sha=$(sha256sum -- "$f" | awk '{print $1}')
        st=$(stat -c'%s %Y' -- "$f")
        printf '%s\t%s\t%s\t%s\n' "$sha" "${st% *}" "${st#* }" "$rel"
    done
} > "$DIR_ABS/recovery/manifest.txt"

echo "==> Generating PAR2 (${PERCENT}%)..."
(
    cd -- "$DIR_ABS"
    rels=()
    for f in "${files[@]}"; do rels+=("${f#"$DIR_ABS"/}"); done
    par2 create -B"$DIR_ABS" -r"$PERCENT" -s"$BS" "recovery/$ROOT_NAME.par2" "${rels[@]}" recovery/manifest.txt
)

echo "==> Verifying PAR2..."
(cd -- "$DIR_ABS" && par2 verify -B"$DIR_ABS" "recovery/$ROOT_NAME.par2")

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
for s in prepare_dir.sh restore_dir.sh README_dir.md; do
    [[ -f $SCRIPT_DIR/$s ]] || die "not found next to prepare_dir.sh: $s ($SCRIPT_DIR)"
done
cp -- "$SCRIPT_DIR/prepare_dir.sh" "$SCRIPT_DIR/restore_dir.sh" "$DIR_ABS/recovery/"
cp -- "$SCRIPT_DIR/README_dir.md" "$DIR_ABS/recovery/README.md"

TOTAL_OUT=$(du -sb -- "$DIR_ABS" | awk '{print $1}')
echo "==> Done. recovery/: $(du -sh -- "$DIR_ABS/recovery" | awk '{print $1}'), total with the files: $(awk -v b="$TOTAL_OUT" 'BEGIN{printf "%.2f", b/1000000000}')GB of ${DISC_GB}GB"
if (( TOTAL_OUT > DISC_BYTES )); then
    echo "WARNING: the result exceeds the disc capacity (${TOTAL_OUT} > ${DISC_BYTES} bytes)!" >&2
    exit 1
fi
