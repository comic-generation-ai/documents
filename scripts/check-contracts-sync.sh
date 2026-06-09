#!/usr/bin/env bash
# Kiểm tra proto trong từng service repo khớp với documents/contracts/

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONTRACTS="$ROOT/documents/contracts"

check_one() {
  local name="$1"
  local dest="$2"
  local src="$CONTRACTS/$name"

  if [[ ! -f "$dest/$name" ]]; then
    echo "MISSING $name — chưa có tại $dest/ (chạy sync-contracts.sh)"
    return 1
  fi

  if diff -q "$src" "$dest/$name" >/dev/null 2>&1; then
    echo "OK  $name"
    return 0
  fi

  echo "DRIFT $name — lệch giữa documents/contracts/ và $dest/"
  echo "      Chạy: ./documents/scripts/sync-contracts.sh"
  diff -u "$src" "$dest/$name" | head -20 || true
  return 1
}

failed=0
check_one "image_generation.proto" "$ROOT/image-ai/proto" || failed=1
check_one "story_generation.proto" "$ROOT/story-ai/proto" || failed=1
check_one "orchestrator.proto" "$ROOT/orchestrator-ai/proto" || failed=1

echo ""
if [[ "$failed" -eq 0 ]]; then
  echo "All contracts in sync."
  exit 0
fi

echo "Contract drift detected — sync hoặc cập nhật documents/contracts/ trước."
exit 1
