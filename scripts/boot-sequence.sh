#!/usr/bin/env bash
# M6.2 — measured-boot sequencer: "boot = RoT, runtime = TPU+VPU".
#
# Realizes Model A (docs/m6_plan.md): the static NEORV32 is the live root-of-trust
# gatekeeper; the Reconfigurable Partition only becomes the full 4x4 TPU + VPU
# *after* the measured-boot gate passes. Every fabric load is hash-gated by
# measured-load.py against board/allowlist.sha256 (M5) — a tampered/unlisted
# bitstream is refused before it reaches the fabric.
#
# Sequence:
#   1. measured-load the STATIC full  (fpga loadb)   -> NEORV32 RoT comes up
#   2. poll the mailbox (0x41200000)                 -> confirm RoT is alive ("measured OK")
#   3. measured-load the rm_tpuvpu PARTIAL (loadbp)  -> live-swap RP to TPU+VPU
#   4. read the mailbox                              -> VPU inference result (POST0-3)
#
# The board must already be at the miner U-Boot prompt (see ../CLAUDE.md recipe).
# UART runs through /dev/ebaz-uart at 115200.
#
# Usage:
#   scripts/boot-sequence.sh [--static <bit>] [--partial <bit>] [--port <dev>] [--dry-run]
#   --dry-run : verify the bitstreams exist + are allowlisted and print the plan,
#               WITHOUT touching the board (host-side logic check, no hardware).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PY="${PY:-/home/test/xilinx/.env/bin/python}"

STATIC="$ROOT/vivado/dfx/m6_out/static_full_tpuvpu.bit"
PARTIAL="$ROOT/vivado/dfx/m6_out/rm_tpuvpu_partial.bit"
ALLOWLIST="$ROOT/board/allowlist.sha256"
PORT="/dev/ebaz-uart"
MBOX="0x41200000"
DRYRUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --static)  STATIC="$2";  shift 2;;
    --partial) PARTIAL="$2"; shift 2;;
    --port)    PORT="$2";    shift 2;;
    --dry-run) DRYRUN=1;     shift;;
    -h|--help) sed -n '2,30p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

# --- helpers ---------------------------------------------------------------
gate_check() {  # local replica of measured-load's gate (for --dry-run)
  local bit="$1"
  [ -f "$bit" ] || { echo "  [MISS] $bit not found"; return 1; }
  local h; h="$(sha256sum "$bit" | cut -d' ' -f1)"
  if grep -qi "^$h" "$ALLOWLIST"; then
    echo "  [trust] OK  $(basename "$bit")  ($(grep -i "^$h" "$ALLOWLIST" | awk '{print $2}'))"
  else
    echo "  [trust] REJECTED  $(basename "$bit")  sha256=$h not in allowlist"; return 2
  fi
}
measured() {  # measured-load.py: gate then fpga load over UART
  $PY "$HERE/measured-load.py" --bit "$1" --op "$2" --port "$PORT" --allowlist "$ALLOWLIST" \
      ${3:+--read "$3"}
}
poll_mbox() { $PY "$HERE/uart-poke.py" --port "$PORT" --send "md $MBOX 1\r" --wait 3; }

# --- dry-run: host-side logic check, no board ------------------------------
if [ "$DRYRUN" = 1 ]; then
  echo "== boot-sequence DRY-RUN (no board) =="
  echo "[1] static full  : $STATIC"
  gate_check "$STATIC"
  echo "[3] tpu+vpu part : $PARTIAL"
  gate_check "$PARTIAL"
  echo "Plan when run for real:"
  echo "  1. measured-load.py --bit static  --op loadb  --read $MBOX   (RoT comes up)"
  echo "  2. poll md $MBOX over UART x3                                (RoT heartbeat)"
  echo "  3. measured-load.py --bit partial --op loadbp --read $MBOX   (live swap to TPU+VPU)"
  echo "  4. poll md $MBOX                                             (POST0-3 inference)"
  echo "== DRY-RUN OK =="
  exit 0
fi

# --- real run (needs board at U-Boot) --------------------------------------
echo "== [1/4] measured-load STATIC full (RoT) via fpga loadb =="
measured "$STATIC" loadb "$MBOX"

echo "== [2/4] poll RoT heartbeat (mailbox $MBOX) — 'measured OK' =="
for i in 1 2 3; do poll_mbox; sleep 1; done

echo "== [3/4] measured-load rm_tpuvpu PARTIAL via fpga loadbp (live swap) =="
measured "$PARTIAL" loadbp "$MBOX"

echo "== [4/4] read VPU inference result (POST0-3) from mailbox =="
poll_mbox

echo "== boot-sequence complete: RoT -> measured-gate -> TPU+VPU, no PS reset =="
