#!/usr/bin/env bash
# The offline regression gate. Desktop runtime acceptance remains separate.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
bash -n bin/omathlete bin/provider.sh bin/planner.sh tests/fixture-curl tests/provider-fixtures.sh tests/reliability.sh tests/smoke.sh
python3 -I tests/storage.py
tests/provider-fixtures.sh
bash tests/reliability.sh
node tests/panel-logic.mjs
node tests/loading.mjs
node tests/slate-view.mjs
node tests/bar-view.mjs
node tests/planner.mjs
node tests/planner-view.mjs
git diff --check
