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
: "${POST_COMMENT:=true}"

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
  local expr=$1
  if date -d "$expr" '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
    date -d "$expr" '+%Y-%m-%dT%H:%M:%SZ'
  elif date -v "$expr" '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
    date -v "$expr" '+%Y-%m-%dT%H:%M:%SZ'
  else
    fail "Cannot parse TIME_FILTER: $TIME_FILTER on this platform."
  fi
}

# -------- Functions ----------------------------------------------------------
fetch_issues() {
  local time_ago=$1
  log "Fetching issues from $REPO..."
  gh api -X GET "repos/${REPO}/issues" -f state=all --paginate > raw_issues.json
  jq --arg newNum "$NEW_ISSUE_NUMBER" --arg dateFilter "$time_ago" '
    map(select(.pull_request | not))
    | map(select(.number != ($newNum|tonumber)))
    | map(select(.created_at >= $dateFilter))
    | map({ number, title, state, body, created_at })
  ' raw_issues.json > issues.json
}

create_batches() {
  # Reads issues.json, writes batch_prompt_*.txt and batch_metadata.json
  [ -f issues.json ] || fail "issues.json missing before batch creation"
  local total_issues
  total_issues=$(jq 'length' issues.json)
  if [ "$total_issues" -eq 0 ]; then
    log "No issues to process. Exiting create_batches early."
    echo '{"total_batches":0,"total_issues":0,"batch_size":'$BATCH_SIZE',"batches":[]}' > batch_metadata.json
    return 0
  fi
  local processed=0 batch_index=0 batch_files_json='[]'
  while [ "$processed" -lt "$total_issues" ]; do
    batch_index=$((batch_index + 1))
    local start=$processed
    local end=$((start + BATCH_SIZE))
    local issues_slice=$(jq ".[${start}:${end}]" issues.json)
    local batch_count=$(echo "$issues_slice" | jq 'length')
    [ "$batch_count" -gt 0 ] || break
    local batch_file="batch_prompt_${batch_index}.txt"
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
      echo "$issues_slice" | jq -r '.[] | "Issue #\(.number)\nTitle: \(.title)\nBody: \(.body // "")\nState: \(.state)\n---"'
    } > "$batch_file"
    log "Created $batch_file with $batch_count issues."
    processed=$((processed + batch_count))
    # Append batch metadata
    batch_files_json=$(echo "$batch_files_json" | jq --arg f "$batch_file" --argjson c "$batch_count" '. + [{"file":$f, "count":$c}]')
  done
  local total_batches=$((batch_index))
  log "Total batches: $total_batches (issues processed: $processed)"
  jq -n --argjson tb "$total_batches" --argjson ti "$processed" --argjson bs "$BATCH_SIZE" --argjson batches "$batch_files_json" '{total_batches:$tb,total_issues:$ti,batch_size:$bs,batches:$batches}' > batch_metadata.json
}

run_ai() {
  mkdir -p batch_results
  if [ ! -f batch_metadata.json ]; then fail "Missing batch_metadata.json before AI step"; fi
  local total_batches
  total_batches=$(jq '.total_batches' batch_metadata.json)
  if [ "$total_batches" -eq 0 ]; then
    log "No batches to run AI against. Skipping AI phase."
    return 0
  fi
  jq -r '.batches[].file' batch_metadata.json | while read -r bf; do
    [ -s "$bf" ] || { log "Skipping empty $bf"; continue; }
    log "Running AI on $bf ..."
    local ai_out=$(cat "$bf" | gh models run "$MODEL_NAME" --max-tokens "$MAX_TOKENS" || echo "")
    echo "$ai_out" > "batch_results/result_${bf%.txt}.md"
  done
}

combine_results() {
  cd batch_results || return 0
  {
    echo "## Duplicate Issue Analysis Results"; echo
    local found_any="false"
    shopt -s nullglob
    for rf in result_batch_prompt_*.md; do
      if grep -qE '\*\*Issue:\*\* #[0-9]+' "$rf"; then
        cat "$rf"; echo; found_any="true"; fi
    done
    if [ "$found_any" = "false" ]; then
      echo "No duplicate or similar issues found."
    fi
  } > final_response.md
  cat final_response.md >> "${GITHUB_STEP_SUMMARY:-/dev/null}" 2>/dev/null || true
  if [ "$found_any" = "true" ] && [ "$POST_COMMENT" = "true" ]; then
    log "Posting comment to issue #$NEW_ISSUE_NUMBER"
    gh issue comment "$NEW_ISSUE_NUMBER" --repo "$REPO" --body-file final_response.md || true
  else
    log "No duplicates detected; not commenting."
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

# -------- Main script execution ---------------------------------------------
fetch_issues "$time_ago"
create_batches
run_ai
combine_results
log "Completed duplicate analysis."
