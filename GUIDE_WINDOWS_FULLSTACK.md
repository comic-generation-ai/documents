# Chạy FULL hệ thống ComicSystem trên Windows (không GPU)

> Dành cho máy Windows không có GPU NVIDIA (vd Acer Aspire 3).
> Ảnh sẽ sinh bằng **CPU** — chậm (~1–3 phút/panel) nhưng đủ để test full luồng.
> **Mẹo quan trọng nhất:** chỉ cần sinh truyện thành công **1 lần** — kết quả nằm
> vĩnh viễn trong Postgres, sau đó dev UI (bubble, reader...) thoải mái mà
> không cần sinh lại. Đừng sinh truyện mỗi lần muốn xem UI!

---

## 0. Cài đặt một lần (prerequisites)

| Phần mềm | Link | Ghi chú |
|---|---|---|
| **Git for Windows** | git-scm.com | Cài xong có **Git Bash** — DÙNG GIT BASH CHO MỌI LỆNH trong guide này (lệnh `source`, `export`, script `.sh` chạy y hệt hướng dẫn của team) |
| **Docker Desktop** | docker.com | Lúc cài chọn WSL2 backend. Nếu báo lỗi virtualization → vào BIOS bật VT-x/SVM |
| **Python 3.11 hoặc 3.12** | python.org | Lúc cài TÍCH Ô "Add python.exe to PATH" |
| **Node.js 20+** | nodejs.org | Cho be-comic + fe-comic |
| Tài khoản HuggingFace | huggingface.co | Tạo Access Token loại Read (Settings → Access Tokens) — tải model nhanh |

## 1. Clone code (Git Bash)

```bash
cd ~
mkdir ComicSystem && cd ComicSystem
git clone https://github.com/comic-generation-ai/image-ai.git
git clone https://github.com/comic-generation-ai/story-ai.git
git clone https://github.com/comic-generation-ai/orchestrator-ai.git
git clone https://github.com/comic-generation-ai/be-comic.git
git clone https://github.com/comic-generation-ai/fe-comic.git
```

## 2. Xin file `.env` (KHÔNG có trong git)

4 file `.env` của: `image-ai`, `orchestrator-ai`, `story-ai`, `be-comic`
(story-ai chứa API key LLM — gửi kênh riêng tư). Bỏ từng file vào đúng thư mục repo.

Sau đó **sửa 2 chỗ trong `image-ai/.env`** cho máy CPU:
1. Khối PROFILE đầu file: comment toàn bộ khối **[A]**, mở khối **[C] LAPTOP CPU**.
2. Mục `IMAGE GENERATION DEFAULTS`: sửa `IMAGE_AI_DEFAULT_WIDTH=384` và
   `IMAGE_AI_DEFAULT_HEIGHT=384` (CPU vẽ 384px nhanh gần gấp đôi 512px).

## 3. Hạ tầng Docker (Redis + MinIO + Postgres)

Mở Docker Desktop trước, đợi nó chạy hẳn, rồi trong Git Bash:

```bash
cd ~/ComicSystem/image-ai && docker compose up -d     # redis :6379 + minio :9000
cd ~/ComicSystem/be-comic && docker compose up -d     # postgres :5432
docker ps   # phải thấy 3 container Up
```

## 4. image-ai (nặng nhất — làm trước, tải ~4GB model lần đầu)

```bash
cd ~/ComicSystem/image-ai
py -m venv env
.\env\Scripts\activate        # Windows venv: Scripts chứ không phải bin
pip install -r requirements.txt    # ~10-15 phút (torch CPU ~200MB + thư viện)
bash scripts/generate_proto.sh     # biên dịch gRPC stubs

# Chạy worker (TERMINAL 1 — để nguyên chạy):
$env:HF_TOKEN="<YOUR_HUGGINGFACE_TOKEN>"
$env:PYTHONPATH="src"
celery -A worker.celery_app:celery_app worker --loglevel=info --concurrency=1 --pool=solo
```
Lần đầu tải model ~4GB rồi warmup. **Chờ đến dòng
`KHỞI TẠO CELERY WORKER PROCESS HOÀN TẤT`** — trên CPU, warmup có thể mất vài phút.
Log phải có `Running on device: cpu` (đúng — máy này không có GPU).

Mở Git Bash mới (**TERMINAL 2**):
```bash
cd ~/ComicSystem/image-ai && source env/Scripts/activate
docker compose up -d
python src/server.py               # gRPC :50051 + health :8000
```

New-Item -ItemType Directory -Force -Path src/service/generated

python -m grpc_tools.protoc -Iproto --python_out=src/service/generated --pyi_out=src/service/generated --grpc_python_out=src/service/generated proto/image_generation.proto

(Get-Content src/service/generated/image_generation_pb2_grpc.py) -replace 'import image_generation_pb2', 'from . import image_generation_pb2' | Set-Content src/service/generated/image_generation_pb2_grpc.py


## 5. story-ai (TERMINAL 3)

```bash
cd ~/ComicSystem/story-ai
python -m venv env && source env/Scripts/activate
pip install -r requirements.txt
python src/server.py               # HTTP :50052
```

## 6. orchestrator-ai (TERMINAL 4)

```bash
cd ~/ComicSystem/orchestrator-ai
python -m venv env && source env/Scripts/activate
pip install -r requirements.txt
bash scripts/generate_proto.sh
python src/server.py               # gRPC :50054
```

## 7. be-comic (TERMINAL 5)

```bash
cd ~/ComicSystem/be-comic
npm install
npm run migration:run              # dựng schema Postgres
docker compose up -d
npm run start:dev                  # HTTP :3000, Swagger tại /docs
```
Log phải in `CORS origins: http://localhost:4200`.

## 8. fe-comic (TERMINAL 6)

Kiểm tra `proxy.conf.json` trỏ `"target": "http://localhost:3000"` rồi:
```bash
cd ~/ComicSystem/fe-comic
npm install
npm start                          # Angular :4200
```

## 9. Test full luồng (lần sinh truyện DUY NHẤT cần kiên nhẫn)

Qua UI Angular, hoặc bằng Swagger `http://localhost:3000/docs`:

1. `POST /api/projects` → `{"title": "Test", "rawPrompt": "Chú mèo Miu nhặt được viên sỏi phát sáng bên bờ biển."}` → lấy `id`.
2. `POST /api/generation-jobs` → `{"projectId": "<id>", "summary": "Chú mèo Miu nhặt được viên sỏi phát sáng bên bờ biển.", "style": "storybook", "numPanels": 4}`.
3. Poll `GET /api/generation-jobs/{jobId}` — **trên CPU tổng ~5–15 phút** (story ~30s
   + 4 panel × 1–3 phút). Nhìn log Terminal 1 thấy thanh % từng panel chạy là đang sống.
4. Xong: `GET /api/frames?projectId=<id>` → 4 frame. `GET /api/frames/{frameId}/image-url`
   → mở URL xem ảnh.

**Từ giây phút này**: 4 frame + caption + (sau này) bubbles nằm trong Postgres của máy
bạn. Dev màn đọc truyện / editor bubble / nút Save → chỉ đụng be-comic + Postgres,
**không cần 4 terminal AI nữa** (tắt đi cho nhẹ máy — mở lại khi nào cần sinh truyện mới).

---

## Lỗi thường gặp

| Triệu chứng | Nguyên nhân / cách sửa |
|---|---|
| `docker compose` báo cannot connect | Docker Desktop chưa mở / WSL2 chưa bật |
| Port 8000/3000/6379... đã bị chiếm | `netstat -ano \| findstr :3000` tìm process, hoặc đổi PORT trong .env |
| Worker báo `No module named 'service.generated'` | quên chạy `bash scripts/generate_proto.sh` |
| `pydantic_settings` not found (orchestrator) | `pip install pydantic-settings` (đã có trong requirements bản mới — pull lại) |
| Sinh ảnh cực chậm + máy đơ | đúng như dự báo với CPU — kiểm tra đã dùng profile [C] + 384px chưa; đóng Chrome bớt |
| Ảnh không mở được từ URL | container minio có đang Up không (`docker ps`) |
| POST job trả 500 "Active pipeline AI error" | orchestrator (T4) chưa chạy, hoặc chuỗi AI chưa lên đủ |
