# Fix lỗi dữ liệu kết nối story-ai ↔ orchestrator-ai

Ngày: 2026-07-07

Sửa 4 lỗi dữ liệu phát hiện khi rà soát luồng JSON `image_prompt` từ story-ai
qua orchestrator-ai đến image-ai.

---

## Lỗi 1 — Lệch timeout: orchestrator ReadTimeout trong khi story-ai vẫn đang retry

**Vấn đề:** `StoryClient` phía orchestrator đặt timeout 90s, nhưng vòng retry của
story-ai (3 lần gọi LLM, mỗi lần chờ rate-limit mặc định 30s+, có thể đổi model
fallback) tổng cộng có thể kéo dài vài phút. Orchestrator timeout và fail job
trong khi story-ai vẫn xử lý.

**Thay đổi:**

| File | Sửa gì |
|---|---|
| `orchestrator-ai/src/config/settings.py` | `STORY_AI_TIMEOUT_SEC` mặc định `90.0` → `240.0` |
| `story-ai/src/server.py` | Thời gian chờ retry rate-limit: mặc định `30s` → `15s`, và chặn trần `wait = min(wait, 20)` để tổng thời gian 3 attempts luôn nằm dưới timeout của orchestrator |

---

## Lỗi 2 — `panel_number` từ LLM không được kiểm tra → IndexError / ghi đè panel

**Vấn đề:** LLM có thể trả `panel_number` nhảy số (1, 2, 4) hoặc trùng lặp.
Orchestrator dùng `panel_number - 1` làm index truy cập `state.panels[...]`
(`comic_job.py`) → nhảy số gây `IndexError`, trùng số gây ghi đè panel.

**Thay đổi (vá cả 2 phía — defense in depth):**

| File | Sửa gì |
|---|---|
| `story-ai/src/llm/parser.py` | Sau khi validate bằng pydantic: sort panels theo `panel_number` rồi **gán lại thành dãy liên tục 1..N** trước khi trả về |
| `orchestrator-ai/src/clients/story_client.py` | Sau khi sort panels: **gán lại `panel.index = vị trí thực tế trong list`** (enumerate) — chống lỗi kể cả khi gọi tới bản story-ai cũ chưa vá |

**Đã test:** input `panel_number = [4, 1, 2, 2]` → output `[1, 2, 3, 4]`,
thứ tự nội dung giữ nguyên theo sort.

---

## Lỗi 3 — Fallback mock che giấu lỗi: orchestrator không phân biệt truyện thật / truyện giả

**Vấn đề:** Story-ai không bao giờ trả HTTP error — mọi lỗi (hết API key, hết
quota, parse hỏng) đều trả 200 kèm panels mock generic. Orchestrator chạy tiếp,
đốt GPU sinh ảnh từ prompt mock vô nghĩa.

**Thay đổi:**

| File | Sửa gì |
|---|---|
| `story-ai/src/server.py` | Thêm trường `is_fallback: bool = False` vào `GenerateStoryResponse`; `_get_mock_fallback` đặt `is_fallback=True` |
| `orchestrator-ai/src/config/settings.py` | Thêm setting `STORY_ALLOW_FALLBACK` (mặc định `False`) + property `story_allow_fallback` |
| `orchestrator-ai/src/clients/story_client.py` | Thêm `is_fallback` vào `StoryResult`; đọc cờ từ response: nếu `is_fallback=True` và `STORY_ALLOW_FALLBACK=false` → raise `RuntimeError` (job FAILED sớm, không sinh ảnh); nếu `=true` → log warning và chạy tiếp |

**Cấu hình mới (`.env` của orchestrator-ai):**

```env
# Cho phép chấp nhận truyện mock khi dev không có API key LLM
ORCHESTRATOR_STORY_ALLOW_FALLBACK=true
```

Mặc định (không đặt biến) là **chặn** fallback — job fail ngay với thông báo rõ ràng.

---

## Lỗi 4 — Dialogue fallback có thể vượt giới hạn caption 500 ký tự của image-ai

**Vấn đề:** `_get_mock_fallback` sinh `dialogue = "[Khung i] {toàn bộ summary}"`.
Summary dài hơn ~490 ký tự làm `caption_text` vượt `CAPTION_MAX_LENGTH=500`
→ image-ai trả `INVALID_ARGUMENT` → job fail.

**Thay đổi:**

| File | Sửa gì |
|---|---|
| `story-ai/src/server.py` | Cắt summary trong dialogue fallback về tối đa 150 ký tự (thêm `...` nếu bị cắt) |

**Đã test:** summary 600 ký tự → dialogue mỗi panel 163 ký tự (< 500).

---

## Tổng hợp file đã thay đổi

| # | File | Lỗi liên quan |
|---|---|---|
| 1 | `story-ai/src/server.py` | 1, 3, 4 |
| 2 | `story-ai/src/llm/parser.py` | 2 |
| 3 | `orchestrator-ai/src/config/settings.py` | 1, 3 |
| 4 | `orchestrator-ai/src/clients/story_client.py` | 2, 3 |

## Kiểm tra đã chạy

- ✅ `ast.parse` (syntax) pass cả 4 file sửa.
- ✅ Test parser: chuẩn hóa `panel_number` `[4,1,2,2]` → `[1,2,3,4]`.
- ✅ Test fallback: `is_fallback=True`, dialogue ≤ 500 ký tự với summary 600 ký tự.
- ⚠️ Settings mới của orchestrator chỉ kiểm tra cú pháp (máy local không có venv
  của orchestrator-ai) — cần chạy `python src/server.py` của orchestrator để xác
  nhận load settings khi deploy.

## Lưu ý tương thích

- Trường `is_fallback` là **optional, mặc định `False`** ở cả hai phía → bản
  story-ai cũ + orchestrator mới (và ngược lại) vẫn chạy được, chỉ mất tính năng
  chặn fallback.
- Hành vi mặc định thay đổi: job giờ sẽ **FAILED sớm** khi story-ai fallback.
  Môi trường dev không có API key cần đặt `ORCHESTRATOR_STORY_ALLOW_FALLBACK=true`.
