# Phân tích luồng "chèn thoại" hiện tại & hướng tích hợp bong bóng thoại tối ưu

Ngày: 2026-07-13

Rà soát toàn bộ luồng dữ liệu `story-ai → orchestrator-ai → be-comic → fe-comic`
để trả lời câu hỏi: `image-ai` hiện chỉ vẽ ảnh từ `image_prompt`, vậy lời thoại
tiếng Việt được xử lý ở đâu, dưới hình thức nào, và vì sao chưa "hợp lý"? Từ đó
đề xuất hướng tích hợp tối ưu nhất dựa trên hạ tầng đã có sẵn trong repo.

---

## 1. Luồng dữ liệu thực tế hiện nay

```
story-ai (LLM)            → sinh panel_type, speaker, dialogue, image_prompt
                             (prompt_template.py, parser.py)
        ↓
orchestrator-ai            → CHỈ giữ lại caption_vi + prompt_en, DROP speaker
   comic_job.py:24-29         và panel_type (PanelScriptData không có 2 field này)
        ↓
image-ai (Celery task)     → generate_image_task() vẽ ảnh từ prompt xong GỌI LUÔN
   tasks.py:164-168            add_caption_to_comic(image, caption_vi)
                                → burn cứng 1 hộp caption trắng ở ĐÁY ảnh
                                  (image_processing.py:79-165), KHÔNG phải bong
                                  bóng thoại thật: không tail, không phân biệt ai
                                  nói, không phân biệt narration/dialogue/shout
        ↓
be-comic FramesService     → lưu image_url (đã có chữ cháy sẵn trong ảnh),
   frames.service.ts:23-39    caption_vi, image_prompt, seed vào bảng COMIC_FRAME
        ↓
GET /frames?projectId=     → trả Frame[] kèm relation speech_bubbles
   frames.controller.ts:11    (nhưng bảng này luôn RỖNG — xem mục 2)
```

### Điểm mấu chốt: hạ tầng bong bóng thoại đã có sẵn nhưng chưa nối dây

- Bảng `COMIC_SPEECH_BUBBLE` (`speech-bubble.entity.ts`) đã được thiết kế đầy đủ:
  `frame_id`, `text_content`, `bubble_type` (SPEECH/THOUGHT/NARRATION/SHOUT),
  `pos_x`, `pos_y`, `width`, `height`, `tail_direction`, `style_config` (jsonb).
- Nhưng `SpeechBubblesService`/`SpeechBubblesController`
  (`speech-bubbles.service.ts:6-25`) chỉ là code stub do NestJS CLI sinh ra
  (`create()` trả string `'This action adds a new speechBubble'`...), **không
  hề được gọi ở đâu trong `saveFromPanels`**. Bảng rỗng vĩnh viễn.
- Phía `fe-comic`, `WorkspaceComic` + `ComicEditorService`
  (`workspace-comic.ts`, `comic-editor.service.ts`) đã xây **hoàn chỉnh** một
  editor bong bóng thoại dạng SVG: kéo/thả, resize, tail, 3 kiểu bubble
  (round/square/cloud), export canvas 2x (`exportComicAsImage`). Nhưng:
  - `bubbles: []` luôn khởi tạo rỗng, không đọc dữ liệu từ BE.
  - Ảnh panel hiện đang là placeholder giả
    `'https://picsum.photos/seed/comic_panel_' + idx + '/600/400'`
    (`workspace-comic.html:59`) — **FE còn chưa gọi `GET /frames` để lấy
    `image_url` thật**, chứ đừng nói tới bubble.
- `GET /generation-jobs/:id` (qua `liveStatus.panels[]`, xem
  `generation-jobs.service.ts` + proto `PanelResult`) chỉ trả `index`,
  `captionVi`, `imageUrl`, `promptEn`, `seed`, `status`, `errorMessage` — không
  có `speaker`/`panel_type`/toạ độ bubble nào cả, đúng như hệ quả của việc bị
  drop dữ liệu ở orchestrator.

---

## 2. Vì sao cách hiện tại (burn caption vào ảnh) là hướng sai

1. **Không sửa được nữa** sau khi ảnh đã render — muốn đổi vị trí/nội dung câu
   thoại phải chạy lại toàn bộ pipeline GPU (tốn tiền, tốn thời gian).
2. **Luôn chỉ 1 caption ở đáy ảnh** — không phân biệt ai nói, không hỗ trợ
   nhiều bong bóng/panel, mất hẳn `speaker` và `panel_type` mà story-ai đã sinh
   ra rất công phu (xem rule trong `prompt_template.py`).
3. **Đá nhau trực tiếp với editor SVG đã xây ở FE** — editor đó cần ảnh "sạch"
   (không chữ) để vẽ đè bong bóng vector lên, nhưng ảnh nhận về từ image-ai đã
   có chữ cháy cứng vào pixel.

---

## 3. Hướng tối ưu đề xuất: structured data + client-side render

Ý tưởng cốt lõi: **tách nội dung thoại ra khỏi ảnh nền, giữ ảnh sạch**, để FE
(đã có sẵn cơ chế) vẽ bong bóng như một lớp vector đè lên ảnh — giống cách các
tool comic editor chuyên nghiệp (Webtoon, Canva...) làm. Không cố gắng để AI tự
đoán toạ độ pixel chính xác của miệng nhân vật (gần như không khả thi với ảnh
Stable Diffusion không có bounding box nhân vật) — thay vào đó dùng vị trí mặc
định theo heuristic + để người dùng kéo chỉnh tay trong editor đã có sẵn.

### Bước 1 — Ngừng burn caption ở image-ai

| File | Sửa gì |
|---|---|
| `image-ai/src/worker/tasks.py:164-168` | Thêm flag `render_caption: bool` (mặc định `False`) vào request; chỉ gọi `add_caption_to_comic` khi flag bật |
| proto `image_generation.proto` + `GenerateImageRequest` | Thêm field `render_caption` |

Kết quả: ảnh trả về là panel sạch, không chữ cháy sẵn.

### Bước 2 — Không làm mất dữ liệu ở orchestrator

| File | Sửa gì |
|---|---|
| `orchestrator-ai/src/workflow/comic_job.py:24-29` (`PanelScriptData`) | Thêm field `speaker`, `panel_type` |
| `be-comic/src/proto/orchestrator.proto:41-49` (`PanelResult`) | Thêm field `speaker`, `panel_type` |
| `orchestrator-ai/src/clients/story_client.py` | Truyền `speaker`/`panel_type` từ response story-ai xuyên suốt tới `PanelResult` |

### Bước 3 — Implement thật `SpeechBubblesService`, nối vào `saveFromPanels`

| File | Sửa gì |
|---|---|
| `be-comic/src/module/frames/frames.service.ts:23-39` | Sau khi upsert `Frame`, tạo kèm 1 `SpeechBubble` dựa trên `speaker`/`panel_type`/`dialogue` |
| `be-comic/src/module/speech-bubbles/speech-bubbles.service.ts` | Implement `create()` thật (insert DB), thay code stub |

Quy tắc map dữ liệu:
- `bubble_type`: `panel_type = dialogue` → `SPEECH`; `narration` → `NARRATION`;
  `action` có chữ → `SHOUT`.
- `pos_x/pos_y/width/height/tail_direction`: heuristic đơn giản, không cần
  chính xác tuyệt đối — ví dụ narration → dải trên cùng full-width; dialogue →
  góc dưới trái/phải luân phiên theo thứ tự panel. Người dùng kéo chỉnh lại
  trong editor là hành vi tự nhiên, không phải bug.

### Bước 4 — FE: nối editor có sẵn vào dữ liệu thật

| File | Sửa gì |
|---|---|
| `fe-comic/.../workspace-comic/workspace-comic.html:59` | Thay `picsum.photos` bằng `frame.image_url` thật, lấy qua `GET /frames?projectId=` sau khi job `COMPLETED` |
| `fe-comic/.../comic-editor.service.ts` | Thêm hàm nạp bubble ban đầu: map `frame.speech_bubbles[]` (format BE) → `SpeechBubble[]` (format FE, đã tương thích ~90% field) rồi `updateState({ bubbles })` thay vì để rỗng |

Kết quả: người dùng mở editor ra đã có sẵn thoại + vị trí gợi ý, chỉ cần tinh
chỉnh — trải nghiệm tốt hơn hẳn so với phải tự thêm từng bubble từ đầu. Bước
export ảnh cuối (`exportComicAsImage` trong `workspace-comic.ts`) giữ nguyên
không đổi — đây chính là bước "burn" cuối cùng, nhưng làm ở client sau khi user
đã ưng ý, không phải làm cứng một chiều ở server.

### Bước 5 (tuỳ chọn, làm sau) — Lưu lại chỉnh sửa của user

| File | Sửa gì |
|---|---|
| `be-comic/src/module/speech-bubbles/speech-bubbles.service.ts` | Implement nốt `update()` |
| `be-comic/src/module/speech-bubbles/speech-bubbles.controller.ts` | Đảm bảo route `PATCH /speech-bubbles/:id` hoạt động, FE gọi khi user chỉnh xong |

Tránh mất chỉnh sửa của user khi F5/tải lại trang.

---

## 4. Vì sao hướng này tối ưu

- Tận dụng gần như 100% hạ tầng đã tồn tại (entity, migration, SVG editor) —
  việc chính là **nối dây**, không phải xây mới từ đầu.
- Thoại luôn sửa được, không tốn GPU render lại mỗi lần đổi chữ/vị trí.
- Giữ được đầy đủ ngữ nghĩa story-ai đã sinh (speaker, loại panel) thay vì đánh
  rơi giữa đường ở orchestrator như hiện tại.
- Tránh bài toán khó "AI tự đặt bong bóng đúng vị trí miệng nhân vật trong ảnh
  AI-generated" — gần như không giải được đáng tin cậy ở giai đoạn hiện tại;
  thay vào đó dùng heuristic + con người chỉnh tay, đúng với UX editor đã thiết
  kế sẵn ở FE.

## 5. Thứ tự triển khai đề xuất

1. Bước 4 trước (ít rủi ro nhất, hiển thị được ảnh thật ngay trên editor).
2. Bước 1 (ngừng burn caption) — cần làm trước hoặc song song bước 3 để ảnh sạch.
3. Bước 2 + 3 (giữ + lưu speaker/panel_type/bubble) — cần sửa cả 3 service
   (story/orchestrator/be-comic), rủi ro cao nhất, nên làm sau khi đã xác nhận
   FE hiển thị đúng ảnh thật.
4. Bước 5 (lưu chỉnh sửa) — làm sau cùng, không chặn luồng chính.
