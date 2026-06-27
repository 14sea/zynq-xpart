#!/usr/bin/env python3
"""m73-demo.py — M7.3 DFX train<->infer split + measured-boot gate (path (a)).

Orchestrates the M7.3 headline END-TO-END on the EBAZ4205 using ONLY already-built,
already-allowlisted bitstreams — no Vivado rebuild needed for the MECHANISM tier:

  1. (assumed) board is at the U-Boot prompt with the DFX static loaded (the RP comes
     up in whatever RM the boot full carried; rm_rot/rm_train/rm_tpuvpu all share the
     same static, pr_verify-compatible — see allowlist M6.4 note).
  2. measured-load the TRAINING partial (rm_train, trio) -> M5 gate measures its
     SHA-256 against board/allowlist.sha256; on pass, `fpga loadbp` swaps the RP to the
     trainer. The RP is RESET_AFTER_RECONFIG but PS + NEORV32 (static) keep running.
  3. (optional --watch-loss) poll the PS mailbox 0x41200000 while the trainer runs.
  4. measured-load the INFERENCE partial (rm_tpuvpu) -> gate measures, `loadbp` swaps
     the RP back to the inference accelerator. PS/NEORV32 heartbeat is uninterrupted
     across BOTH loadbps (measure-then-yield, M6.4 Model B).
  5. NEGATIVE control: a 1-byte-tampered copy of the training partial is presented to
     the gate, which REFUSES it (M5) — proof the swap path is gated, not open.

This is the MECHANISM tier (gate + DFX swap + heartbeat + negative). The weight-handoff
tier (rm_train publishes its just-learned Q8.8 master over the mailbox; PS feeds it to
rm_infer so inference runs on the LEARNED weights) needs the single-step+yield firmware
variant baked into the static — that is the next board+IMEM-rebuild step (see
docs/m7_plan.md §M7.3, path (a): converged-weight seed -> one verified HW SGD step ->
yield -> infer XOR 4/4). Until then this script proves everything that does NOT need the
new firmware.

Usage:
  scripts/m73-demo.py                 # full mechanism demo (train->infer swap + negative)
  scripts/m73-demo.py --watch-loss 30 # also poll the loss mailbox 30 s after the swap
  scripts/m73-demo.py --skip-negative # omit the tamper-rejection control
"""
import argparse
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# bitstreams + their allowlist names (must already be in board/allowlist.sha256)
RM_TRAIN = os.path.join(ROOT, 'vivado/dfx/build/dfx.runs/impl_8',
                        'u_soc_wb_tpu_inst_rm_train_partial.bit')
RM_INFER = os.path.join(ROOT, 'vivado/dfx/m6_out', 'rm_tpuvpu_partial.bit')
MBOX = '0x41200000'


def run(cmd):
    print(f"\n$ {' '.join(cmd)}")
    return subprocess.run(cmd, cwd=ROOT).returncode


def measured_load(bit, port, expect_pass=True):
    """Drive scripts/measured-load.py. Returns True iff the gate PASSED."""
    cmd = [sys.executable, os.path.join(HERE, 'measured-load.py'),
           '--bit', bit, '--op', 'loadbp', '--port', port, '--read', MBOX]
    rc = run(cmd)
    passed = (rc == 0)
    if passed != expect_pass:
        verb = 'PASS' if expect_pass else 'REJECT'
        print(f"[m73] !! expected gate to {verb} for {os.path.basename(bit)} "
              f"but rc={rc}", file=sys.stderr)
    return passed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', default='/dev/ebaz-uart')
    ap.add_argument('--watch-loss', type=int, metavar='SECS', default=0,
                    help='poll the PS mailbox 0x41200000 for this many seconds after '
                         'loading the trainer')
    ap.add_argument('--skip-negative', action='store_true',
                    help='skip the tamper-rejection (M5 negative) control')
    args = ap.parse_args()

    for p in (RM_TRAIN, RM_INFER):
        if not os.path.exists(p):
            sys.exit(f"missing bitstream: {p}\n"
                     "build it first: vivado -mode batch -source vivado/dfx/build_dfx.tcl")

    print("=== M7.3 train<->infer DFX swap + measured-boot gate (path a, mechanism tier) ===")
    print("Pre-req: board at U-Boot prompt with the DFX static loaded "
          "(see CLAUDE.md 'Get to U-Boot prompt').")

    # --- 1. measured-load the TRAINER -------------------------------------------------
    print("\n[1/4] measured-load TRAINING RM (rm_train, trio) -> loadbp")
    if not measured_load(RM_TRAIN, args.port, expect_pass=True):
        sys.exit("trainer gate failed unexpectedly — is partial-RM_TRAIN-trio allowlisted?")

    # --- 2. (optional) watch the loss mailbox -----------------------------------------
    if args.watch_loss:
        print(f"\n[2/4] watch loss mailbox {MBOX} for {args.watch_loss}s")
        run([sys.executable, os.path.join(HERE, 'm7-watch-loss.py'),
             '--port', args.port, '--timeout', str(args.watch_loss)])
    else:
        print("\n[2/4] (skipped loss watch; pass --watch-loss SECS to enable)")

    # --- 3. measured-load the INFERENCE RM (the YIELD) --------------------------------
    print("\n[3/4] measured-load INFERENCE RM (rm_tpuvpu) -> loadbp  (measure-then-yield)")
    if not measured_load(RM_INFER, args.port, expect_pass=True):
        sys.exit("inference gate failed unexpectedly — is partial-RM_TPUVPU-tpu+vpu allowlisted?")
    print("    PS/NEORV32 heartbeat should be uninterrupted across both loadbps "
          "(static region untouched).")

    # --- 4. NEGATIVE control: tampered trainer is REFUSED -----------------------------
    if not args.skip_negative:
        print("\n[4/4] NEGATIVE control: 1-byte-tampered trainer partial -> gate must REFUSE")
        with open(RM_TRAIN, 'rb') as f:
            data = bytearray(f.read())
        data[len(data) // 2] ^= 0x01   # flip one bit in the bitstream body
        with tempfile.NamedTemporaryFile(suffix='.bit', delete=False) as tf:
            tf.write(data)
            tampered = tf.name
        try:
            refused = not measured_load(tampered, args.port, expect_pass=False)
            print("    => REFUSED (good): the swap path is measured, not open."
                  if refused else "    => !! tampered partial was NOT refused — gate bug.")
        finally:
            os.unlink(tampered)
    else:
        print("\n[4/4] (skipped negative control)")

    print("\n=== M7.3 mechanism demo done. "
          "Next: bake the single-step+yield firmware for the weight-handoff tier. ===")


if __name__ == '__main__':
    main()
