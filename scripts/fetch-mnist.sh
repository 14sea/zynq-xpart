#!/usr/bin/env bash
# Fetch the raw MNIST idx files for the M7.4 oracle (sim/oracle_mnist.py).
# Saved under data/mnist/ (gitignored, ~47 MB). The committed golden header
# (sw/m7_train/m7_mnist_vectors.h) is generated from these, so the build itself
# does NOT need this — only regenerating the oracle/header does.
#
# Source: OSSCI S3 mirror (the canonical yann.lecun.com host is unreliable).
# This box's IPv6 is broken — force IPv4 (curl -4).
set -euo pipefail
cd "$(dirname "$0")/.."
DST=data/mnist
BASE=https://ossci-datasets.s3.amazonaws.com/mnist
mkdir -p "$DST"
for f in train-images-idx3-ubyte train-labels-idx1-ubyte \
         t10k-images-idx3-ubyte t10k-labels-idx1-ubyte; do
    if [ -f "$DST/$f" ]; then echo "have $f"; continue; fi
    echo "fetch $f"
    curl -4 -fsSL --max-time 120 -o "$DST/$f.gz" "$BASE/$f.gz"
    gunzip -f "$DST/$f.gz"
done
echo "--- md5 (expect: 6bbc9ace.. a25bea73.. 2646ac64.. 27ae3e4e..) ---"
md5sum "$DST"/*
