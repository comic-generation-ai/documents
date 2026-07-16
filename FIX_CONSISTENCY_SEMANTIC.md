# Fix: nhất quán nhân vật + bám sát ngữ nghĩa prompt

Bổ sung cho `PLAN_IMAGE_GENERATION_UPGRADE.md` — các phát hiện này đến từ việc đọc
trực tiếp source code (`image-ai/pipeline_runner.py`, `story-ai/prompt_template.py`,
`orchestrator-ai/comic_job.py`, `be-comic` DTO) chứ không suy từ tài liệu cũ.

---

## Bối cảnh — vì sao cần sửa

**Nhất quán nhân vật:** IP-Adapter (`pipeline_runner.py:390-397, 694-708`) chỉ dùng
ảnh **panel 1** làm reference cho panel 2/3/4 (`orchestrator-ai/comic_job.py:230-258`,
không chain nối tiếp). Đây là cơ chế **toàn ảnh** — không tách được "chỉ giữ mặt nhân
vật A" khỏi bố cục/nền — nên nếu panel 1 có nhiều nhân vật, các panel sau dễ bị kéo
giống bố cục panel 1. Đây là giới hạn kỹ thuật của IP-Adapter chuẩn, không phải bug,
không có cách sửa rẻ tiền (muốn giải quyết dứt điểm phải làm regional prompting —
để sau, ~3-5 ngày công).

**Bám sát ngữ nghĩa:** `_encode_with_compel` chỉ nối chunk tuần tự thành 1
conditioning tensor — không có compositional/regional binding, cross-attention CLIP
chuẩn vẫn dễ "rò" thuộc tính giữa 2-3 nhân vật trong 1 prompt. Compel `.and()` đã
test và không tương thích (xem `PLAN_IMAGE_GENERATION_UPGRADE.md`), không dùng được.
Cách sửa khả thi duy nhất trong 2 tuần: bắt LLM tự cấu trúc câu rõ ràng theo vị trí
không gian, thay vì để SD tự đoán.

Cả 2 vấn đề đều cần sửa ở **story-ai** (LLM là nơi duy nhất kiểm soát được cấu trúc
câu và mô tả nhân vật) — image-ai chỉ nhận prompt dạng text thuần, không tự thêm
được cấu trúc ngữ nghĩa.

---

## Phần A — story-ai (chủ: Nhân)

File `src/server.py`, dòng **157**:
```python
fallback_model = "qwen3.7-max-2026-06-08"
```
đổi thành:
```python
fallback_model = "qwen3.7-plus"
```
(model chính vẫn `qwen3.6-flash`, dòng này chỉ chạy khi model chính lỗi.)

File `src/llm/prompt_template.py`, hàm `get_system_prompt()`, khối
`IMAGE PROMPT RULES` (dòng 38-48). Tìm dòng 45:
```python
- Do NOT include any Midjourney parameters (e.g., do NOT use --ar, --v, --style, etc.).
```
Chèn 2 rule mới ngay phía trên dòng đó (giữa dòng 44 và 45):
```python
- When a panel has 2 or more characters, ALWAYS anchor each character to an
  explicit spatial position so the image model can separate their attributes
  correctly. Format: "on the left, [character A description]; on the right,
  [character B description]". For 3 characters use "left / center / right".
  Bad: "a girl in red dress and a boy in blue armor talking"
  Good: "on the left, a girl in red dress; on the right, a boy in blue armor, both facing each other"
- When the same character appears in multiple panels, describe their key visual
  identifiers (hair, clothing, distinguishing features) using the EXACT SAME
  wording every time — do not paraphrase panel to panel. This keeps the
  character's appearance consistent across the whole comic.
  Bad: panel 1 "a girl with long black hair in a red ao dai"; panel 3 "young woman in a crimson traditional dress"
  Good: panel 1 "a girl with long black hair in a red ao dai"; panel 3 "a girl with long black hair in a red ao dai, now smiling"
```

**Verify:** chạy 1 truyện ≥2 nhân vật, cùng nhân vật xuất hiện ở ≥2 panel. Xem JSON
trả về (`docker exec image-ai-redis-1 redis-cli -n 1 get "comic_job:<id>"`), kiểm:
1. Panel ≥2 nhân vật có cấu trúc `"on the left,... on the right,..."`.
2. Cùng 1 nhân vật ở các panel khác nhau viết mô tả giống hệt từ ngữ.

---

## Phần B — be-comic — style không có validate

File `src/module/generation-jobs/dto/create-generation-job.dto.ts`.

**Vấn đề:** field `style` (dòng 13-16) hiện chỉ `@IsString() @IsOptional()`, không
giới hạn giá trị. `image-ai/pipeline_runner.py` tra `STYLE_PRESETS` với đúng 5 key:
`storybook / anime / manga / retro / american_comic`. Nếu FE gửi tên lệch (sai
chính tả, khác casing...), image-ai âm thầm rơi về `DEFAULT_NEGATIVE_PROMPT` chung
chung, mất hẳn negative-prompt tinh chỉnh riêng cho style đó — không log lỗi nào.

Dòng luồng xác nhận qua code: `be-comic/generation-jobs.service.ts:109` —
`style: dto.style || 'storybook'` → forward xuống `orchestrator-ai/comic_job.py` →
dùng field này cho **cả 2** lệnh gọi: `story_client.generate_story(style=...)` (LLM
biết `ART STYLE: {style}`) và `image_client.generate_panel(style=...)` (image-ai tra
`STYLE_PRESETS`). Default `'storybook'` đã khớp sẵn 1 trong 5 key, nên fix dưới đây
không phá luồng hiện có.

**Sửa dòng 1** (thêm `IsIn`):
```typescript
import { IsUUID, IsString, IsNotEmpty, IsOptional, IsInt, Min, Max, MaxLength, IsIn } from 'class-validator';
```

**Sửa khối `style`** (dòng 13-16), từ:
```typescript
    @IsString()
    @IsOptional()
    @MaxLength(100)
    style?: string;
```
thành:
```typescript
    @IsIn(['storybook', 'anime', 'manga', 'retro', 'american_comic'])
    @IsOptional()
    style?: string;
```

**Lưu ý trước khi merge:** sau fix này, style không khớp đúng 1 trong 5 tên sẽ bị
từ chối ngay (400 Bad Request) khi tạo generation-job, thay vì âm thầm chạy với
chất lượng kém hơn như trước. Cần Nhân xác nhận dropdown chọn style ở FE đang gửi
đúng 5 giá trị này (chữ thường, đúng chính tả, có gạch dưới ở `american_comic`)
trước khi merge — nếu FE chưa khớp thì sửa FE trước.

**Verify:** `npm run start:dev`, gọi `POST /api/generation-jobs` với
`style: "anime"` (phải qua) và `style: "xyz"` (phải trả 400).

---

## Phần C — style: đang có 1 nguồn sai, không phải "2 style"

**Phát hiện:** `_build_prompt` (`pipeline_runner.py:240-243`) đã tra đúng
`STYLE_PRESETS[style_to_use]` theo CHÍNH style user gửi xuống — không phải suffix
cố định chung chung. Vấn đề thật nằm ở `story-ai`: câu ví dụ dòng 46 trong
`get_system_prompt()` có đuôi `"comic book style, vibrant colors, detailed line
art"` là **chữ tĩnh, không đổi theo style user chọn** — dù user chọn `anime` hay
`manga`, LLM vẫn có xu hướng viết y như ví dụ này. Kết quả: style user chọn hiện
gần như không có tác dụng lên chữ mà LLM viết ra.

**Sửa — image-ai (1 dòng, không sửa code):**
```
IMAGE_AI_COMIC_STYLE_ENABLED=true
```
(hiện đang `false`). Logic tra `STYLE_PRESETS` theo style đã đúng sẵn, chỉ cần bật
cờ để nó chạy.

**Sửa — story-ai (Nhân), file `src/llm/prompt_template.py`:**

1. Bỏ đuôi style khỏi câu ví dụ dòng 46 — từ:
   ```
   "young Vietnamese woman in traditional clothing, walking along dirt path, thatched-roof house, golden hour, melancholic mood, wide shot, comic book style, vibrant colors, detailed line art"
   ```
   cắt còn:
   ```
   "young Vietnamese woman in traditional clothing, walking along dirt path, thatched-roof house, golden hour, melancholic mood, wide shot"
   ```

2. Thêm rule mới vào `IMAGE PROMPT RULES` (cùng chỗ chèn 2 rule ở Phần A):
   ```python
   - Do NOT include art style descriptors (e.g. "comic book style", "anime style",
     "watercolor", "vibrant colors") in the image_prompt. Focus purely on scene
     content — style is applied separately by the rendering system based on the
     selected ART STYLE.
   ```

**Verify:** sinh 2 truyện cùng nội dung, style khác nhau (`anime` vs `manga`), so
`image_prompt` trả về — không còn thấy chữ style trong đó — rồi so ảnh ra có đúng
đặc trưng phong cách đã chọn không (anime: nét mảnh, màu tươi; manga: đen trắng,
screen tone).

---

## Thứ tự làm gợi ý

1. Phần B trước (nhanh, 2 dòng, tự test bằng Swagger được ngay, không phụ thuộc ai).
2. Phần A + Phần C nhắn Nhân làm song song (cùng 1 file `prompt_template.py`, làm
   1 lần).
3. Đổi `.env` image-ai (Phần C, 1 dòng).
4. Xong cả 3 mới nên chạy test SDXL-Turbo (Tầng 1, xem
   `PLAN_IMAGE_GENERATION_UPGRADE.md`) — để thấy đúng hiệu quả cộng dồn của các lớp
   sửa, không lẫn lộn biến số.
