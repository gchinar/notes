#!/usr/bin/env bash

# Exit on:
# - command failure
# - unset variable
# - failed pipeline command
set -euo pipefail

# ------------------------------------------------------------------------------
# PURPOSE
# ------------------------------------------------------------------------------
# This script compares only the trust relationship JSON of:
# 1. a working IAM role trust policy JSON
# 2. a failing IAM role trust policy JSON
#
# It extracts and compares only the important OIDC-related fields:
# - Federated OIDC provider
# - audience (aud)
# - subject (sub)
#
# ------------------------------------------------------------------------------
# USAGE
# ------------------------------------------------------------------------------
# ./compare_aud_sub.sh <WORKING_TRUST_JSON> <FAILING_TRUST_JSON>
#
# Example:
# ./compare_aud_sub.sh working-trust.json failing-trust.json
# ------------------------------------------------------------------------------

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <WORKING_TRUST_JSON> <FAILING_TRUST_JSON>"
  exit 1
fi

WORKING_JSON="$1"
FAILING_JSON="$2"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1"
    exit 1
  }
}

need_cmd python3

extract_summary() {
  local input_file="$1"
  local label="$2"

  echo "================ $label ================"
  python3 - <<PY
import json

with open("$input_file") as f:
    doc = json.load(f)

stmts = doc.get("Statement", [])
if isinstance(stmts, dict):
    stmts = [stmts]

for i, s in enumerate(stmts, 1):
    print(f"Statement #{i}")
    print("Federated:", s.get("Principal", {}).get("Federated"))

    cond = s.get("Condition", {})
    aud_found = False
    sub_found = False

    for op, values in cond.items():
        if isinstance(values, dict):
            for k, v in values.items():
                if k.endswith(":aud"):
                    print(f"{op} aud: {k} = {v}")
                    aud_found = True
                if k.endswith(":sub"):
                    print(f"{op} sub: {k} = {v}")
                    sub_found = True

    if not aud_found:
        print("aud: NOT FOUND")
    if not sub_found:
        print("sub: NOT FOUND")

    print()
PY
}

compare_summary() {
  local working_file="$1"
  local failing_file="$2"

  echo "================ IMPORTANT DIFFERENCES ================"
  python3 - <<PY
import json

def extract(doc):
    stmts = doc.get("Statement", [])
    if isinstance(stmts, dict):
        stmts = [stmts]

    result = []
    for s in stmts:
        item = {
            "Federated": s.get("Principal", {}).get("Federated"),
            "aud": [],
            "sub": []
        }

        cond = s.get("Condition", {})
        for op, values in cond.items():
            if isinstance(values, dict):
                for k, v in values.items():
                    if k.endswith(":aud"):
                        item["aud"].append((op, k, v))
                    if k.endswith(":sub"):
                        item["sub"].append((op, k, v))
        result.append(item)
    return result

with open("$working_file") as f:
    working = extract(json.load(f))

with open("$failing_file") as f:
    failing = extract(json.load(f))

print("Working role summary:")
for i, item in enumerate(working, 1):
    print(f"  Statement #{i}")
    print(f"    Federated: {item['Federated']}")
    print(f"    aud: {item['aud'] if item['aud'] else 'NOT FOUND'}")
    print(f"    sub: {item['sub'] if item['sub'] else 'NOT FOUND'}")

print()
print("Failing role summary:")
for i, item in enumerate(failing, 1):
    print(f"  Statement #{i}")
    print(f"    Federated: {item['Federated']}")
    print(f"    aud: {item['aud'] if item['aud'] else 'NOT FOUND'}")
    print(f"    sub: {item['sub'] if item['sub'] else 'NOT FOUND'}")

print()
print("Quick difference signals:")

if working != failing:
    print("  Trust summaries differ.")
else:
    print("  Trust summaries are identical.")

working_fed = [x["Federated"] for x in working]
failing_fed = [x["Federated"] for x in failing]
if working_fed != failing_fed:
    print("  Federated provider differs.")

working_aud = [x["aud"] for x in working]
failing_aud = [x["aud"] for x in failing]
if working_aud != failing_aud:
    print("  aud condition differs.")

working_sub = [x["sub"] for x in working]
failing_sub = [x["sub"] for x in failing]
if working_sub != failing_sub:
    print("  sub condition differs.")
PY
}

extract_summary "$WORKING_JSON" "WORKING TRUST"
extract_summary "$FAILING_JSON" "FAILING TRUST"
compare_summary "$WORKING_JSON" "$FAILING_JSON"
