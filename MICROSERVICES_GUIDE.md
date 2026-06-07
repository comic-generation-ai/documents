# ComicSystem — Hướng dẫn Microservices Chuẩn

> Tài liệu thực hành: làm sao để dự án **thật sự** là microservices, không chỉ nhiều repo.
>
> Đọc kèm: [ARCHITECTURE.md](./ARCHITECTURE.md) | Contracts: [contracts/](./contracts/) | Versions: [../deployment/VERSIONS.md](../deployment/VERSIONS.md)

---

## 1. Nguyên tắc vàng (10 quy tắc bắt buộc)

| # | Quy tắc | ComicSystem |
|---|---------|-------------|
| 1 | **Một service = một bounded context** | story = text; image = diffusion; orchestrator = workflow |
| 2 | **Database per service** | BE → PostgreSQL; image-ai → Redis DB riêng; orchestrator → Redis DB riêng |
| 3 | **Không share business code** | Chỉ share **contract** (proto/OpenAPI) trong `documents/contracts/` |
| 4 | **Giao tiếp qua network API** | gRPC nội bộ; REST public qua BE |
| 5 | **Deploy độc lập** | Mỗi repo build image riêng; `deployment` compose |
| 6 | **Failure isolation** | 1 panel image fail → retry panel, không sập cả BE |
| 7 | **Async cho tác vụ dài** | Sinh 4 ảnh = job async, không block HTTP |
| 8 | **Smart endpoints, dumb pipes** | Orchestrator giữ logic workflow; queue chỉ vận chuyển |
| 9 | **Observability** | `job_id` + `X-Request-Id` xuyên suốt mọi log |
| 10 | **API Gateway pattern** | Chỉ `be-comic` + `fe-comic` public; AI services internal |

---

## 2. Kiến trúc chuẩn cho ComicSystem

```
                    INTERNET
                        │
                        ▼
              ┌─────────────────┐
              │    fe-comic     │  Presentation — không biết AI
              └────────┬────────┘
                       │ REST (public-api.openapi.yaml)
                       ▼
              ┌─────────────────┐
              │    be-comic     │  BFF / API Gateway — auth, DB user/job
              │   PostgreSQL    │
              └────────┬────────┘
                       │ gRPC (orchestrator.proto) — INTERNAL ONLY
                       ▼
              ┌─────────────────┐
              │ orchestrator-ai │  Saga coordinator — state machine
              │   Redis (state) │
              └────┬───────┬────┘
                   │       │
         gRPC      │       │      gRPC
    (story.proto)  │       │  (image.proto)
                   ▼       ▼
            ┌──────────┐ ┌──────────────┐
            │ story-ai │ │  image-ai    │
            │  Llama   │ │ gRPC+Celery  │
            └──────────┘ │ Redis+MinIO  │
                         └──────────────┘

         deployment/docker-compose.yml — glue tất cả
         documents/contracts/ — source of truth
```

### Ai được gọi ai (ma trận phụ thuộc)

| Caller | Được gọi | Cấm gọi |
|--------|----------|---------|
| fe-comic | be-comic | orchestrator, story-ai, image-ai |
| be-comic | orchestrator-ai | story-ai, image-ai trực tiếp |
| orchestrator-ai | story-ai, image-ai | be-comic DB, fe-comic |
| story-ai | (không gọi service khác) | image-ai, be-comic |
| image-ai | MinIO, Redis | story-ai, be-comic |

---

## 3. Khung 5 trụ (bắt buộc có)

### Trụ 1 — Contract-first (`documents/contracts/`)

**Làm trước khi code logic.**

```
documents/contracts/
├── public-api.openapi.yaml    ← fe ↔ be
├── orchestrator.proto         ← be ↔ orchestrator
├── story_generation.proto     ← orchestrator ↔ story
├── image_generation.proto     ← orchestrator ↔ image
└── README.md
```

Workflow khi đổi API:

1. Sửa file trong `documents/contracts/`
2. Bump version trong `deployment/VERSIONS.md`
3. Copy proto sang từng service repo
4. Generate client/server code
5. Implement + test integration

### Trụ 2 — Deployment glue (`deployment/`)

```bash
cd deployment && docker compose up --build
```

- Network `comic-internal` — AI không publish port ra host
- Chỉ `fe-comic:3000` và `be-comic:8000` public
- Infra shared: `postgres`, `redis`, `minio`
- `image-ai` tách **2 container**: gRPC server + Celery worker

### Trụ 3 — Versioning (`deployment/VERSIONS.md`)

Mỗi release ghi rõ tag từng repo. Không deploy `orchestrator v0.2` với `story-ai v0.1` nếu contract không tương thích.

### Trụ 4 — Data ownership

| Service | Sở hữu data | Không được |
|---------|-------------|------------|
| be-comic | users, comics, generation_jobs (metadata) | Đọc Redis queue của image-ai |
| orchestrator-ai | workflow state tạm (Redis TTL) | Lưu user password |
| story-ai | Không DB lâu dài (stateless inference) | Ghi Postgres của BE |
| image-ai | Ảnh trên MinIO; cache Redis | Ghi Postgres |

**Redis namespace (tránh đụng nhau):**

```
DB 0 — be-comic (session, rate limit)
DB 1 — orchestrator-ai (job state)
DB 2 — story-ai (optional cache)
DB 3-5 — image-ai (cache, celery broker, result)
```

### Trụ 5 — Vận hành

**Correlation ID** — bắt buộc truyền xuyên suốt:

```
FE header: X-Request-Id: uuid
  → BE log + forward
    → orchestrator log (job_id + request_id)
      → story-ai / image-ai log
```

**Health checks:**

| Service | Endpoint |
|---------|----------|
| be-comic | `GET /health` |
| orchestrator-ai | gRPC `CheckHealth` |
| story-ai | gRPC `CheckHealth` |
| image-ai | gRPC `CheckHealth` + `CheckGpuHealth` |

---

## 4. Pattern bắt buộc cho pipeline AI

### 4.1 Async Job (không sync end-to-end)

```
Client                          Server
   │  POST /comics/generate         │
   │ ─────────────────────────────► │  202 { jobId }
   │                                │  (không chờ AI)
   │  GET /comics/jobs/{id}         │
   │ ─────────────────────────────► │  200 { status: IMAGE_GENERATING, progress: 2/4 }
   │  ... poll 2-3s ...             │
   │ ─────────────────────────────► │  200 { status: SUCCESS, panels: [...] }
```

### 4.2 Saga Pattern (orchestrator-ai)

Orchestrator là **Saga coordinator** — không phải pass-through:

```
State machine:
  PENDING
    → STORY_GENERATING     (gọi story-ai)
    → STORY_READY
    → IMAGE_GENERATING     (loop 4 panel → image-ai)
    → COMPOSING            (ghép 2×2, optional)
    → SUCCESS | FAILED | CANCELLED

Compensation:
  - story fail     → mark FAILED, không gọi image
  - panel 2 fail   → retry panel 2 (max 2 lần), không regenerate story
  - user cancel    → CancelTask trên image-ai tasks đang chạy
```

**Lưu state** trong Redis (orchestrator):

```json
{
  "job_id": "uuid",
  "status": "IMAGE_GENERATING",
  "progress_current": 2,
  "progress_total": 4,
  "panels": [...],
  "story_result": {...},
  "image_task_ids": ["t1", "t2", null, null]
}
```

### 4.3 Polling nội bộ (orchestrator → image-ai)

image-ai đã async (Celery). Orchestrator:

1. `GenerateImageAsync` → nhận `task_id`
2. Loop `GetTaskStatus` mỗi 2s (với timeout 10 phút/panel)
3. Lưu `minio_url` vào state
4. Panel tiếp theo: truyền `reference_image_url` = URL panel 0 (nhất quán nhân vật)

---

## 5. Cấu trúc chuẩn mỗi repo

### fe-comic (Angular)

```
src/app/
├── core/
│   ├── api/              ← ComicApiService (chỉ gọi be-comic)
│   ├── interceptors/     ← AuthInterceptor, X-Request-Id
│   └── models/           ← types generate từ OpenAPI
├── features/
│   ├── comic-generate/   ← form tóm tắt + poll progress
│   └── comic-editor/     ← editor bubble (đã có)
```

**Không** hardcode URL orchestrator/image-ai.

### be-comic (NestJS)

```
src/
├── modules/
│   ├── auth/
│   ├── comics/           ← POST generate, GET job
│   └── users/
├── grpc/                 ← client orchestrator.proto
├── database/             ← TypeORM + PostgreSQL
└── common/
    ├── guards/
    └── interceptors/     ← logging + request-id
```

**Trách nhiệm duy nhất:** validate → lưu job DB → gọi orchestrator → map response cho FE.

### orchestrator-ai (Python khuyến nghị)

```
src/
├── server.py             ← gRPC server (orchestrator.proto)
├── workflow/
│   ├── saga.py           ← state machine
│   └── steps.py          ← story_step, image_step
├── clients/
│   ├── story_client.py
│   └── image_client.py
├── state/
│   └── redis_store.py
└── config/
```

### story-ai (Python + Llama)

```
src/
├── server.py             ← gRPC (story_generation.proto)
├── llm/
│   ├── prompt_template.py
│   └── parser.py         ← LLM output → PanelScript JSON
└── config/
```

**Output bắt buộc structured JSON** — không trả plain text cho orchestrator tự parse.

### image-ai (đã có — giữ nguyên pattern)

- gRPC server + Celery worker
- Không thêm business logic story/orchestrator

### deployment

```
deployment/
├── docker-compose.yml
├── VERSIONS.md
└── .env.example          ← biến môi trường toàn stack
```

### documents

```
documents/
├── ARCHITECTURE.md
├── MICROSERVICES_GUIDE.md   ← file này
└── contracts/             ← source of truth
```

---

## 6. Lộ trình implement (theo thứ tự chuẩn microservices)

### Phase 1 — Contract & skeleton (1 tuần)

- [x] Tạo `documents/contracts/` (proto + OpenAPI)
- [x] `deployment/VERSIONS.md`
- [ ] Copy proto vào từng repo + script `sync-contracts.sh`
- [ ] be-comic: NestJS skeleton + `GET /health` + PostgreSQL migration `generation_jobs`
- [ ] orchestrator: gRPC server stub + Redis state store
- [ ] story-ai: gRPC stub trả **mock 4 panels** (chưa cần Llama)

**Done khi:** `orchestrator.StartComicGeneration` → mock story → mock image URLs → `GetComicJobStatus` = SUCCESS

### Phase 2 — Nối image-ai thật (1 tuần)

- [ ] orchestrator gọi image-ai gRPC thật (1 panel trước, rồi 4 panel)
- [ ] be-comic `POST /comics/generate` + `GET /comics/jobs/:id`
- [ ] Async poll flow hoàn chỉnh

**Done khi:** Tóm tắt → 4 ảnh thật từ MinIO qua API be-comic

### Phase 3 — story-ai Llama (1–2 tuần)

- [ ] Thay mock bằng Llama inference
- [ ] Prompt template → `PanelScript[]` + `CharacterProfile`
- [ ] Validate JSON schema trước khi trả orchestrator

### Phase 4 — fe-comic integration (1 tuần)

- [ ] `ComicApiService` generate + poll
- [ ] UI progress bar (1/4, 2/4...)
- [ ] Hiển thị panel + bubble overlay từ `captionVi`

### Phase 5 — Production hardening

- [ ] Character consistency (IP-Adapter panel 0 → 1,2,3)
- [ ] Rate limit trên be-comic
- [ ] CI mỗi repo + integration test trên deployment
- [ ] GPU cloud tách worker (optional)

---

## 7. Checklist “đủ chuẩn microservices” cho luận văn

Dùng checklist này khi bảo vệ:

### Kiến trúc
- [ ] ≥ 4 service độc lập deploy được (fe, be, orchestrator, story, image)
- [ ] Sơ đồ dependency rõ — không vòng tròn
- [ ] Database/cache không share schema giữa service

### Contract
- [ ] Proto/OpenAPI trong repo `documents/contracts/`
- [ ] Mô tả request/response từng bước pipeline
- [ ] Versioning document trong `VERSIONS.md`

### Communication
- [ ] Sync REST chỉ FE ↔ BE
- [ ] gRPC internal cho AI layer
- [ ] Job async cho image generation

### Resilience
- [ ] Retry panel image (không retry cả story)
- [ ] Cancel job propagation
- [ ] Timeout per step

### Operations
- [ ] `deployment/docker-compose.yml` chạy full stack
- [ ] Health check mỗi service
- [ ] `job_id` / `X-Request-Id` trong log

### Demo
- [ ] 1 luồng E2E: nhập tóm tắt → 4 ảnh hiển thị web
- [ ] Giải thích vì sao tách story-ai vs image-ai

---

## 8. Những gì KHÔNG cần (tránh over-engineering đồ án)

| Công nghệ | Có cần không? | Lý do |
|-----------|---------------|-------|
| Kubernetes | Không (giai đoạn đầu) | Docker Compose đủ demo |
| Consul / Eureka | Không | Docker DNS + service name đủ |
| Kafka | Không | Redis + gRPC async đủ |
| API Gateway riêng (Kong) | Không | be-comic đóng vai BFF |
| Service mesh (Istio) | Không | Quá phức tạp cho scope |
| Shared npm/pip library business | Không | Chỉ share contract |

---

## 9. Script tiện ích đề xuất

Tạo `documents/scripts/sync-contracts.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONTRACTS="$ROOT/documents/contracts"

cp "$CONTRACTS/image_generation.proto"  "$ROOT/image-ai/proto/"
cp "$CONTRACTS/story_generation.proto"    "$ROOT/story-ai/proto/"
cp "$CONTRACTS/orchestrator.proto"        "$ROOT/orchestrator-ai/proto/"

echo "Contracts synced. Bump VERSIONS.md if breaking change."
```

Chạy sau mỗi lần sửa contract.

---

## 10. Tóm tắt một câu

**Microservices chuẩn cho ComicSystem = nhiều repo + contract rõ + deploy glue + async saga + data ownership + không gọi chéo lung tung.**

Bạn đã có: `image-ai` (worker pattern tốt), `deployment` (compose), `documents/contracts` (vừa tạo).

Làm tiếp theo đúng thứ tự: **orchestrator saga → be-comic API → story-ai mock → nối image-ai → fe-comic poll**.

---

*Cập nhật khi hoàn thành từng phase. Tham chiếu: [ARCHITECTURE.md](./ARCHITECTURE.md)*
