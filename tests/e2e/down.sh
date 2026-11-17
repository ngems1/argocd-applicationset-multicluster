#!/usr/bin/env bash
# Delete the e2e kind clusters (after `KEEP=1 tests/e2e/run.sh` or `make e2e-up`).
set -euo pipefail
for c in dev staging prod; do
  kind delete cluster --name "cc-$c"
done
rm -rf "$(cd "$(dirname "$0")/../.." && pwd)/.e2e"
