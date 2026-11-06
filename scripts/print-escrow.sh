#!/usr/bin/env bash
# Print every keyfile from a bootstrap staging tree as relative path + base64,
# so they can be pasted into the offline recovery vault. Each file is
# small; rebuild it with: echo '<base64>' | base64 -d > <name>.
#
# Usage: print-escrow.sh <staging-dir>
set -euo pipefail

if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
  echo "usage: $0 <staging-dir>   (printed by bootstrap.sh after key generation)" >&2
  exit 1
fi

cd "$1"
find . -type f -print0 | sort -z | while IFS= read -r -d '' file; do
  printf '%s:\n' "${file#./}"
  base64 "$file"
  echo
done
