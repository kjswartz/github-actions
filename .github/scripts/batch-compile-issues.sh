#!/bin/bash

echo "Starting batch processing for issue duplication detection..."
echo "New Issue #$NEW_ISSUE_NUMBER: $NEW_ISSUE_TITLE"
echo "Will process up to approximately $NEW_ISSUE_NUMBER issues in batches of $BATCH_SIZE"

# Initialize variables
processed_count=0
page=1
batch_files=()

gh api -X GET repos/$REPO/issues -f state="all" --paginate | jq --arg newNum "$NEW_ISSUE_NUMBER" '.[] | select(.number != ($newNum | tonumber)) | {
  "number": .number,
  "title": .title,
  "state": .state,
  "body": .body
}' | jq -s . > issues.txt

total_issues=$(jq 'length' issues.txt)

# Create batch processing loop
while [ $processed_count -lt $total_issues ]; do
  echo "Processing batch $page..."
  
  offset=$processed_count
  
  echo "Fetching issues starting from offset $offset..."
  issues_json=$(jq ".[$offset:$(($offset + $BATCH_SIZE))]" issues.txt)
  
  batch_count=$(echo "$issues_json" | jq 'length')
  
  if [ "$batch_count" -eq 0 ]; then
    echo "No more issues to process. Breaking loop."
    break
  fi
  
  echo "Retrieved $batch_count issues in batch $page"
  processed_count=$(($processed_count + $batch_count))
  
  batch_prompt_file="batch_prompt_${page}.txt"
  batch_files+=("batch_prompt_${page}")
  
  cat > "$batch_prompt_file" << EOF
Instructions:
You are an expert in software engineering and issue management. Compare the following new issue with the batch of existing issues and identify any duplicates or similar issues. If any of the existing issues are similar to the new issue, rate the similarity as 'HIGH', 'MEDIUM', or 'LOW'. Only include issues that have some similarity.
Provide your response in this format for each similar issue:\n\n**Issue:** #[number] - [similarity rating]\n**Title:** [title]\n**State:** [state]\n**Reason for similarity:** [brief explanation]\n\n---\n
If no similar issues are found in this batch, respond with an empty string or newline character.

New Issue:
Title: $NEW_ISSUE_TITLE
Body: $NEW_ISSUE_BODY

Existing Issues in this batch:
EOF
  
  # Add each issue to the prompt
  echo "$issues_json" | jq -r '.[] | "
Issue #\(.number)
Title: \(.title)
Body: \(.body)
State: \(.state)
---"' >> "$batch_prompt_file"

  echo "Created prompt file: $batch_prompt_file"
  echo "Batch $page contains $batch_count issues"

  page=$(($page + 1))
done

total_batches=$(($page - 1))

# Output batch information for GitHub Actions matrix
if [ ${#batch_files[@]} -gt 0 ]; then
  # Create properly formatted JSON array for the matrix
  batch_matrix_json="["
  for i in "${!batch_files[@]}"; do
    if [ $i -gt 0 ]; then
      batch_matrix_json+=","
    fi
    batch_matrix_json+="\"${batch_files[$i]}\""
  done
  batch_matrix_json+="]"
  
  echo "batch_matrix=$batch_matrix_json" >> $GITHUB_OUTPUT
  echo "total_batches=$total_batches" >> $GITHUB_OUTPUT
  
  echo "Generated matrix with ${#batch_files[@]} batches: $batch_matrix_json"
else
  echo "batch_matrix=[]" >> $GITHUB_OUTPUT
  echo "total_batches=0" >> $GITHUB_OUTPUT
  echo "No batches created - no issues to process"
fi

# Create processing summary for output
processing_summary="Batch Processing Summary:
- Total batches processed: $total_batches
- Total issues analyzed: $processed_count
- Batch size: $BATCH_SIZE
- New issue number: $NEW_ISSUE_NUMBER

Each batch has been saved as batch_prompt_[number].txt for AI analysis."

echo "Batch processing completed. Processed $processed_count total issues across $total_batches batches."
echo "$processing_summary" >> $GITHUB_STEP_SUMMARY
