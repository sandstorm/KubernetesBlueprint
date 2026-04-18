#!/bin/bash
set -ex

# 1. Run steps that must not be parallelized before caretakerd starts.
#    Otherwise race conditions lead to partial cache builds and broken state.

./flow flow:cache:flush || true

# This does the warmup as well
./flow doctrine:migrate || true

# 2. Start caretakerd, which runs FrankenPHP + startup.sh in parallel
/usr/bin/caretakerd run
