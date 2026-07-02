# Hướng dẫn thao tác — Contracts & Release (ComicSystem)

> Dành cho nhóm 2 người. **Bạn** lo: `be-comic`, `image-ai`, `orchestrator-ai`.

---

## Phần A — Trước mắt cần làm gì? (thứ tự ưu tiên)

### Bước 0 — Hôm nay (30 phút): “Đóng băng” contract v0.1

Hai người ngồi review 4 file trong `documents/contracts/`:

| File | Cần chốt |
|------|----------|
| `story_generation.openapi.yaml` | POST /generate: 4 panel, `caption_vi`, `prompt_en`, `characters` (FastAPI REST) |
| `orchestrator.proto` | `StartComicGeneration`, `GetComicJobStatus`, enum status |
| `image_generation.proto` | Giữ nguyên (image-ai đã implement) |
| `public-api.openapi.yaml` | `POST /comics/generate`, `GET /comics/jobs/{id}` |

**Xong bước 0 khi:** cả hai đồng ý, commit vào repo `documents`, ghi trong chat: *“contracts v0.1 frozen”*.

```bash
cd ComicSystem/documents
git add contracts/
git commit -m "chore(contracts): freeze API v0.1 for E2E integration"
git tag contracts-v0.1.0
git push && git push --tags
```

---

### Bước 1 — Tuần này (bạn): orchestrator-ai skeleton

Mục tiêu: orchestrator-ai gọi story-ai qua **REST HTTP**, **mock story-ai**, gọi **image-ai thật** (1 panel trước).

```
orchestrator StartComicGeneration
  → POST http://story-ai/generate  (mock: 4 PanelScript hardcode hoặc đọc từ story_generation shape)
  → gọi image-ai GenerateImageAsync × 1 (rồi × 4)
  → poll GetTaskStatus
  → GetComicJobStatus trả SUCCESS + minio URLs
```

**Chưa cần:** be-comic, fe-comic, story-ai thật.

---

### Bước 2 — Tuần này (bạn): be-comic API tối thiểu

Implement theo `public-api.openapi.yaml`:

- `GET /api/v1/health`
- `POST /api/v1/comics/generate` → tạo `job_id` UUID → gọi orchestrator gRPC
- `GET /api/v1/comics/jobs/:id` → proxy `GetComicJobStatus`

Postgres bảng `generation_jobs` (id, user_id, summary, status, created_at).

Test bằng **curl/Postman** — chưa cần Angular.

---

### Bước 3 — Song song (bạn kia)

- `story-ai`: FastAPI server trả **mock 4 panels** đúng `story_generation.openapi.yaml` qua `POST /generate`
- `fe-comic`: chưa cần gấp — đợi be-comic chạy được

---

### Bước 4 — Tích hợp

| Thứ tự | Việc |
|--------|------|
| 1 | orchestrator gọi mock story-ai thay hardcode |
| 2 | orchestrator × 4 panel image-ai |
| 3 | fe-comic poll be-comic |
| 4 | story-ai Llama thật |

**Mốc release `v0.2.0`:** `POST /comics/generate` → poll → 4 ảnh hiển thị web.

---

## Phần B — Contracts: thao tác đúng từng bước

### B.1 Contracts là gì (nhắc nhanh)

Chỉ gồm **thỏa thuận giữa 2 service** — không có code logic.

```
documents/contracts/     ← SỬA Ở ĐÂY (repo documents)
        │
        │  sync-contracts.sh
        ▼
image-ai/proto/
orchestrator-ai/proto/
story-ai/proto/
be-comic/              ← OpenAPI: copy thủ công hoặc generate types
```

---

### B.2 Quy trình hàng ngày khi SỬA contract

#### Trường hợp 1 — Thay đổi nhỏ, không breaking (thêm field optional)

Ví dụ: thêm `string title = 9;` optional vào response.

```
1. Sửa file trong documents/contracts/
2. Ghi 1 dòng vào deployment/VERSIONS.md → Contract changelog
3. Chạy sync + kiểm tra
4. Commit documents TRƯỚC, rồi commit từng service repo
```

```bash
# Từ thư mục ComicSystem/
./documents/scripts/sync-contracts.sh
./documents/scripts/check-contracts-sync.sh   # phải in "OK"

# Generate code Python (trong từng repo AI)
cd image-ai && ./scripts/generate_proto.sh    # nếu có script
cd orchestrator-ai && python -m grpc_tools.protoc -I./proto --python_out=./src --grpc_python_out=./src ./proto/orchestrator.proto
```

Bump version: **PATCH** repo bạn sửa (vd. `image-ai v0.1.0` → `v0.1.1`). **Không** cần release stack mới.

---

#### Trường hợp 2 — Breaking change (đổi tên field, xóa field, đổi type)

Ví dụ: đổi `summary` → `story_summary` trong proto.

```
1. Họp 2 người — thống nhất trước khi sửa
2. Sửa documents/contracts/
3. Bump MAJOR contract version trong VERSIONS.md
4. sync-contracts.sh + check-contracts-sync.sh
5. CẢ HAI bên implement cùng lúc — không merge một nửa
6. Tag release stack mới (vd. comic-system v0.3.0)
```

**Quy tắc:** Không sửa proto trực tiếp trong `image-ai/proto/` mà quên sync ngược lên `documents/`.

---

### B.3 Ai sửa file nào?

| Muốn đổi… | Sửa file | Ai propose | Ai review |
|-----------|----------|------------|-----------|
| API web (FE gọi BE) | `public-api.openapi.yaml` | Bạn | Bạn kia (FE) |
| BE ↔ orchestrator | `orchestrator.proto` | Bạn | — |
| orchestrator ↔ image | `image_generation.proto` | Bạn | — |
| orchestrator ↔ story | `story_generation.proto` | Bạn (orchestrator cần) | Bạn kia (story-ai) |

**OpenAPI cho be-comic:** copy file vào `be-comic/docs/public-api.openapi.yaml` hoặc dùng `@nestjs/swagger` generate từ code — nhưng **nguồn sự thật vẫn là** `documents/contracts/public-api.openapi.yaml`.

---

### B.4 Lệnh sync & kiểm tra (copy-paste)

```bash
# 1. Sync proto sang các repo
cd /path/to/ComicSystem
./documents/scripts/sync-contracts.sh

# 2. Kiểm tra các bản copy khớp bản gốc
./documents/scripts/check-contracts-sync.sh

# 3. (Tuỳ chọn) Xem diff nếu lệch
diff documents/contracts/image_generation.proto image-ai/proto/image_generation.proto
```

Kết quả đúng:

```
OK  image_generation.proto
OK  story_generation.proto
OK  orchestrator.proto
All contracts in sync.
```

---

### B.5 Sau sync — generate code ở từng repo

**Python (orchestrator-ai, image-ai):**

```bash
# orchestrator-ai
cd orchestrator-ai
python -m grpc_tools.protoc \
  -I./proto \
  --python_out=./src/generated \
  --grpc_python_out=./src/generated \
  ./proto/orchestrator.proto
```

**story-ai (FastAPI) — không dùng protoc, dùng OpenAPI:**

```bash
# Tạo server từ story_generation.openapi.yaml (hoặc implement thủ công FastAPI)
cd story-ai
pip install fastapi uvicorn
# Implement theo spec trong documents/contracts/story_generation.openapi.yaml
```

**NestJS (be-comic)** — gọi orchestrator:

- Cài `@grpc/grpc-js` + `@grpc/proto-loader`
- Load `orchestrator.proto` từ `be-comic/proto/` (copy từ sync script — có thể mở rộng script sau)

Hoặc dùng `grpc_tools` generate TypeScript — tùy stack bạn chọn.

---

## Phần C — Release & Versioning: thao tác cụ thể

### C.1 Hai loại version (đừng nhầm)

| Loại | Ví dụ | Ý nghĩa | Ghi ở đâu |
|------|-------|---------|-----------|
| **Contract version** | `story_generation v1.0.0` | Format API giữa services | `deployment/VERSIONS.md` → Contract changelog |
| **Repo / service tag** | `image-ai v0.1.0` | Code release từng repo | Git tag trên từng repo GitHub |
| **Stack release** | `comic-system v0.2.0` | Bộ combo chạy được cùng nhau | `deployment/VERSIONS.md` → Releases |

**Stack release** = “bộ này chạy E2E được” — gồm nhiều repo tag khác nhau.

---

### C.2 Semantic versioning (đơn giản)

```
vMAJOR.MINOR.PATCH

MAJOR ↑  — breaking contract (cả team phải update)
MINOR ↑  — tính năng mới, contract tương thích ngược
PATCH ↑  — bugfix, không đổi contract
```

Ví dụ:

| Thay đổi | Bump |
|----------|------|
| Fix cache bug image-ai | `image-ai v0.1.0` → `v0.1.1` |
| orchestrator thêm retry | `orchestrator-ai v0.1.0` → `v0.1.1` |
| Thêm field optional `title` trong proto | Contract patch; service PATCH |
| Đổi tên field bắt buộc trong proto | Contract MAJOR; stack release mới |

---

### C.3 Quy trình release stack (làm từng bước)

Giả sử release **`comic-system v0.2.0`** — E2E pipeline chạy được.

#### Bước 1 — Cập nhật VERSIONS.md

Mở `deployment/VERSIONS.md`, thêm section:

```markdown
### `v0.2.0` — E2E pipeline (2026-06-XX)

| Repo | Tag | Contract |
|------|-----|----------|
| documents | v0.2.0 | contracts v0.1 |
| orchestrator-ai | v0.1.0 | orchestrator v1 |
| be-comic | v0.1.0 | public-api v0.1 |
| image-ai | v0.1.0 | image_generation v1 |
| story-ai | v0.1.0 | story_generation v1 |
| fe-comic | v0.2.0 | public-api v0.1 |
| deployment | v0.2.0 | — |
```

Commit trong repo `deployment`.

---

#### Bước 2 — Tag từng repo (trên GitHub)

Làm **trên từng repo** sau khi code đã merge vào `main`:

```bash
# Repo image-ai
cd image-ai
git checkout main
git pull
git tag -a v0.1.0 -m "E2E single panel, gRPC+Celery"
git push origin v0.1.0

# Repo orchestrator-ai
cd ../orchestrator-ai
git tag -a v0.1.0 -m "Saga MVP, mock story + real image-ai"
git push origin v0.1.0

# Repo be-comic
cd ../be-comic
git tag -a v0.1.0 -m "POST generate + GET job status"
git push origin v0.1.0

# Repo documents
cd ../documents
git tag -a v0.2.0 -m "contracts v0.1 frozen"
git push origin v0.2.0

# Repo deployment (tag stack)
cd ../deployment
git tag -a v0.2.0 -m "comic-system stack: E2E pipeline"
git push origin v0.2.0
```

**Lưu ý:** Mỗi repo trong organization có git riêng → tag riêng từng repo.

---

#### Bước 3 — Kiểm tra trước khi tag (checklist)

```bash
./documents/scripts/check-contracts-sync.sh

cd deployment
docker compose up --build -d
# Test E2E:
curl -X POST http://localhost:8000/api/v1/comics/generate \
  -H "Content-Type: application/json" \
  -d '{"summary":"Cậu bé và chú mèo đi phiêu lưu trong rừng."}'

# Lấy jobId từ response, poll:
curl http://localhost:8000/api/v1/comics/jobs/<jobId>
```

Tick trong `VERSIONS.md`:

- [ ] Contracts sync OK
- [ ] docker compose up OK
- [ ] E2E generate → SUCCESS

---

#### Bước 4 — Deploy (khi lên server)

Trên server, clone đủ repo sibling hoặc dùng script:

```bash
git clone .../deployment.git && cd deployment
# Checkout tag stack
git checkout v0.2.0

# (Tuỳ chọn) Pin từng repo về đúng tag trước khi build
cd ../image-ai && git checkout v0.1.0
cd ../be-comic && git checkout v0.1.0
# ...

cd ../deployment
docker compose up --build -d
```

---

### C.4 Hàng ngày — KHÔNG cần release

Khi đang dev:

```bash
# Chỉ commit + push branch feature
git checkout -b feat/orchestrator-saga
# ... code ...
git push origin feat/orchestrator-saga
# Merge PR — KHÔNG tag
```

**Chỉ tag khi:**

- Milestone xong (E2E chạy được)
- Demo cho thầy / bảo vệ
- Deploy lên server

---

### C.5 Khi bạn kia merge story-ai — quy trình tích hợp

```
1. Bạn kia push story-ai — đảm bảo proto sync từ documents
2. Bạn chạy check-contracts-sync.sh
3. orchestrator: đổi từ mock → gọi story-ai gRPC thật
4. Test local: orchestrator + story-ai + image-ai (không cần FE)
5. Nếu OK → bump orchestrator PATCH tag hoặc đợi stack release
```

---

## Phần D — Cheat sheet 1 trang

### Sửa contract

```
documents/contracts/ → sửa
VERSIONS.md → ghi changelog
sync-contracts.sh → copy
check-contracts-sync.sh → verify
generate proto → implement
commit documents trước → commit service repos
```

### Release stack

```
E2E test OK
→ cập nhật deployment/VERSIONS.md
→ tag từng repo (v0.x.x)
→ tag deployment (comic-system v0.x.0)
→ docker compose up trên server
```

### Việc của bạn tuần này

| # | Việc | Repo |
|---|------|------|
| 1 | Chốt contracts v0.1 với bạn kia | documents |
| 2 | orchestrator gRPC + mock story + image-ai 1 panel | orchestrator-ai |
| 3 | be-comic POST/GET job | be-comic |
| 4 | Mở rộng 4 panel | orchestrator-ai |

---

*Liên quan: [MICROSERVICES_GUIDE.md](./MICROSERVICES_GUIDE.md) | [contracts/README.md](./contracts/README.md) | [../deployment/VERSIONS.md](../deployment/VERSIONS.md)*
