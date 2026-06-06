#!/usr/bin/env bash
# Decode a (full or partial) XC7Z010 bitstream to FASM with prjxray, naming
# LUT-INIT and other CRAM features. Used to cross-validate the Phase-4 LUT
# surgery: `diff <(prjxray-fasm.sh A.bit) <(prjxray-fasm.sh edited.bit)` names the
# exact LUT INIT bit that was changed.
#
# Requires the local prjxray install + the xc7z010 prjxray-db (see Step 0):
#   /home/test/prjxray (with .venv: pip install simplejson fasm intervaltree pyyaml textx)
#   /home/test/prjxray-db  (f4pga/prjxray-db, has zynq7/xc7z010 tilegrid + segbits)
set -e
# Override these if your prjxray / prjxray-db live elsewhere:
#   PRJXRAY=/path/to/prjxray  XRAY_DATABASE_DIR=/path/to/prjxray-db  prjxray-fasm.sh x.bit
PRJXRAY=${PRJXRAY:-/home/test/prjxray}
export XRAY_DATABASE_DIR=${XRAY_DATABASE_DIR:-/home/test/prjxray-db}
export XRAY_DATABASE=zynq7
export XRAY_PART=xc7z010clg400-1
export XRAY_TOOLS_DIR=$PRJXRAY/build/tools
PYTHONPATH=$PRJXRAY "$PRJXRAY/.venv/bin/python" \
  "$PRJXRAY/utils/bit2fasm.py" --db-root "$XRAY_DATABASE_DIR/zynq7" --part xc7z010clg400-1 "$1" 2>/dev/null
