# ComicSystem — Shared Contracts (Source of Truth)

Repo `documents/contracts/` là **nguồn sự thật duy nhất** cho giao tiếp giữa các microservice.

## Quy tắc bắt buộc

1. **Không** tự sửa proto trong từng service repo — sửa tại đây trước.
2. Mỗi service **copy hoặc submodule** proto từ folder này khi build.
3. Mọi thay đổi breaking phải bump version trong `deployment/VERSIONS.md`.
4. CI (khi có) so sánh hash proto giữa `documents/contracts/` và bản trong service.

## Danh sách contract

| File | Giữa | Giao thức |
|------|------|-----------|
| `public-api.openapi.yaml` | `fe-comic` ↔ `be-comic` | REST (HTTPS) |
| `orchestrator.proto` | `be-comic` ↔ `orchestrator-ai` | gRPC (internal) |
| `story_generation.proto` | `orchestrator-ai` ↔ `story-ai` | gRPC (internal) |
| `image_generation.proto` | `orchestrator-ai` ↔ `image-ai` | gRPC (internal) |

## Sync vào từng repo

```bash
# Ví dụ từ root ComicSystem/
cp documents/contracts/image_generation.proto image-ai/proto/
cp documents/contracts/story_generation.proto story-ai/proto/
cp documents/contracts/orchestrator.proto orchestrator-ai/proto/
```

## Generate code

```bash
# Python (story-ai, image-ai, orchestrator-ai)
python -m grpc_tools.protoc -I./proto --python_out=./src --grpc_python_out=./src ./proto/*.proto

# TypeScript client cho be-comic (khi cần)
# npm run proto:generate  # script trong be-comic
```
