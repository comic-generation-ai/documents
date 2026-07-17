# Fix: image_prompt không mô tả đúng cảnh / mất nhân vật trong khung ảnh (image-ai)

Ngày: 2026-07-16

## Vấn đề gốc

Người dùng phản ánh: prompt sinh ảnh hiện tại không diễn tả được hình ảnh
mong muốn, và các nhân vật cần xuất hiện trong khung đôi khi bị thiếu.

Story-ai đã được siết giới hạn `image_prompt` (40-60 từ, nhân vật đặt đầu
chuỗi, góc máy/ánh sáng đặt cuối). Nhưng đó chỉ là giảm rủi ro ở nguồn —
gốc rễ thật sự nằm ở cách `image-ai` ghép và cắt prompt, nên phải sửa ở đây.

### Vì sao giới hạn ở story-ai không đủ, vẫn phải cắt/sửa ở image-ai

1. **Giới hạn ở story-ai chỉ là lời dặn trong system prompt cho LLM, không
   có gì ép buộc số ký tự thực tế LLM trả về.** Không có validator nào chặn
   độ dài `image_prompt` ở story-ai (khác với `dialogue` — có
   `MAX_DIALOGUE_CHARS` cắt cứng trong `story-ai/src/llm/parser.py`).
2. **`image_prompt` từ story-ai chưa phải là prompt cuối cùng đưa vào model
   sinh ảnh.** `image-ai/src/core/pipeline_runner.py::_build_prompt` còn nối
   thêm **style suffix** (~100-130 ký tự tùy style) vào sau, rồi mới đưa vào
   CLIP text encoder (giới hạn cứng ~77 token). Dù story-ai gửi đúng như
   dặn, tổng `image_prompt + style_suffix` vẫn có thể vượt ngưỡng CLIP.
3. **`image-ai` là service dùng chung**, `ImageRequest.prompt` nhận chuỗi
   thô từ bất kỳ caller nào, không riêng story-ai — không thể tin tưởng mù
   quáng rằng caller nào cũng gửi prompt đúng chuẩn độ dài.

→ Do đó cần một lớp cắt cứng ở đúng nơi ghép chuỗi thật sự gửi vào model
(image-ai) như một lưới an toàn (defense in depth). Vấn đề không phải ở
việc "có lớp cắt" — mà lớp cắt hiện tại **cắt mù từ cuối chuỗi**, không
phân biệt đang cắt vào style suffix (không sao) hay cắt vào mô tả nhân vật
(mất nhân vật khỏi ảnh).

### Cơ chế gây mất nhân vật (đã xác nhận trong code)

1. `image-ai/src/core/pipeline_runner.py::_build_prompt` nhận `image_prompt`
   từ story-ai, nối thêm **style suffix** (xem `STYLE_PRESETS` và
   `COMIC_STYLE_PROMPT_SUFFIX` trong `image-ai/src/config/settings.py`),
   rồi cắt cứng toàn bộ chuỗi ở `MAX_PROMPT_CHARS = 380` ký tự
   (`settings.py:142`).
2. Khi `clean_prompt` (đến từ story-ai) tự nó đã dài hơn ngân sách còn lại
   sau khi trừ style suffix, code cắt bằng:
   ```python
   trimmed_prompt = clean_prompt[:prompt_budget].rsplit(",", 1)[0].strip()
   ```
   tức cắt từ **cuối chuỗi mô tả cảnh**. Vì format 2 nhân vật thường đặt
   nhân vật bên phải và phần góc máy/ánh sáng ở cuối câu, đây chính là phần
   bị cắt mất đầu tiên — nhân vật thứ 2 hoặc thông tin ánh sáng/góc máy biến
   mất khỏi ảnh dù story-ai đã mô tả đúng trong `image_prompt` gửi đi.
3. `_truncate_for_clip` (lớp cắt cuối cùng, áp cho toàn bộ chuỗi đã ghép) áp
   dụng cùng kiểu cắt mù này một lần nữa, phòng trường hợp style suffix +
   scene vẫn vượt `MAX_PROMPT_CHARS` dù đã trừ ngân sách ở bước trên.

## Hướng sửa (image-ai) — CHƯA LÀM

1. **Đổi thứ tự ưu tiên khi cắt trong `_build_prompt`**: hiện code đã ưu
   tiên giữ `style_suffix` và cắt bớt `clean_prompt` (dòng ~250-262) — đúng
   hướng. Nhưng khi `clean_prompt` tự nó đã dài hơn `prompt_budget`, việc
   cắt `clean_prompt[:prompt_budget]` vẫn cắt từ cuối của chính
   `clean_prompt` — tức cắt vào nhân vật bên phải/thông tin cuối câu. Cần
   cân nhắc:
   - Hạ `COMIC_STYLE_PROMPT_SUFFIX` / các suffix trong `STYLE_PRESETS`
     xuống ngắn hơn nữa để nhường thêm ngân sách cho mô tả cảnh, HOẶC
   - Tăng `MAX_PROMPT_CHARS` (hiện 380) nếu Compel-chunking (đã có sẵn qua
     `_encode_with_compel`) thực sự hỗ trợ prompt dài hơn 1 chunk CLIP —
     hiện tại `_build_prompt` cắt về 380 ký tự **trước khi** vào
     `_encode_with_compel`, nên lợi ích chunk nhiều đoạn của Compel gần như
     bị vô hiệu hóa. Cần xác nhận lại việc này có chủ đích (giữ 1 chunk cho
     ổn định) hay là do quên nới giới hạn sau khi thêm Compel.
2. **Cắt theo cụm nhân vật thay vì cắt mù theo ký tự**: nếu `clean_prompt`
   vượt `prompt_budget`, tách chuỗi theo dấu `;` (ranh giới giữa các nhân
   vật trong format "on the left, ...; on the right, ...") và bỏ bớt từ cụm
   cuối cùng nguyên vẹn, thay vì cắt giữa chừng một mô tả nhân vật bằng
   `rsplit(",", 1)`.
3. **Log cảnh báo rõ hơn khi cắt xảy ra ở mô tả cảnh** (không chỉ log số ký
   tự cắt như hiện tại) — nên log kèm phần bị cắt để dễ debug khi người dùng
   báo thiếu nhân vật.

## File liên quan

| File | Vai trò |
|---|---|
| `image-ai/src/core/pipeline_runner.py` | Chưa sửa — nơi ghép style suffix + cắt cứng 380 ký tự (`_build_prompt`, `_truncate_for_clip`) |
| `image-ai/src/config/settings.py` | `MAX_PROMPT_CHARS`, `COMIC_STYLE_PROMPT_SUFFIX`, `STYLE_PRESETS` |
| `story-ai/src/llm/prompt_template.py` | Đã sửa trước đó (giảm rủi ro ở nguồn) — không thuộc phạm vi việc cần làm còn lại trong file này |
