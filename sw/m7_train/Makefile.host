# M7.0b host validation: build the portable C backprop and bit-exact check it
# against the numpy oracle (sim/oracle_train.py). The header is regenerated from
# the oracle so the two can never drift.
CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra -std=c99
ORACLE   = ../../sim/oracle_train.py
HEADER   = m7_vectors.h

.PHONY: check header clean
check: $(HEADER) train_xor.c
	$(CC) $(CFLAGS) -o /tmp/train_xor train_xor.c
	/tmp/train_xor

# Regenerate the golden header from the oracle (golden config defaults).
header:
	python3 $(ORACLE) --dump-header $(HEADER)

clean:
	rm -f /tmp/train_xor
