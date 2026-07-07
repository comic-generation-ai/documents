#!/usr/bin/env bash
# Sync shared contracts từ documents/contracts/ sang từng service repo.
# Chạy sau mỗi lần sửa proto

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONTRACTS="$ROOT/documents/contracts"

copy_proto() {
  local name="$1"
  local dest_dir="$2"
  if [[ ! -d "$dest_dir" ]]; then
    echo "SKIP $name — thư mục không tồn tại: $dest_dir"
    return 0
  fi
  mkdir -p "$dest_dir"
  cp "$CONTRACTS/$name" "$dest_dir/$name"
  echo "OK  $name → $dest_dir/"
}

copy_proto "image_generation.proto"  "$ROOT/image-ai/proto"
copy_proto "orchestrator.proto"      "$ROOT/orchestrator-ai/proto"
# orchestrator cần image proto để gọi image-ai (gRPC client)
copy_proto "image_generation.proto"  "$ROOT/orchestrator-ai/proto"

