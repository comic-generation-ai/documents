# Chạy FULL hệ thống ComicSystem trên GPU Cloud (Ubuntu)

> Dành cho máy GPU thuê ngoài (RunPod, Vast.ai, ezycloud, ...) chạy Ubuntu.
> Kết nối qua VS Code **Remote-SSH**. Chạy full 6 tiến trình kể cả `fe-comic` —
> test qua UI Angular thật, không chỉ Swagger `/docs`.

---

## Bước 0 — Thuê GPU, connect Remote-SSH

Mở VS Code → Remote-SSH → connect vào máy GPU đã thuê → mở Terminal tích hợp.

---

## Bước 1 — Cài Docker + Python

Nếu apt báo lỗi do `unattended-upgrades` giữ lock (rất hay gặp trên máy GPU rental
mới boot), dọn lock trước:

```bash
sudo systemctl stop unattended-upgrades 2>/dev/null
sudo pkill -9 -f unattended-upgrade 2>/dev/null
sleep 2
sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock
sudo dpkg --configure -a
```

**Trước khi cài Docker, kiểm tra đã có sẵn chưa** (nhiều image GPU rental cài sẵn Docker):

```bash
docker --version && docker compose version
```

- Nếu đã có → bỏ qua bước cài `docker.io`, chỉ cài Python:
  ```bash
  sudo apt update && sudo apt install -y python3.12-venv
  ```
- Nếu chưa có → cài đầy đủ. Nếu gặp lỗi `containerd.io : Conflicts: containerd`
  (do repo `download.docker.com` đã có sẵn từ trước), chạy `sudo apt remove -y
  containerd` rồi thử lại:
  ```bash
  sudo apt update && sudo apt install -y docker.io docker-compose-v2 python3.12-venv
  ```

Cho user hiện tại dùng Docker không cần `sudo`:

```bash
sudo usermod -aG docker $USER
newgrp docker
```

---

## Bước 2 — Clone code (5 repo)

```bash
mkdir -p ~/ComicSystem && cd ~/ComicSystem
git clone https://github.com/comic-generation-ai/image-ai.git
git clone https://github.com/comic-generation-ai/story-ai.git
git clone https://github.com/comic-generation-ai/orchestrator-ai.git
git clone https://github.com/comic-generation-ai/be-comic.git
git clone https://github.com/comic-generation-ai/fe-comic.git
```

---

## Bước 3 — Đưa 4 file `.env` lên

Sidebar trái VS Code → tab **File Explorer** (đang trỏ máy remote) → kéo-thả 4 file
`.env` từ máy Mac vào đúng chỗ:

- `image-ai/.env`
- `story-ai/.env`
- `orchestrator-ai/.env`
- `be-comic/.env`

(`fe-comic` không dùng `.env` — cấu hình proxy nằm sẵn ở `fe-comic/proxy.conf.json`,
trỏ `"target": "http://localhost:3000"`. Không cần sửa gì vì proxy này chạy trên
chính máy GPU remote — port 3000 remote đúng là be-comic remote, không phải máy Mac.)

**`image-ai/.env`** — bật khối cấu hình GPU cloud SDXL (khối `[D]`), comment các
khối còn lại, đảm bảo đúng các dòng sau (không được để sót dòng
`TURBO_GUIDANCE_SCALE` — model hiện dùng là non-turbo nên phải dùng đúng tên biến
`GUIDANCE_SCALE`):

```dotenv
IMAGE_AI_MODEL_ID=Lykon/dreamshaper-xl-1-0
IMAGE_AI_DEFAULT_STEPS=25
IMAGE_AI_MAX_STEPS=30
IMAGE_AI_GUIDANCE_SCALE=6.0
IMAGE_AI_IP_ADAPTER_ENABLED=true
IMAGE_AI_IP_ADAPTER_SCALE=0.5
```

Cần một **HuggingFace Access Token** (loại Read, tạo ở
huggingface.co/settings/tokens) để tải model — không hard-code vào `.env` rồi
commit lên git. Export tạm trong terminal ở Bước 5, hoặc thêm dòng
`HF_TOKEN=<token của bạn>` vào `image-ai/.env` **miễn là `.env` đã nằm trong
`.gitignore`** (kiểm tra lại trước khi commit bất kỳ thứ gì).

**`orchestrator-ai/.env`** — khớp resolution với image-ai:

```dotenv
ORCHESTRATOR_IMAGE_AI_WIDTH=1024
ORCHESTRATOR_IMAGE_AI_HEIGHT=1024
```

---

## Bước 4 — Hạ tầng Docker (Redis, MinIO, Postgres)

```bash
cd ~/ComicSystem/image-ai && docker compose up -d      # redis + minio
cd ~/ComicSystem/be-comic && docker compose up -d      # postgres
docker ps    # phải thấy 3 container Up
```

---

## Bước 5 — venv + cài đặt từng repo Python

```bash
cd ~/ComicSystem/image-ai
python3.12 -m venv env && source env/bin/activate
pip install -r requirements.txt
bash scripts/generate_proto.sh
export HF_TOKEN="<token của bạn>"
deactivate

cd ~/ComicSystem/story-ai
python3.12 -m venv env && source env/bin/activate
pip install -r requirements.txt
deactivate

cd ~/ComicSystem/orchestrator-ai
python3.12 -m venv env && source env/bin/activate
pip install -r requirements.txt
pip install pydantic-settings   # thiếu trong requirements.txt, cài tay
bash scripts/generate_proto.sh
deactivate
```

---

## Bước 6 — be-comic + fe-comic: cài đặt

```bash
cd ~/ComicSystem/be-comic
npm install
npm run migration:run

cd ~/ComicSystem/fe-comic
npm install
```

---

## Bước 7 — Chạy 6 tiến trình (mỗi cái 1 tab Terminal riêng, để nguyên chạy)

```bash
# Tab 1 — image-ai Celery worker
cd ~/ComicSystem/image-ai && source env/bin/activate
export PYTHONPATH=src
celery -A worker.celery_app:celery_app worker --loglevel=info --concurrency=1 --pool=solo
```

Chờ tới dòng log `KHỞI TẠO CELERY WORKER PROCESS HOÀN TẤT` mới mở tab tiếp theo
(model load xong, warmup xong).

```bash
# Tab 2 — image-ai gRPC server
cd ~/ComicSystem/image-ai && source env/bin/activate
python src/server.py

# Tab 3 — story-ai
cd ~/ComicSystem/story-ai && source env/bin/activate
python src/server.py

# Tab 4 — orchestrator-ai
cd ~/ComicSystem/orchestrator-ai && source env/bin/activate
python src/server.py

# Tab 5 — be-comic
cd ~/ComicSystem/be-comic
npm run start:dev                  # HTTP :3000, Swagger tại /docs
```

Chờ log Tab 5 in ra `CORS origins: http://localhost:4200` rồi mới mở Tab 6.

```bash
# Tab 6 — fe-comic
cd ~/ComicSystem/fe-comic
npm start                          # Angular :4200 (đã có --host 0.0.0.0 sẵn trong package.json)
```

---

## Bước 8 — Forward port, test full luồng từ FE

Panel dưới VS Code → tab **PORTS** → forward 3 port: `4200` (fe-comic, Angular),
`3000` (be-comic API) và `9000` (MinIO, để ảnh load được trong trình duyệt).

Mở `http://localhost:4200` trên máy Mac — test qua UI thật:

1. Đăng ký/đăng nhập (nếu FE yêu cầu auth).
2. Tạo project mới, nhập tóm tắt truyện, chọn style, số panel → bấm sinh truyện.
3. FE tự poll trạng thái job — **kiên nhẫn chờ** (story ~90s + ảnh ~10-12s/panel
   trên GPU, tổng khoảng 2-3 phút cho 4 panel).
4. Xong thấy 4 panel hiện ảnh trong UI — kiểm tra thứ tự panel, prompt có khớp
   ảnh không, bubble/caption có đặt đúng vị trí `speaker_position` không.

**Nếu FE lỗi không tải được ảnh** (ảnh vỡ/404): do URL ảnh MinIO trả về là
`http://127.0.0.1:9000/...` — đúng khi be-comic và trình duyệt cùng máy, nhưng
qua Remote-SSH thì trình duyệt (Mac) và MinIO (remote) là 2 nơi khác nhau. Port
9000 đã forward ở trên nên `127.0.0.1:9000` trên Mac vẫn trỏ đúng vào MinIO remote
— chỉ cần đảm bảo port 9000 xuất hiện trong tab PORTS, không cần sửa gì thêm.

**Test riêng BE qua Swagger** (khi không cần xem UI, chỉ kiểm tra API): mở
`http://localhost:3000/docs`, theo thứ tự `POST /api/projects` →
`POST /api/generation-jobs` → poll `GET /api/generation-jobs/{jobId}` →
`GET /api/frames?projectId=<id>`.

---

## Ghi chú — giới hạn hiện tại của model image-ai (đã kiểm chứng qua nhiều lần test GPU)

- Model đang dùng: `Lykon/dreamshaper-xl-1-0` (SDXL non-turbo) + `h94/IP-Adapter`
  (scale 0.5) — giữ nhất quán trang phục/màu sắc nhân vật khá tốt qua nhiều panel.
- **Hạn chế đã xác nhận nhiều lần**: model vẽ tốt "nhân vật là ai, mặc gì, ở
  đâu" nhưng thường KHÔNG vẽ đúng hành động/động từ cụ thể trong prompt (ví dụ:
  "đang bay", "đang thả sỏi", "đang trèo cây" thường không render đúng — nhân
  vật bị đóng băng ở tư thế tĩnh chung chung). Đây là giới hạn thật của
  SDXL + IP-Adapter ở cấu hình hiện tại, không phải lỗi cấu hình.
- Nếu cảnh có 2+ nhân vật, luôn viết theo format `"on the left, ...; on the
  right, ..."` (đã có sẵn trong `story-ai/src/llm/prompt_template.py`) — thiếu
  format này dễ khiến model trộn lẫn đặc điểm giữa các nhân vật.
