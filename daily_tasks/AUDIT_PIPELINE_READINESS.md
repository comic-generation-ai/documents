# Audit mức độ sẵn sàng pipeline FE → BE → Orchestrator → Story-AI → Image-AI

Ngày: 2026-07-10

Rà soát toàn bộ 5 service (`fe-comic`, `be-comic`, `orchestrator-ai`, `story-ai`,
`image-ai`) để trả lời câu hỏi: luồng dữ liệu **thật** (không mock) từ khi người
dùng bấm "Generate Comic" trên FE tới khi nhận được ảnh truyện tranh thật đã
chạy được end-to-end chưa.

---

## Kết luận chung

**SẴN SÀNG MỘT PHẦN.** Logic ở cả 4 service phía sau `fe-comic` đều là code
**thật** — gọi LLM thật (story-ai), sinh ảnh Stable Diffusion thật (image-ai),
điều phối gRPC/HTTP thật giữa các service (orchestrator-ai) — không phải mock
giả vờ hoàn thiện. Tuy nhiên có vài lỗi chặn (blocking bugs) phải sửa trước khi
chạy được, và một vài chỗ cần cấu hình đúng.

| Service | Trạng thái | Vấn đề chặn chạy |
|---|---|---|
| `fe-comic` | ✅ Đã nối dây thật (fix trong phiên trước) | `projectId` hardcode tạm, chưa có project picker |
| `be-comic` | ✅ Hoạt động tốt, đã verify JSON đúng field | Không |
| `orchestrator-ai` | 🟡 Code logic thật, đủ cả 3 gRPC method | `requirements.txt` thiếu `pydantic`/`pydantic-settings`; `docker-compose.yml` + `Dockerfile` rỗng 0 byte |
| `story-ai` | 🟡 Gọi LLM thật (Qwen-plus qua OpenRouter/Alibaba), có API key hợp lệ | Không blocking, chỉ có bug nhỏ tên biến env không khớp |
| `image-ai` | 🟡 Pipeline Stable Diffusion thật, đã test E2E | `docker-compose.yml` comment hết service `api-server`/`celery-worker` |

---

## Chi tiết từng service

### fe-comic

Đã hoàn thiện:
- Nút "Generate Comic" gọi API thật `POST /api/generation-jobs` qua
  `ComicApiService` (trước đó dùng `setTimeout` giả lập, đã sửa).
- `cancelJob()` đã sửa từ `POST .../cancel` (route không tồn tại ở BE) sang
  `DELETE /api/generation-jobs/:id` (đúng route thật).
- Proxy `proxy.conf.json` forward `/api` sang `be-comic` (`localhost:3000`)
  hoạt động đúng — đã verify bằng request qua cổng FE (4200).

Còn thiếu:
- `projectId` đang hardcode tạm (`DEV_PROJECT_ID` trong
  `comic-editor-page.ts`) vì FE chưa có luồng auth + chọn/tạo project thật.
- Login/Register hiện chỉ mock (`console.log` + điều hướng route), khớp với
  việc `be-comic` chưa có auth JWT (xem TODO trong README `be-comic`).

### be-comic

Đã verify:
- `POST /api/generation-jobs` nhận đúng 4 field (`projectId`, `summary`,
  `style`, `numPanels`), không thiếu không thừa — kiểm chứng bằng debug log
  tạm thời trong `generation-jobs.controller.ts` (đã xoá sau khi test).
- Tiếng Việt (dấu) trong `summary` được giữ nguyên UTF-8 chính xác qua toàn
  bộ pipeline HTTP.
- Khi orchestrator tắt: trả đúng `500 "Active pipeline AI error"`, job được
  ghi DB với `status = FAILED` — đúng hành vi thiết kế ở chế độ test khô.

### orchestrator-ai

Đã hoàn thiện:
- Cả 3 gRPC method (`StartComicGeneration`, `GetComicJobStatus`,
  `CancelComicJob`) + `CheckHealth` implement thật, không TODO/mock/
  NotImplementedError (`src/service/orchestrator_service.py`).
- `StoryClient` gọi HTTP thật sang story-ai, có validate cờ `is_fallback` —
  mặc định **chặn job** nếu story-ai trả kết quả mock, trừ khi set
  `ORCHESTRATOR_STORY_ALLOW_FALLBACK=true`.
- `ImageAiClient` gọi gRPC thật sang image-ai (`GenerateImageAsync` + poll
  `GetTaskStatus`), có dùng panel đầu làm reference image cho panel sau.
- Enum `ComicJobStatus` trong `proto/orchestrator.proto` khớp 100% với mô tả
  trong README `be-comic` (2=STORY_GENERATING, 4=IMAGE_GENERATING, 6=SUCCESS,
  7=FAILED, 8=CANCELLED).
- `.env` đã set đúng `ORCHESTRATOR_GRPC_PORT=50054`.

Còn thiếu / cần sửa:
1. **[Chặn]** `requirements.txt` **không có** `pydantic` / `pydantic-settings`,
   nhưng `src/config/settings.py` import cả hai → `pip install` xong sẽ
   `ImportError` khi start. **Cần thêm 2 package này vào `requirements.txt`.**
2. `docker-compose.yml` và `Dockerfile` **rỗng 0 byte** — không có cách tự
   dựng hạ tầng qua Docker, phải tự chạy Redis riêng cho orchestrator thủ công.
3. `.env.example` mặc định port orchestrator trùng port mặc định của story-ai
   (50052) — dễ gây nhầm khi setup máy mới (bản `.env` thật đang dùng đúng
   50054 nên hiện tại không phải vấn đề thực tế).
4. `ORCHESTRATOR_STORY_ALLOW_FALLBACK` chưa set trong `.env` (mặc định
   `False`) — nếu story-ai fallback (hết quota/lỗi key), job sẽ FAILED ngay,
   không sinh ảnh mock (đây là thiết kế cố ý, xem
   `FIX_STORY_ORCHESTRATOR_DATA.md`).

### story-ai

Đã hoàn thiện:
- FastAPI HTTP service (`POST /generate-story`, `GET /health`), **không phải
  gRPC** như tên "port 50052" gợi ý.
- Gọi LLM thật qua OpenRouter/Alibaba DashScope (model `qwen-plus`) bằng
  `openai` SDK, có retry 3 lần + chuyển model fallback khi rate-limit, parse
  JSON + validate Pydantic đầy đủ (`src/server.py`).
- `.env` đã có `API_KEY` thật (không rỗng) — chạy LLM thật, không rơi vào chế
  độ mock trong điều kiện bình thường.
- `.env` và `api_key.txt` đã nằm trong `.gitignore` — không lộ secret.
- Cơ chế fallback mock có cờ `is_fallback` rõ ràng để orchestrator biết mà
  fail sớm thay vì tốn GPU sinh ảnh từ prompt rác.

Vấn đề nhỏ (không chặn chạy):
- `.env` dùng biến `GRPC_PORT` nhưng `src/config.py` đọc `PORT` — tên biến
  không khớp, hiện tại "ăn may" vì cùng rơi về default `50052`. Có vẻ sót lại
  từ thời còn dùng gRPC. Nên đổi tên biến cho nhất quán.
- `requirements.txt` không liệt kê `httpx` dù `server.py` import trực tiếp —
  chạy được nhờ `openai` SDK kéo theo như transitive dependency, nhưng nên
  khai báo tường minh.

### image-ai

Đã hoàn thiện:
- Pipeline Stable Diffusion thật (`dreamshaper-8`, diffusers/torch), đã test
  E2E bằng `tests/test_client.py` — không phải stub/dummy.
- gRPC async đầy đủ: `GenerateImageAsync`, `GetTaskStatus`, `CancelTask`,
  `CheckHealth`/`Gpu`/`Cpu`, `ClearGpuCache`.
- Celery (concurrency=1) + Redis cache (MD5 hash, chống thundering-herd) +
  MinIO upload từ RAM — đã chạy thật.
- Safety filter NSFW thật (`Falconsai/nsfw_image_detection`), có validate
  ảnh đen/hỏng ở output.
- Pillow caption tiếng Việt, 5 style preset, prompt engineering chống cắt
  mất suffix.
- Health check `/healthz` đọc đúng cờ Redis `image_ai:worker_ready`.

Còn thiếu / chưa xong:
1. **[Chặn nếu muốn chạy qua Docker]** `docker-compose.yml` — service
   `api-server` và `celery-worker` bị **comment toàn bộ**, chỉ Redis+MinIO
   chạy qua Docker. gRPC server và Celery worker phải chạy **local thủ công**
   (`python src/server.py` + `celery -A worker.celery_app worker`), chưa có
   cấu hình GPU runtime (nvidia) trong compose.
2. `Dockerfile` compile proto sai path (`./src/image_generation_pb2.py` thay
   vì đúng thư mục `service/generated/`) — **phải sửa trước khi** bật lại 2
   service bị comment ở trên, nếu không container sẽ lỗi import.
3. Character consistency (IP-Adapter): code đã xong nhưng **tắt mặc định**
   (`IMAGE_AI_IP_ADAPTER_ENABLED=false`) vì bật lên trên máy yếu (Mac 8GB)
   chậm gấp ~10 lần (745s/panel) — không khả thi cho demo nhanh.
4. Trang ghép 2×2 (4 panel): **chưa có** — `page_assembler.py` và API
   `GenerateComicPage` đều chưa code.
5. Speech bubble theo nhân vật: proto có field nhưng **chưa implement**,
   hiện chỉ có 1 caption cố định ở đáy ảnh.
6. Model weights không cần tải thủ công — HuggingFace tự tải khi Celery
   worker start lần đầu (cần internet, không commit vào git).

---

## Việc cần làm theo thứ tự ưu tiên

1. **[Chặn]** Fix `orchestrator-ai/requirements.txt` — thêm `pydantic` và
   `pydantic-settings`.
2. **[Nên làm]** Fix `image-ai/Dockerfile` — sửa path compile proto, cần làm
   trước khi uncomment service trong `docker-compose.yml` nếu muốn chạy qua
   Docker thay vì thủ công.
3. **[Cấu hình]** `orchestrator-ai/.env` — cân nhắc set
   `ORCHESTRATOR_STORY_ALLOW_FALLBACK=true` nếu muốn test nhanh mà không cần
   lo story-ai fallback làm fail job sớm (mặc định `false` = chặn, đúng thiết
   kế production).

---

## Các bước khởi động để chạy luồng dữ liệu thật đầy đủ

```bash
# 1. image-ai
cd image-ai
docker compose up -d redis minio
./scripts/generate_proto.sh
python src/server.py                                  # gRPC 50051 + HTTP health 8000
# terminal khác:
cd src && celery -A worker.celery_app worker --loglevel=info --concurrency=1
# lần đầu sẽ tải model Stable Diffusion từ HuggingFace, có thể mất vài phút

# 2. story-ai
cd story-ai
pip install -r requirements.txt
python src/server.py                                  # HTTP port 50052

# 3. orchestrator-ai
cd orchestrator-ai
pip install -r requirements.txt pydantic pydantic-settings
# cần Redis riêng cho orchestrator: redis://localhost:6379/1
python -m src.server                                   # gRPC port 50054

# 4. be-comic
cd be-comic
docker compose up -d                                   # Postgres port 5433
npm run migration:run                                  # chỉ cần nếu DB rỗng
npm run start:dev                                       # port 3000

# 5. fe-comic
cd fe-comic
npm start                                                # port 4200, proxy sang 3000
```

Sau khi cả 5 service chạy, bấm "Generate Comic" trên UI sẽ đi qua đúng chuỗi
thật: FE → BE (ghi job) → Orchestrator (điều phối) → Story-AI (sinh kịch bản
bằng Qwen-plus) → Image-AI (sinh ảnh Stable Diffusion) → BE lưu frame vào
Postgres → FE poll thấy `COMPLETED` với ảnh thật.

**Lưu ý về thời gian:** trên máy không có GPU rời (CPU/LCM), một job 4 panel
có thể mất **3–5 phút**; lần chạy Celery worker đầu tiên còn tốn thêm vài
phút tải model Stable Diffusion (~2-4GB) từ HuggingFace.
