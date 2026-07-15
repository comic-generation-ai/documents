# Kế hoạch nâng cấp chất lượng sinh ảnh — 2 tuần

Mục tiêu: ảnh sinh ra **đẹp hơn**, **đúng ngữ nghĩa prompt hơn**, và **vẽ được 2-3 chủ thể trong 1 ảnh mà không rò thuộc tính**. Môi trường: GPU cloud thuê (16-24GB VRAM). Mỗi mục dưới đây có sẵn code/lệnh copy-paste được — không cần tự nghĩ cách làm.

---

## Tổng quan trạng thái (đã xong, khỏi làm lại)

| Service | Đã xong |
|---|---|
| image-ai | Compel (chunking >77 token), IP-Adapter SD1.5, cache theo hash, caption tách khỏi ảnh (FE render), fallback fp16, fix index=0/composite unique index cho frames |
| orchestrator-ai | `ORCHESTRATOR_IMAGE_AI_STEPS=0`, truyền `style` qua `generate_panel`, trả `seed` thật |
| story-ai | `MODEL_NAME=qwen3.6-flash` (đã verify chạy ~30-40s/truyện), JSON schema `image_prompt`/`dialogue`, nhận diện folklore Việt Nam |

---

## 🎨 image-ai — chủ: tôi

### Tầng 0 — Vệ sinh prompt

**Bước 1 — Tắt style suffix trùng lặp.** Mở `image-ai/.env`, tìm dòng:
```bash
IMAGE_AI_COMIC_STYLE_ENABLED=true
```
Đổi thành `false` (story-ai đã tự nhúng style vào `image_prompt` rồi).

**Bước 2 — Sửa bug mất negative prompt.** File `src/core/pipeline_runner.py`, hàm `_build_negative_prompt` (~dòng 278). Thay:
```python
    def _build_negative_prompt(self, negative_prompt: str, style: str = "") -> str:
        style_to_use = (style or "").strip().lower()
        if style_to_use in STYLE_PRESETS:
            default_neg = STYLE_PRESETS[style_to_use]["negative"]
        elif self.settings.COMIC_STYLE_ENABLED:
            default_neg = self.settings.DEFAULT_NEGATIVE_PROMPT
        else:
            default_neg = ""
```
Thành:
```python
    def _build_negative_prompt(self, negative_prompt: str, style: str = "") -> str:
        style_to_use = (style or "").strip().lower()
        if style_to_use in STYLE_PRESETS:
            default_neg = STYLE_PRESETS[style_to_use]["negative"]
        else:
            # Luôn áp dụng negative mặc định — kể cả khi COMIC_STYLE_ENABLED=false,
            # vì đó là cấu hình STYLE SUFFIX (dương), không liên quan tới việc có
            # cần chặn tay biến dạng/ảnh mờ/photorealistic hay không.
            default_neg = self.settings.DEFAULT_NEGATIVE_PROMPT
```

**Bước 3 — Verify:** restart worker, sinh 1 ảnh, kiểm log **không còn** dòng `Prompt mô tả cảnh bị rút gọn`.

---

### Tầng 1 — Chuyển sang SDXL-Turbo (không sửa pipeline — code đã tự nhận qua `is_sdxl`/`is_turbo`)

Thêm khối profile mới vào `.env`, theo đúng khuôn các khối `[A]/[B]/[C]` đã có — dán ngay dưới khối `[C]`:

```bash
# ---------- [D] SDXL-TURBO — thử nghiệm chất lượng/multi-subject ----------
# IMAGE_AI_ENV=production
# IMAGE_AI_MODEL_ID=Lykon/dreamshaper-xl-v2-turbo
# IMAGE_AI_DEFAULT_STEPS=5
# IMAGE_AI_MAX_STEPS=10
# IMAGE_AI_TURBO_GUIDANCE_SCALE=2.0
# IMAGE_AI_SAFETY_CHECKER_ENABLED=true
# IMAGE_AI_IP_ADAPTER_ENABLED=true
# IMAGE_AI_IP_ADAPTER_SCALE=0.6
# ...và sửa DEFAULT_WIDTH/HEIGHT=1024 ở mục IMAGE GENERATION DEFAULTS phía dưới
# (bắt buộc — SDXL train ở 1024, ép 512 ra ảnh vỡ/lặp bố cục)
# KHÔNG bật LOW_VRAM_MODE — VRAM dư (24GB, đo thực tế dùng có 3.6GB),
# enable_model_cpu_offload chỉ làm chậm, không ảnh hưởng chất lượng.
```

Khi test: comment khối đang dùng, bỏ comment khối `[D]`, **và** sửa tay:
```bash
IMAGE_AI_DEFAULT_WIDTH=1024
IMAGE_AI_DEFAULT_HEIGHT=1024
```
(2 dòng này nằm ở mục `IMAGE GENERATION DEFAULTS`, không khai được trong khối profile — xem comment sẵn có trong `.env` giải thích lý do.)

Restart worker, kiểm log có `IP-Adapter enabled (scale=0.6)` và không lỗi tải model.

---

### Tầng 2 — Xử lý 2-3 chủ thể

**a) Test Compel `.and()` — làm script rời trước khi sửa code chính thức.** Tạo `scratch_compel_and.py` ở gốc `image-ai`:
```python
import sys; sys.path.insert(0, "src")
from core.pipeline_runner import pipeline_runner, ImageRequest

pipeline_runner.initialize_pipeline()

prompt_comma = "girl in red dress, boy in blue armor, standing together, comic style"
prompt_and = '("girl in red dress").and("boy in blue armor"), standing together, comic style'

for name, prompt in [("comma", prompt_comma), ("and", prompt_and)]:
    resp = pipeline_runner.generate(ImageRequest(prompt=prompt, seed=42, steps=pipeline_runner.settings.DEFAULT_STEPS))
    resp.image.save(f"out_compel_{name}.jpg")
    print(f"Đã lưu out_compel_{name}.jpg")
```
So 2 ảnh `out_compel_comma.jpg` vs `out_compel_and.jpg`. Nếu `.and()` cho kết quả tách biệt chủ thể rõ hơn → đưa vào `_encode_with_compel` (dòng ~442) làm phương án mặc định khi phát hiện prompt có ≥2 tên riêng.

**b) Steps động theo độ phức tạp cảnh.** File `src/service/image_service.py`, ngay sau dòng tính `is_fast_model` (~dòng 39), thêm hàm đếm chủ thể và áp dụng khi client không tự ép steps cao:
```python
import re

def _count_subjects(prompt: str) -> int:
    """Đếm sơ bộ số chủ thể qua từ khóa người/danh từ riêng — heuristic, không cần chính xác tuyệt đối."""
    subject_words = re.findall(
        r'\b(girl|boy|man|woman|child|character|[A-Z][a-z]+)\b', prompt
    )
    return len(set(w.lower() for w in subject_words))
```
Trong đoạn xử lý `steps` (~dòng 40-51), thêm nhánh: nếu `requested_steps` do client gửi bằng 0 (để image-ai tự quyết) và `_count_subjects(request.prompt) >= 3`, nâng `steps` lên `min(settings.MAX_STEPS, settings.DEFAULT_STEPS + 3)` — nhiều "thời gian" khử nhiễu hơn cho cảnh đông chủ thể. Chỉ đổi phía image-ai, orchestrator không cần biết gì về logic này.

**c) Regional prompting** — chỉ làm nếu (a)+(b) đo không đủ tốt. Việc kỹ thuật thật (~3-5 ngày), để cuối cùng, không viết trước.

---

### Script test bắt buộc — chạy trước khi merge bất kỳ tầng nào

```bash
# scratch_compare.py — gốc image-ai
import sys, time; sys.path.insert(0, "src")
from core.pipeline_runner import pipeline_runner
from core.pipeline_runner import ImageRequest

PROMPTS = {
    "1_chu_the": "a red fox sitting in a autumn forest, comic book style",
    "2_chu_the": "girl in red dress and boy in blue armor standing together, comic book style",
    "3_chu_the": "a knight, a wizard, and a dragon in a castle courtyard, comic book style",
    "van_hoa_vn": "Tam in yellow ao tu than picking betel nuts in ancient Vietnamese village courtyard, comic book style",
}

pipeline_runner.initialize_pipeline()
for name, prompt in PROMPTS.items():
    start = time.time()
    resp = pipeline_runner.generate(ImageRequest(prompt=prompt, seed=42, steps=pipeline_runner.settings.DEFAULT_STEPS))
    resp.image.save(f"out_{name}.jpg")
    print(f"{name}: {time.time()-start:.1f}s -> out_{name}.jpg")
```
Chạy script này ở **mỗi cấu hình** (SD1.5 baseline / SDXL-turbo trần / SDXL-turbo + Tầng 0 / SDXL-turbo 8 steps) rồi so 4 ảnh cùng tên cạnh nhau qua các lần chạy — không merge dựa trên cảm tính.

---

## 📖 story-ai — chủ: Nhân

**1. Đổi fallback model.** File `src/server.py`, dòng **157**:
```python
fallback_model = "qwen3.7-max-2026-06-08"
```
Đổi thành:
```python
fallback_model = "qwen3.7-plus"
```
(model chính vẫn là `Config.MODEL_NAME` = `qwen3.6-flash`, dòng này chỉ chạy khi model chính lỗi — đổi để lúc lỗi không rơi vào model chậm nhất workspace.)

**2. Thêm hướng dẫn bố cục không gian cho cảnh nhiều nhân vật.** File `src/llm/prompt_template.py`, hàm `get_system_prompt()`, mục `IMAGE PROMPT RULES` (dòng 38-47). Thêm 1 rule mới vào giữa danh sách, ngay trước dòng `- Do NOT include any Midjourney parameters...` (dòng 45):

```python
- When a panel has 2 or more characters, ALWAYS anchor each character to an
  explicit spatial position so the image model can separate their attributes
  correctly. Format: "on the left, [character A description]; on the right,
  [character B description]". For 3 characters use "left / center / right".
  Bad: "a girl in red dress and a boy in blue armor talking"
  Good: "on the left, a girl in red dress; on the right, a boy in blue armor, both facing each other"
```

Sửa lại ví dụ ở dòng 46 để khớp rule mới (đang là ví dụ 1 nhân vật, giữ nguyên được, không bắt buộc đổi — chỉ cần rule trên áp dụng khi có ≥2 nhân vật).

**3. Không cần đổi gì về style** — story-ai tiếp tục tự nhúng style vào `image_prompt` như hiện tại (dòng 46 ví dụ đã có `comic book style, vibrant colors`) — phần dedup là việc của image-ai (Tầng 0, đã tắt suffix phía đó).

**4. Verify sau khi sửa:** chạy 1 truyện có ≥2 nhân vật, xem JSON trả về (cách xem: `docker exec image-ai-redis-1 redis-cli -n 1 get "comic_job:<id>"` như đã làm trước đây), kiểm `image_prompt` có đúng cấu trúc `"on the left, ... on the right, ..."` không.

---

## 🔀 orchestrator-ai — không có việc mới

Đã đúng cấu hình cần thiết. Verify nhanh (không cần sửa):
```bash
grep ORCHESTRATOR_IMAGE_AI_STEPS orchestrator-ai/.env   # phải =0
grep "style=" orchestrator-ai/src/clients/image_client.py  # phải có truyền style
```

---

## Không nằm trong phạm vi đợt này

- **FLUX**: cần viết lại pipeline, để dành "hướng phát triển" khi báo cáo.
- **Bubble vẽ vào ảnh**: FE (Nhân, Angular) vẽ SVG đè lên ảnh — `bubble_renderer.py` giữ làm phương án export dự phòng.
- **Auth, presigned URL endpoint, CRUD bubbles**: thuộc be-comic, theo dõi riêng.
