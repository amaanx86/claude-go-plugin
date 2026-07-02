#!/bin/bash
# Auto-format Go files after writing.
# Always exits 0 (non-blocking).

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Only process Go source files
if [[ "$FILE_PATH" != *.go ]]; then
  exit 0
fi

# gofmt ships with Go: simplify (-s) and format in place.
if command -v gofmt &> /dev/null; then
  gofmt -s -w "$FILE_PATH" 2>/dev/null
fi

# goimports additionally groups and prunes imports (Kubernetes convention).
if command -v goimports &> /dev/null; then
  goimports -w "$FILE_PATH" 2>/dev/null
fi

exit 0
