#!/usr/bin/env bash

# Exit immediately if:
# - any command fails (-e)
# - any unset variable is used (-u)
# - any command in a pipeline fails (-o pipefail)
set -euo pipefail

# ------------------------------------------------------------------------------
# PURPOSE
# ------------------------------------------------------------------------------
# This script compares:
# 1. a WORKING IAM role used by GitHub Actions OIDC
# 2. a FAILING IAM role used by GitHub Actions OIDC
# 3. the IAM OIDC provider used by both
#
# It helps identify mismatches in:
# - OIDC provider ARN
# - trust relationship
# - audience (aud)
# - subject (sub)
# - inline policies
# - attached managed policies
# - provider client ID / audience list
#
# ------------------------------------------------------------------------------
# USAGE
# ------------------------------------------------------------------------------
# ./check_oidc_setup.sh <WORKING_ROLE_NAME> <FAILING_ROLE_NAME> <OIDC_PROVIDER_ARN>
#
# Example:
# ./check_oidc_setup.sh \
#   working-gitactions-role \
#   failing-gitactions-role \
#   arn:aws:iam::123456789012:oidc-provider/github.example.com/_services/token
# ------------------------------------------------------------------------------

# Check that the user passed 3 arguments:
# 1) working role name
# 2) failing role name
# 3) OIDC provider ARN
if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <WORKING_ROLE_NAME> <FAILING_ROLE_NAME> <OIDC_PROVIDER_ARN>"
  exit 1
fi

# Read arguments into named variables for clarity
WORKING_ROLE="$1"
FAILING_ROLE="$2"
OIDC_PROVIDER_ARN="$3"

# Create a temporary directory to store intermediate JSON files
# mktemp -d makes a new temporary folder
TMP_DIR="$(mktemp -d)"

# trap ensures the temp directory is deleted when the script exits
trap 'rm -rf "$TMP_DIR"' EXIT

# ------------------------------------------------------------------------------
# FUNCTION: need_cmd
# ------------------------------------------------------------------------------
# This function checks whether a command exists in the shell PATH.
# If not, it stops the script with a clear error.
#
# Example:
# need_cmd aws
# need_cmd python3
# ------------------------------------------------------------------------------
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1"
    exit 1
  }
}

# Ensure the required tools are installed before running
need_cmd aws
need_cmd python3

# ------------------------------------------------------------------------------
# FUNCTION: pretty_json
# ------------------------------------------------------------------------------
# Reads JSON from stdin and prints it in a nicely formatted way.
#
# Example:
# cat file.json | pretty_json
# ------------------------------------------------------------------------------
pretty_json() {
  python3 -m json.tool
}

# ------------------------------------------------------------------------------
# FUNCTION: extract_role
# ------------------------------------------------------------------------------
# Fetches an IAM role using AWS CLI and extracts its trust policy.
#
# Input:
#   $1 = role name
#   $2 = output file path where decoded trust policy JSON will be written
#
# What it does:
# 1. Calls "aws iam get-role"
# 2. Saves raw AWS response into <output>.raw.json
# 3. Extracts AssumeRolePolicyDocument
# 4. Decodes it if needed
# 5. Saves the trust relationship into a clean JSON file
# ------------------------------------------------------------------------------
extract_role() {
  local role_name="$1"
  local out_file="$2"

  echo "Fetching role: $role_name"
  aws iam get-role --role-name "$role_name" > "$out_file.raw.json"

  python3 - <<PY > "$out_file"
import json, urllib.parse

# Open the raw AWS CLI JSON output
with open("$out_file.raw.json") as f:
    data = json.load(f)

# Extract the trust relationship document
doc = data["Role"]["AssumeRolePolicyDocument"]

# In some AWS CLI outputs, the policy may come URL-encoded or stringified.
# If it is a string, decode and parse it.
if isinstance(doc, str):
    doc = json.loads(urllib.parse.unquote(doc))

# Print the trust relationship in pretty JSON form
print(json.dumps(doc, indent=2))
PY
}

# ------------------------------------------------------------------------------
# FUNCTION: extract_provider
# ------------------------------------------------------------------------------
# Fetches details of the IAM OIDC provider using AWS CLI.
#
# Input:
#   $1 = OIDC provider ARN
#   $2 = output file path
#
# Output includes:
# - Url
# - ClientIDList (important for audience checks)
# - ThumbprintList
# ------------------------------------------------------------------------------
extract_provider() {
  local arn="$1"
  local out_file="$2"

  echo "Fetching OIDC provider: $arn"
  aws iam get-open-id-connect-provider \
    --open-id-connect-provider-arn "$arn" > "$out_file"
}

# ------------------------------------------------------------------------------
# FUNCTION: show_role_summary
# ------------------------------------------------------------------------------
# Prints a summary of a role:
# - trust relationship
# - inline policies
# - attached managed policies
#
# Input:
#   $1 = role name
#   $2 = trust file path
# ------------------------------------------------------------------------------
show_role_summary() {
  local role_name="$1"
  local trust_file="$2"

  echo
  echo "================ ROLE SUMMARY: $role_name ================"
  echo "--- Trust relationship ---"
  cat "$trust_file"

  echo
  echo "--- Inline policies ---"
  aws iam list-role-policies --role-name "$role_name" | pretty_json

  echo
  echo "--- Attached managed policies ---"
  aws iam list-attached-role-policies --role-name "$role_name" | pretty_json
}

# ------------------------------------------------------------------------------
# FUNCTION: extract_claims_summary
# ------------------------------------------------------------------------------
# Reads a trust relationship JSON file and prints only the important claim checks:
# - Effect
# - Action
# - Federated provider
# - Condition operators like StringEquals / StringLike
# - aud
# - sub
#
# This helps quickly understand what the role is checking.
#
# Input:
#   $1 = trust file
#   $2 = label to print
# ------------------------------------------------------------------------------
extract_claims_summary() {
  local trust_file="$1"
  local label="$2"

  echo
  echo "----- Extracted OIDC trust checks: $label -----"
  python3 - <<PY
import json

with open("$trust_file") as f:
    doc = json.load(f)

# Statement may be a list or a single object, normalize to list
stmts = doc.get("Statement", [])
if isinstance(stmts, dict):
    stmts = [stmts]

for i, s in enumerate(stmts, 1):
    print(f"Statement #{i}")
    print("  Effect:", s.get("Effect"))
    print("  Action:", s.get("Action"))
    print("  Federated:", s.get("Principal", {}).get("Federated"))

    cond = s.get("Condition", {})
    for op, values in cond.items():
        print(f"  {op}:")
        if isinstance(values, dict):
            for k, v in values.items():
                print(f"    {k}: {v}")
        else:
            print(f"    {values}")
    print()
PY
}

# ------------------------------------------------------------------------------
# FUNCTION: compare_files
# ------------------------------------------------------------------------------
# Shows a unified diff between two files.
#
# Useful to compare:
# - working trust policy
# - failing trust policy
#
# Input:
#   $1 = first file
#   $2 = second file
#   $3 = label shown in output
# ------------------------------------------------------------------------------
compare_files() {
  local f1="$1"
  local f2="$2"
  local label="$3"

  echo
  echo "================ DIFF: $label ================"
  if command -v diff >/dev/null 2>&1; then
    diff -u "$f1" "$f2" || true
  else
    echo "diff command not available"
  fi
}

# ------------------------------------------------------------------------------
# FUNCTION: check_provider_audience_match
# ------------------------------------------------------------------------------
# Checks whether the audience values used in the trust policy exist in the OIDC
# provider's ClientIDList.
#
# Why this matters:
# AWS can reject OIDC tokens if the trust policy expects an audience that is not
# registered in the IAM OIDC provider.
#
# Input:
#   $1 = trust file
#   $2 = provider JSON file
#   $3 = label to print
# ------------------------------------------------------------------------------
check_provider_audience_match() {
  local trust_file="$1"
  local provider_file="$2"
  local label="$3"

  echo
  echo "================ PROVIDER AUDIENCE CHECK: $label ================"
  python3 - <<PY
import json

with open("$trust_file") as f:
    trust = json.load(f)

with open("$provider_file") as f:
    provider = json.load(f)

# ClientIDList contains allowed audiences configured on the OIDC provider
client_ids = provider.get("ClientIDList", [])

# Normalize trust statements to list
stmts = trust.get("Statement", [])
if isinstance(stmts, dict):
    stmts = [stmts]

aud_values = []

# Extract any condition keys that end with ":aud"
for s in stmts:
    cond = s.get("Condition", {})
    for op, values in cond.items():
        if isinstance(values, dict):
            for k, v in values.items():
                if k.endswith(":aud"):
                    aud_values.append(v)

print("Provider client IDs / audiences:")
for cid in client_ids:
    print(" -", cid)

print()
print("Trust policy audience values:")
for aud in aud_values:
    print(" -", aud)

print()
for aud in aud_values:
    if aud in client_ids:
        print(f"MATCH: trust audience '{aud}' exists in provider client IDs")
    else:
        print(f"MISMATCH: trust audience '{aud}' NOT found in provider client IDs")
PY
}

# ------------------------------------------------------------------------------
# TEMP FILE PATHS
# ------------------------------------------------------------------------------
# These files store:
# - working role trust policy
# - failing role trust policy
# - OIDC provider details
# ------------------------------------------------------------------------------
WORKING_TRUST="$TMP_DIR/working-trust.json"
FAILING_TRUST="$TMP_DIR/failing-trust.json"
PROVIDER_JSON="$TMP_DIR/provider.json"

# ------------------------------------------------------------------------------
# FETCH DATA
# ------------------------------------------------------------------------------
# 1. Get trust relationship for working role
# 2. Get trust relationship for failing role
# 3. Get OIDC provider details
# ------------------------------------------------------------------------------
extract_role "$WORKING_ROLE" "$WORKING_TRUST"
extract_role "$FAILING_ROLE" "$FAILING_TRUST"
extract_provider "$OIDC_PROVIDER_ARN" "$PROVIDER_JSON"

# ------------------------------------------------------------------------------
# PRINT OIDC PROVIDER DETAILS
# ------------------------------------------------------------------------------
echo
echo "================ OIDC PROVIDER DETAILS ================"
cat "$PROVIDER_JSON" | pretty_json

# ------------------------------------------------------------------------------
# PRINT ROLE SUMMARIES
# ------------------------------------------------------------------------------
show_role_summary "$WORKING_ROLE" "$WORKING_TRUST"
show_role_summary "$FAILING_ROLE" "$FAILING_TRUST"

# ------------------------------------------------------------------------------
# PRINT EXTRACTED OIDC CLAIM CHECKS
# ------------------------------------------------------------------------------
extract_claims_summary "$WORKING_TRUST" "WORKING ROLE"
extract_claims_summary "$FAILING_TRUST" "FAILING ROLE"

# ------------------------------------------------------------------------------
# CHECK WHETHER trust-policy aud exists in provider ClientIDList
# ------------------------------------------------------------------------------
check_provider_audience_match "$WORKING_TRUST" "$PROVIDER_JSON" "WORKING ROLE"
check_provider_audience_match "$FAILING_TRUST" "$PROVIDER_JSON" "FAILING ROLE"

# ------------------------------------------------------------------------------
# SHOW DIRECT DIFF BETWEEN WORKING AND FAILING TRUST POLICIES
# ------------------------------------------------------------------------------
compare_files "$WORKING_TRUST" "$FAILING_TRUST" "TRUST POLICY"

# ------------------------------------------------------------------------------
# FINAL HINTS
# ------------------------------------------------------------------------------
echo
echo "================ DONE ================"
echo "Focus on differences in:"
echo "1. Principal.Federated"
echo "2. Condition StringEquals for :aud"
echo "3. Condition StringLike / StringEquals for :sub"
echo "4. Provider ClientIDList containing the trust-policy audience"
