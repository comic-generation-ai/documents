# Contracts — Hướng dẫn sử dụng (ComicSystem)

> **Nguồn sự thật duy nhất** cho API giữa các service.  
> Nhóm 2 người, mỗi người một nhóm repo, làm trên `main` — **không cần release/tag**.

---

## 1. Contracts là gì?

Là file mô tả **service A gửi gì / nhận gì** khi gọi service B. Không chứa logic code.

```
documents/contracts/          ← SỬA Ở ĐÂY
        │
        │  ./documents/scripts/sync-contracts.sh  (copy proto)
        ▼
orchestrator-ai/proto/        ← bạn implement server + client
image-ai/proto/               ← bạn implement server
be-comic/                     ← bạn implement REST (xem OpenAPI)
story-ai/proto/               ← bạn kia implement server
fe-comic/                     ← bạn kia implement REST client
```

---

## 2. Bốn file contract

| File | Ai implement **server** | Ai implement **client** | Bạn hay bạn kia |
|------|-------------------------|-------------------------|-----------------|
| `public-api.openapi.yaml` | **be-comic** (REST) | **fe-comic** | Bạn / Bạn kia |
| `orchestrator.proto` | **orchestrator-ai** | **be-comic** | **Bạn** cả hai |
| `image_generation.proto` | **image-ai** | **orchestrator-ai** | **Bạn** cả hai |
| `story_generation.proto` | **story-ai** | **orchestrator-ai** | Bạn kia / **Bạn** (client) |

**Quy tắc nhóm bạn:** Bạn **không sửa** `story_generation.proto` tùy tiện — nhắn bạn kia trước. Bạn kia **không sửa** `orchestrator.proto` / `image_generation.proto` — nhắn bạn.

Chỉ **`public-api.openapi.yaml`** cần hai người thống nhất (bạn làm BE, bạn kia làm FE).

---

## 3. Luồng dữ liệu (đọc contract theo thứ tự)

```
fe-comic
  │  POST { summary }                    public-api.openapi.yaml
  ▼
be-comic
  │  StartComicGeneration(job_id, summary)   orchestrator.proto
  ▼
orchestrator-ai
  │  GenerateStory(summary)                  story_generation.proto
  │       → panels[4], characters
  │  GenerateImageAsync(prompt) × 4          image_generation.proto
  │       → poll GetTaskStatus → minio_url
  ▼
be-comic → fe-comic
  GET job status { panels[], pageImageUrl }
```

---

## 4. Nội dung từng file (đọc nhanh)

### `public-api.openapi.yaml` — Web API

**Bạn implement trong be-comic:**

| Endpoint | Làm gì |
|----------|--------|
| `POST /api/v1/comics/generate` | Nhận `summary` → tạo `jobId` UUID → gọi orchestrator |
| `GET /api/v1/comics/jobs/{jobId}` | Trả status + `panels[]` + `pageImageUrl` |
| `POST .../cancel` | Hủy job |
| `GET /health` | Health check |

Response **202** khi tạo job — không chờ AI xong.

---

### `orchestrator.proto` — be-comic ↔ orchestrator-ai

**Bạn implement server** trong `orchestrator-ai`:

| RPC | Vai trò |
|-----|---------|
| `StartComicGeneration` | Nhận job → chạy saga nền (story → 4 image) → trả ngay PENDING |
| `GetComicJobStatus` | Poll: status, `progress_current/total`, `panels[]`, `page_image_url` |
| `CancelComicJob` | Hủy task đang chạy |
| `CheckHealth` | Health |

**Bạn implement client** trong `be-comic` (gRPC gọi orchestrator).

---

### `story_generation.proto` — orchestrator ↔ story-ai

**Bạn kia implement server** trong `story-ai`:

| RPC | Input | Output |
|-----|-------|--------|
| `GenerateStory` | `summary`, `num_panels=4` | `panels[]` + `characters` map |

Mỗi `PanelScript`:

- `caption_vi` — lời thoại (FE hiển thị bubble)
- `prompt_en` — gửi sang image-ai
- `character_ids` — nhân vật trong khung

**Bạn implement client** trong `orchestrator-ai` (gọi story-ai).

---

### `image_generation.proto` — orchestrator ↔ image-ai

**Bạn implement server** trong `image-ai` (đã có):

| RPC | Vai trò |
|-----|---------|
| `GenerateImageAsync` | Nhận `prompt`, `caption_text`, `reference_image_url` → trả `task_id` |
| `GetTaskStatus` | Poll → `minio_url` khi SUCCESS |
| `CancelTask` | Hủy task Celery |

**Bạn implement client** trong `orchestrator-ai`.

---

## 5. Quy trình hàng ngày

### Lần đầu setup (mỗi người clone repo xong)

```bash
cd ComicSystem
./documents/scripts/sync-contracts.sh
./documents/scripts/check-contracts-sync.sh
```

Phải thấy: `All contracts in sync.`

---

### Khi CẦN đổi contract (hiếm — thống nhất trước qua chat)

**Người sở hữu ranh giới** sửa file trong `documents/contracts/`, commit `documents` lên `main`, nhắn nhóm.

**Người implement** chạy:

```bash
cd ComicSystem
./documents/scripts/sync-contracts.sh
./documents/scripts/check-contracts-sync.sh
```

Rồi **generate lại code** từ proto (sync không tự generate):

```bash
# image-ai (bạn) — dùng venv env/ tự động
cd image-ai && ./scripts/generate_proto.sh

# orchestrator-ai (bạn) — lần đầu: tạo venv rồi generate
cd orchestrator-ai
python3 -m venv env
source env/bin/activate
pip install -r requirements.txt
./scripts/generate_proto.sh

# story-ai (bạn kia) — tương tự với story_generation.proto
```

Cuối cùng sửa code implement cho khớp proto mới, commit repo service lên `main`.

---

### Khi KHÔNG đổi contract (phần lớn thời gian)

Chỉ code trong repo của bạn (`be-comic`, `orchestrator-ai`, `image-ai`). **Không cần** chạy sync.

---

## 6. Sync làm gì / không làm gì

| Sync (`sync-contracts.sh`) | Không làm |
|----------------------------|-----------|
| Copy `.proto` từ `documents/contracts/` → `*/proto/` | Generate Python/TS từ proto |
| Ghi đè bản cũ trong service repo | Sửa code implement |
| | Copy `public-api.openapi.yaml` (copy thủ công vào be-comic nếu cần) |
| | Commit git (bạn tự commit) |

**OpenAPI** — copy thủ công khi đổi:

```bash
cp documents/contracts/public-api.openapi.yaml be-comic/docs/public-api.openapi.yaml
```

---

## 7. Ai được sửa file nào?

```
BẠN sửa (nhắn bạn kia nếu ảnh hưởng FE):
  ├── orchestrator.proto
  ├── image_generation.proto
  └── public-api.openapi.yaml

BẠN KIA sửa (nhắn bạn nếu ảnh hưởng orchestrator):
  └── story_generation.proto

HAI NGƯỜI cùng review:
  └── public-api.openapi.yaml  (FE + BE)
```

**Không** sửa proto trong `image-ai/proto/` rồi quên cập nhật `documents/contracts/`.

---

## 8. Kiểm tra nhanh trước khi push

```bash
./documents/scripts/check-contracts-sync.sh
```

Nếu báo `DRIFT` → chạy `sync-contracts.sh` hoặc pull `documents` mới nhất từ `main`.

---

## 9. Checklist implement (phía bạn)

- [ ] `image-ai` — server `image_generation.proto` (đã có)
- [ ] `orchestrator-ai` — server `orchestrator.proto` + client story + client image
- [ ] `be-comic` — REST theo OpenAPI + gRPC client `orchestrator.proto`
- [ ] Giai đoạn đầu: orchestrator **mock** story (hardcode 4 panels) trước khi story-ai sẵn sàng

---

*Xem thêm: [GUIDE.md](../GUIDE.md) (lộ trình tổng thể)*
