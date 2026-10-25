#!/usr/bin/env bash
# Runs surrealdb-protocol's conformance scenarios through this SDK's driver
# (Conformance/Driver). Needs bun, and a surreal binary in SURREAL_BIN (or
# `surreal` on the PATH); the runner starts its own servers.
#
# Fails on a failure that Conformance/known-failures.txt doesn't list, and on
# a listed one that now passes, so the list stays accurate.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
protocol="${SURREALDB_PROTOCOL_DIR:-$root/.build/surrealdb-protocol}"
report="${CONFORMANCE_REPORT:-$root/.build/conformance.json}"

if [[ ! -f "$protocol/conformance/runner/cli.ts" ]]; then
  "$root/scripts/fetch-surrealdb-protocol.sh"
fi

swift build --package-path "$root" --product SurrealConformanceDriver
driver="$(swift build --package-path "$root" --show-bin-path)/SurrealConformanceDriver"

rm -f "$report"
(
  cd "$protocol"
  bun install --frozen-lockfile
  # Exits non-zero on any failure; the report is checked below instead.
  bun conformance/runner/cli.ts --driver "$driver" --report "$report" || true
)

python3 -I - "$report" "$root/Conformance/known-failures.txt" <<'PY'
import json, sys

report, known_path = sys.argv[1], sys.argv[2]
with open(report) as f:
    results = json.load(f)["results"]
known = set()
with open(known_path) as f:
    for line in f:
        line = line.split("#", 1)[0].strip()
        if line:
            transport, scenario = line.split()
            known.add((transport, scenario))

failed = {(r["transport"], r["scenario"]) for r in results if r["outcome"]["status"] == "fail"}
passed = {(r["transport"], r["scenario"]) for r in results if r["outcome"]["status"] == "pass"}
counts = {}
for r in results:
    counts[r["outcome"]["status"]] = counts.get(r["outcome"]["status"], 0) + 1
print("conformance:", ", ".join(f"{n} {s}" for s, n in sorted(counts.items())))

new = sorted(failed - known)
fixed = sorted(known & passed)
for transport, scenario in new:
    print(f"new failure: {transport} {scenario}")
for transport, scenario in fixed:
    print(f"now passes, remove it from Conformance/known-failures.txt: {transport} {scenario}")
sys.exit(1 if new or fixed else 0)
PY
