#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Duplicate / Similar Issue Identifier
###############################################################################

# -------- Configuration (env vars expected) ----------------------------------
: "${REPO:?REPO is required (owner/name)}"
: "${NEW_ISSUE_NUMBER:?NEW_ISSUE_NUMBER is required}"
: "${NEW_ISSUE_TITLE:?NEW_ISSUE_TITLE is required}"
: "${NEW_ISSUE_BODY:?NEW_ISSUE_BODY is required}"
: "${BATCH_SIZE:=50}"
: "${TIME_FILTER:=1 year ago}"
: "${MODEL_NAME:=openai/gpt-4.1}"
: "${MAX_TOKENS:=2000}"

if ! [[ "$BATCH_SIZE" =~ ^[0-9]+$ ]] || [ "$BATCH_SIZE" -le 0 ]; then
  echo "Invalid BATCH_SIZE: $BATCH_SIZE" >&2
  exit 1
fi

# -------- Helpers ------------------------------------------------------------
log()   { printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail()  { echo "ERROR: $*" >&2; exit 1; }
have()  { command -v "$1" >/dev/null 2>&1; }

[ "${GITHUB_OUTPUT:-}" != "" ] || true
[ "${GITHUB_STEP_SUMMARY:-}" != "" ] || true

for dep in gh jq; do
  have "$dep" || fail "Missing dependency: $dep"
done

# Date handling (portable)
make_iso_utc() {
  # Input: natural language like "7 days ago"
  local expr=$1
  if date -d "$expr" '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
    date -d "$expr" '+%Y-%m-%dT%H:%M:%SZ'
  else
    fail "Cannot parse TIME_FILTER: $TIME_FILTER on this platform."
  fi
}

# -------- Model extension install ----------------------------------------
if ! gh extension list | grep -q 'gh-models'; then
  log "Installing gh-models extension..."
  gh extension install https://github.com/github/gh-models
else
  log "gh-models already installed"
fi

# -------- Prepare workspace --------------------------------------------------
WORKDIR=$(mktemp -d -t duplicate-issues-XXXX)
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

time_ago="$(make_iso_utc "$TIME_FILTER")"
log "Analyzing issues created after: $time_ago"
log "New issue #$NEW_ISSUE_NUMBER: $NEW_ISSUE_TITLE"
log "Batch size: $BATCH_SIZE"

# -------- Fetch issues -------------------------------------------------------
log "Fetching issues from $REPO..."
gh api -X GET "repos/${REPO}/issues" -f state=all --paginate > raw_issues.json

# Filter out new issue & restrict by created_at >= time_ago
jq --arg newNum "$NEW_ISSUE_NUMBER" --arg dateFilter "$time_ago" '
  map(select(.pull_request | not))    
  | map(select(.number != ($newNum|tonumber)))
  | map(select(.created_at >= $dateFilter))
  | map({
      number, title, state, body,
      created_at
    })
' raw_issues.json > issues.json

total_issues=$(jq 'length' issues.json)
log "Filtered issues count: $total_issues"

if [ "$total_issues" -eq 0 ]; then
  log "No issues to process. Exiting."
  exit 0
fi

# -------- Create batches -----------------------------------------------------
processed=0
batch_index=0
batch_files=()

while [ "$processed" -lt "$total_issues" ]; do
  batch_index=$((batch_index + 1))
  start=$processed
  end=$((processed + BATCH_SIZE))
  issues_slice=$(jq ".[$start:$end]" issues.json)
  batch_count=$(echo "$issues_slice" | jq 'length')

  [ "$batch_count" -gt 0 ] || break

  batch_file="batch_prompt_${batch_index}.txt"
  {
    cat <<EOF
Instructions:
You are an expert in software engineering and issue management. Compare the following new issue with the batch of existing issues and identify any duplicates or similar issues. If any of the existing issues are similar to the new issue, rate the similarity as 'HIGH', 'MEDIUM', or 'LOW'. Only include issues that have some similarity.
Provide your response in this format for each similar issue:

**Issue:** #[number] - [similarity rating]
**Title:** [title]
**State:** [state]
**Reason for similarity:** [brief explanation]

---

If none, output an empty string.

New Issue:
Title: $NEW_ISSUE_TITLE
Body: $NEW_ISSUE_BODY

Existing Issues:
EOF
    echo "$issues_slice" | jq -r '
      .[] | "Issue #\(.number)\nTitle: \(.title)\nBody: \(.body // "")\nState: \(.state)\n---"
    '
  } > "$batch_file"

  batch_files+=("$batch_file")
  log "Created $batch_file with $batch_count issues."
  processed=$((processed + batch_count))
done

total_batches=${#batch_files[@]}
log "Total batches: $total_batches (issues processed: $processed)"

# -------- AI Inference -------------------------------------------------------
mkdir -p batch_results
for bf in "${batch_files[@]}"; do
  if [ ! -s "$bf" ]; then
    log "Skipping empty $bf"
    continue
  fi
  log "Running AI on $bf ..."
  ai_out=$(cat "$bf" | gh models run "$MODEL_NAME" --max-tokens "$MAX_TOKENS" || echo "")
  echo "$ai_out" > "batch_results/result_${bf%.txt}.md"
done

# -------- Combine results ----------------------------------------------------
cd batch_results
{
  echo "## Duplicate Issue Analysis Results"
  echo
  found_any=false
  shopt -s nullglob
  for rf in result_batch_prompt_*.md; do
    if grep -qE '\*\*Issue:\*\* #[0-9]+' "$rf"; then
      cat "$rf"
      echo
      found_any=true
    fi
  done
  if ! $found_any; then
    echo "No duplicate or similar issues found."
  fi
} > final_response.md

cat final_response.md >> "${GITHUB_STEP_SUMMARY:-/dev/null}" 2>/dev/null || true

if [ "$found_any" = true ]; then
  log "Posting comment to issue #$NEW_ISSUE_NUMBER"
  gh issue comment "$NEW_ISSUE_NUMBER" --repo "$REPO" --body-file final_response.md
else
  log "No duplicates detected; not commenting."
fi

log "Completed duplicate analysis."
