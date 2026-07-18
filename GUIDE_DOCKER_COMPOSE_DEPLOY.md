# Chạy ComicSystem qua Docker Compose — Local & GPU Cloud

> Cách này chạy **cả 5 service bằng đúng 1 lệnh** (`docker compose up`), khác với
> `GUIDE_GPU_CLOUD_FULLSTACK.md`/`GUIDE_WINDOWS_FULLSTACK.md` (mở tay 6 tab
> terminal, dùng khi đang code/debug cần hot-reload + xem log riêng từng service).
> Dùng guide này khi: test full hệ thống như production thật, hoặc demo/bảo vệ
> đồ án không muốn quản 6 tab terminal.

---

## 0. Chuẩn bị chung (cả local lẫn GPU cloud)

Clone **6 repo** cùng cấp thư mục (`deployment` là repo riêng, không nằm trong 5 repo kia):

```bash
mkdir -p ~/ComicSystem && cd ~/ComicSystem
git clone https://github.com/comic-generation-ai/deployment.git
git clone https://github.com/comic-generation-ai/image-ai.git
git clone https://github.com/comic-generation-ai/story-ai.git
git clone https://github.com/comic-generation-ai/orchestrator-ai.git
git clone https://github.com/comic-generation-ai/be-comic.git
git clone https://github.com/comic-generation-ai/fe-comic.git
```

Đưa 4 file `.env` thật (kéo-thả qua VS Code File Explorer nếu remote, copy trực
tiếp nếu local) vào đúng chỗ — **`fe-comic` không cần `.env`**, `deployment`
cũng không cần:

| File | Bắt buộc phải có |
|---|---|
| `image-ai/.env` | Đúng khối profile đang bật (xem mục 2/3 bên dưới), `HF_TOKEN` |
| `story-ai/.env` | `API_KEY` thật — thiếu thì story-ai âm thầm chạy mock mode |
| `orchestrator-ai/.env` | Resolution khớp image-ai (`ORCHESTRATOR_IMAGE_AI_WIDTH/HEIGHT`) |
| `be-comic/.env` | `JWT_SECRET`, MinIO/Postgres creds |

---

## 1. Chạy LOCAL (máy dev, không GPU) — full e2e, chậm nhưng đủ để test luồng

Dùng khi muốn kiểm tra toàn bộ luồng FE→BE→AI chạy đúng trước khi tốn tiền
thuê GPU, hoặc dev không có GPU rời.

**Docker Desktop** cần cài sẵn (docker.com) — máy này đã có `Docker 27.5.1` +
`Compose v2.32.4`, bỏ qua bước cài.

> **Lưu ý quan trọng — Apple Silicon (M1/M2/M3) KHÔNG dùng được MPS trong
> Docker**: Docker Desktop trên Mac chạy container Linux qua VM, không pass
> được Metal/MPS vào bên trong — `torch.backends.mps.is_available()` luôn trả
> `False` trong container dù máy host là Apple Silicon. `image-ai` sẽ tự rơi
> về **CPU** (chậm, ~1-3 phút/panel giống hệt case Windows CPU trong
> `GUIDE_WINDOWS_FULLSTACK.md`), không nhanh như chạy `venv` trực tiếp trên Mac.
> Đây là giới hạn của Docker, không phải bug — nếu cần tốc độ MPS thật, chạy
> `image-ai` bằng `venv` tay (theo cách cũ), không qua Docker.

`image-ai/.env` nên để khối **`[A]` (dev Mac)** hoặc **`[C]` (CPU laptop)** đang
active — khối `[D]` (GPU non-turbo, 25-30 steps) sẽ rất chậm trên CPU.

Container `image-ai` bind-mount thẳng `image-ai/.cache` của máy host (xem
`deployment/docker-compose.yml`) thay vì tải mới vào volume trống — nếu đã
từng dev bằng `venv` trên máy này trước đó, model đã tải sẵn sẽ được tái dùng
luôn, không tải lại vài GB. Máy mới toanh (chưa dev venv lần nào) thì vẫn phải
tải lần đầu như bình thường, chỉ là **lần sau** (kể cả `docker compose down`
rồi `up` lại, hay chuyển qua chạy `venv` tay) sẽ không phải tải lại nữa vì
chung 1 thư mục cache trên đĩa.

```bash
cd ~/ComicSystem/deployment
docker compose up -d --build
docker compose ps          # đợi tới khi tất cả Up/healthy
```

Mở `http://localhost:4200` (fe-comic) — không cần forward port gì vì đang chạy
ngay trên máy đứng test.

---

## 2. Chạy GPU CLOUD — full e2e với tốc độ GPU thật

### 2a. Cài Docker (nếu máy rental chưa có sẵn)

Xem đúng bẫy `unattended-upgrades` lock + `containerd.io` conflict đã ghi trong
`GUIDE_GPU_CLOUD_FULLSTACK.md` Bước 1 — làm y hệt trước khi qua bước dưới.

### 2b. Cài thêm NVIDIA Container Toolkit (bắt buộc riêng cho Docker thấy GPU)

Cài Docker thường KHÔNG đủ để container truy cập GPU — thiếu bước này thì dù
bật khối GPU trong compose vẫn không thấy card:

```bash
sudo apt install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

### 2c. Bật khối GPU trong `deployment/docker-compose.yml`

Mở file, tìm khối comment cuối service `image-ai-worker`, bỏ `#`:

```yaml
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
```

### 2d. `image-ai/.env` phải đang bật khối `[D]` (GPU non-turbo)

Comment hết các khối khác, chỉ để `[D]` active — đúng config đã kiểm chứng
qua nhiều lần test GPU trong session này (`Lykon/dreamshaper-xl-1-0`,
`GUIDANCE_SCALE=6.0`, `IP_ADAPTER_SCALE=0.5`, `STEPS=25`).

### 2e. Build và chạy

```bash
cd ~/ComicSystem/deployment
docker compose up -d --build
docker compose logs -f image-ai-worker   # phải thấy "Running on device: cuda"
```

### 2f. Forward port, test qua VS Code Remote-SSH

Panel **PORTS** → forward `4200` (fe-comic). Mở `http://localhost:4200` trên
Mac — MinIO/be-comic không cần forward riêng vì fe-comic gọi chúng qua network
nội bộ Docker (`comic-internal`), không phải qua trình duyệt trực tiếp như
cách chạy multi-terminal cũ.

---

## 3. Test full luồng E2E (áp dụng cho cả 2 cách trên)

Qua UI `http://localhost:4200`:

1. Đăng ký/đăng nhập (nếu có).
2. Tạo project, nhập tóm tắt truyện, chọn style, số panel → sinh truyện.
3. Chờ — local/CPU: ~5-15 phút cho 4 panel; GPU: ~2-3 phút cho 4 panel
   (story ~90s + ảnh ~10-12s/panel).
4. Xem 4 panel hiện ảnh đúng thứ tự, prompt khớp ảnh, bubble đặt đúng
   `speaker_position`.

---

## 4. Vận hành cơ bản

```bash
docker compose logs -f <tên service>     # xem log 1 service (vd image-ai-worker, be-comic)
docker compose ps                        # trạng thái tất cả container
docker compose down                      # dừng toàn bộ, giữ volume (data không mất)
docker compose down -v                   # dừng + XOÁ VOLUME (mất data Postgres/MinIO — cẩn thận)
docker compose up -d --build <tên service>  # build + chạy lại riêng 1 service sau khi sửa code
```

---

## Ghi chú — giới hạn hiện tại của model image-ai (đã kiểm chứng qua nhiều lần test GPU)

- Model đang dùng: `Lykon/dreamshaper-xl-1-0` (SDXL non-turbo) + `h94/IP-Adapter`
  (scale 0.5) — giữ nhất quán trang phục/màu sắc nhân vật khá tốt qua nhiều panel.
- Model vẽ tốt "nhân vật là ai, mặc gì, ở đâu" nhưng thường KHÔNG vẽ đúng
  hành động/động từ cụ thể trong prompt (bay, thả sỏi, trèo cây...) — giới hạn
  thật của SDXL + IP-Adapter, không phải lỗi cấu hình.
- Prompt 2+ nhân vật luôn theo format `"on the left, ...; on the right, ..."`
  (đã có sẵn trong `story-ai/src/llm/prompt_template.py`) — pipeline tự tách
  sinh riêng từng nhân vật rồi ghép ảnh khi gặp đúng format này
  (`image-ai/src/core/pipeline_runner.py`), tránh lỗi lẫn đặc điểm 2 nhân vật.
