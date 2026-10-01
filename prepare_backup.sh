#!/usr/bin/env bash
# Prepare an archive for Blu-Ray backup with PAR2 recovery data.
# Usage: prepare_backup.sh <archive> <disc_size_GB> [output_dir]
set -euo pipefail

VOLUME_TARGET_BYTES=512000000

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat >&2 <<EOF
Usage: $0 <archive> <disc_size_GB> [output_dir]

  archive          path to the archive (e.g. backup.zip)
  disc_size_GB     target disc size in GB (e.g. 25)
  output_dir       default: ./backup_folder

The VOLUME_MB environment variable sets the volume size in MB (for tests);
by default volumes are ~512MB each.
The MARGIN_PERCENT environment variable sets the safety margin as a % of the
disc capacity (default 2%, but at least 50MB — with a 700MB CD in mind).
EOF
}

[[ $# -ge 2 && $# -le 3 ]] || { usage; exit 1; }

ARCHIVE=$1
DISC_GB=${2//,/.}
OUT_DIR=${3:-backup_folder}

[[ $DISC_GB =~ ^[0-9]+([.][0-9]+)?$ ]] || die "invalid disc size: '$2' (a number in GB expected)"
awk -v g="$DISC_GB" 'BEGIN{exit !(g>0)}' || die "disc size must be greater than zero"

for tool in split sha256sum par2 stat awk; do
    command -v "$tool" >/dev/null 2>&1 || die "utility not found: $tool"
done

[[ -f $ARCHIVE ]] || die "archive not found: $ARCHIVE"
[[ -r $ARCHIVE ]] || die "archive not readable: $ARCHIVE"

BASENAME=$(basename -- "$ARCHIVE")
[[ $BASENAME != -* ]] || die "the archive name must not start with '-'"

SIZE=$(stat -c%s -- "$ARCHIVE")
DISC_BYTES=$(awk -v g="$DISC_GB" 'BEGIN{printf "%.0f", g*1000000000}')

MARGIN_PERCENT=${MARGIN_PERCENT:-2}
[[ $MARGIN_PERCENT =~ ^[0-9]+([.][0-9]+)?$ ]] || die "invalid MARGIN_PERCENT: '$MARGIN_PERCENT' (a percentage expected)"
MARGIN_BYTES=$(awk -v p="$MARGIN_PERCENT" -v d="$DISC_BYTES" 'BEGIN{m=int(d*p/100); if (m<50000000) m=50000000; printf "%d", m}')

if [[ -d $OUT_DIR ]] && [[ -n $(find "$OUT_DIR" -mindepth 1 -print -quit 2>/dev/null) ]]; then
    die "output directory is not empty: $OUT_DIR (clean it and retry)"
fi

FREE=$(( DISC_BYTES - MARGIN_BYTES - SIZE ))
if (( FREE <= 0 )); then
    die "the archive ($SIZE bytes) does not fit into ${DISC_GB}GB with a $(awk -v b="$MARGIN_BYTES" 'BEGIN{printf "%.2f", b/1000000000}')GB margin (free: $FREE bytes)"
fi

PERCENT=$(awk -v f="$FREE" -v s="$SIZE" 'BEGIN{printf "%d", int(f*100/s)-1}')
if (( PERCENT < 1 )); then
    die "too little space left for PAR2 data: ${FREE} bytes (~$(awk -v f="$FREE" -v s="$SIZE" 'BEGIN{printf "%.1f", f*100/s}')% of the archive). Need a smaller archive or a bigger disc."
fi

if [[ -n ${VOLUME_MB:-} ]]; then
    [[ $VOLUME_MB =~ ^[0-9]+$ ]] || die "VOLUME_MB must be an integer (MB)"
    VOL_SIZE=$(( VOLUME_MB * 1000000 ))
else
    NVOLS=$(awk -v s="$SIZE" -v t="$VOLUME_TARGET_BYTES" 'BEGIN{printf "%d", int((s+t-1)/t)}')
    VOL_SIZE=$(awk -v s="$SIZE" -v n="$NVOLS" 'BEGIN{printf "%.0f", (s+n-1)/n}')
fi
NVOLS=$(awk -v s="$SIZE" -v v="$VOL_SIZE" 'BEGIN{printf "%d", int((s+v-1)/v)}')
(( NVOLS >= 1 )) || die "failed to compute the number of volumes"
(( NVOLS <= 999 )) || die "too many volumes: $NVOLS (increase VOLUME_MB)"
WIDTH=3; (( NVOLS > 99 )) && WIDTH=${#NVOLS}

BS=4096
while (( BS * 2000 < SIZE )); do BS=$(( BS * 2 )); done

echo "==> Archive: $BASENAME ($(awk -v b="$SIZE" 'BEGIN{printf "%.2f", b/1000000000}') GB)"
echo "==> Disc: ${DISC_GB}GB, margin ${MARGIN_PERCENT}% (min 50MB) = $(awk -v b="$MARGIN_BYTES" 'BEGIN{printf "%.2f", b/1000000000}')GB, for PAR2: ${PERCENT}% (~$(awk -v f="$FREE" 'BEGIN{printf "%.2f", f/1000000000}') GB)"
echo "==> Volumes: $NVOLS of $(awk -v b="$VOL_SIZE" 'BEGIN{printf "%.0f", b/1000000}') MB, PAR2 block: ${BS} bytes"
echo "==> Output directory: $OUT_DIR"
mkdir -p -- "$OUT_DIR"

echo "==> Splitting into volumes..."
split -d -a "$WIDTH" -b "$VOL_SIZE" -- "$ARCHIVE" "$OUT_DIR/$BASENAME.part."

echo "==> Computing the archive sha256..."
SHA256=$(sha256sum -- "$ARCHIVE" | awk '{print $1}')
MTIME=$(stat -c%Y -- "$ARCHIVE")

cat > "$OUT_DIR/manifest.txt" <<EOF
ARCHIVE_NAME=$BASENAME
ARCHIVE_SIZE=$SIZE
ARCHIVE_SHA256=$SHA256
ARCHIVE_MTIME=$MTIME
VOLUME_SIZE=$VOL_SIZE
VOLUME_COUNT=$NVOLS
PAR2_PERCENT=$PERCENT
DISC_GB=$DISC_GB
CREATED_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

echo "==> Generating PAR2 (${PERCENT}%)..."
(
    cd -- "$OUT_DIR"
    shopt -s nullglob
    files=("$BASENAME".part.[0-9]* manifest.txt)
    par2 create -r"$PERCENT" -s"$BS" "$BASENAME.par2" "${files[@]}"
)

echo "==> Verifying PAR2..."
(cd -- "$OUT_DIR" && par2 verify "$BASENAME.par2")

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RESTORE_SRC="$SCRIPT_DIR/restore_backup.sh"
README_SRC="$SCRIPT_DIR/README.md"
[[ -f $RESTORE_SRC ]] || die "restore_backup.sh not found next to prepare_backup.sh ($SCRIPT_DIR)"
[[ -f $README_SRC ]] || die "README.md not found next to prepare_backup.sh ($SCRIPT_DIR)"
cp -- "${BASH_SOURCE[0]}" "$RESTORE_SRC" "$README_SRC" "$OUT_DIR/"

TOTAL=$(du -sb -- "$OUT_DIR" | awk '{print $1}')
echo "==> Done. Total size: $(awk -v b="$TOTAL" 'BEGIN{printf "%.2f", b/1000000000}') GB of ${DISC_GB}GB"
if (( TOTAL > DISC_BYTES )); then
    echo "WARNING: the result exceeds the disc capacity (${TOTAL} > ${DISC_BYTES} bytes)!" >&2
    exit 1
fi
