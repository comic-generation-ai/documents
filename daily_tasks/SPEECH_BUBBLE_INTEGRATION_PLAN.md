# Hướng thực hiện: đặt bong bóng thoại lên ảnh

Ngày: 2026-07-16

Mục tiêu: mỗi panel tự động có sẵn bong bóng thoại/caption đặt đúng chỗ khi
job generate xong, không burn cứng vào ảnh — user chỉ cần kéo chỉnh lại nếu
muốn, không phải tự thêm từ đầu.

**Đã hoàn thành (2026-07-16): `story-ai` giờ bắt buộc mọi panel phải có
`dialogue`.** Không còn panel nào trả về `dialogue`/`speaker` rỗng — nếu
panel không có nhân vật nào nói (action/establishing shot), `story-ai` tự
viết 1 câu dẫn truyện ngắn và gán `speaker = "Người kể chuyện"` thay vì để
trống. Có 2 lớp:

- **Lớp chính (prompt):** `story-ai/src/llm/prompt_template.py` — thêm rule
  "MANDATORY — EVERY PANEL NEEDS TEXT, NO EXCEPTIONS" bắt LLM luôn điền
  `speaker`+`dialogue`, panel action không có lời thoại tự nhiên thì viết
  caption dẫn truyện thay vì bỏ trống.
- **Lớp phòng vệ (validator):** `story-ai/src/llm/parser.py` —
  `PanelScriptModel._ensure_dialogue_present` (`model_validator` sau khi
  parse): nếu LLM vẫn lỡ trả `dialogue` rỗng, tự vá `panel_type="narration"`,
  `speaker="Người kể chuyện"`, `dialogue="Câu chuyện tiếp diễn..."`; nếu có
  `dialogue` nhưng thiếu `speaker`, tự gán `speaker="Người kể chuyện"`. Đã
  test bằng tay: panel thiếu cả 2 field được vá đúng, panel có `dialogue`
  nhưng thiếu `speaker` cũng được vá đúng.

Vì vậy, **kể từ `story-ai`, mọi panel luôn có ít nhất 1 trong 2**: thoại
nhân vật thật, hoặc caption người dẫn truyện — không panel nào hiển thị mà
không có bong bóng/caption nào cả.

---

## 1. Phân loại bong bóng cho mỗi panel

Áp dụng theo đúng thứ tự ưu tiên sau, dựa trên `dialogue`/`caption_vi`,
`speaker`, `panel_type` mà `story-ai` đã sinh:

1. `dialogue` rỗng/`null` → **không tạo bong bóng** cho panel đó. Từ khi
   `story-ai` bắt buộc mọi panel có `dialogue` (xem trên), nhánh này **chỉ
   còn là lưới an toàn** cho dữ liệu cũ sinh ra trước khi có ràng buộc này,
   hoặc khi caller khác gọi thẳng `story-ai` bỏ qua field — không phải
   luồng bình thường nữa.
2. Có chữ, và (`panel_type == "narration"` **HOẶC** `speaker` rỗng/`null`
   **HOẶC** `speaker == "Người kể chuyện"`) → **caption người dẫn truyện**
   (`bubble_type = NARRATION`), bất kể `panel_type` ghi gì khác (phòng khi
   LLM gắn nhãn panel sai). Đây là nhánh mà panel action-không-thoại rơi
   vào sau khi được `story-ai` tự vá.
3. Còn lại (có chữ + tên nhân vật thật) → **bong bóng thoại nhân vật**
   (`bubble_type = SPEECH`, hoặc `SHOUT` nếu `panel_type == "action"`).

## 2. Vị trí đặt theo từng loại

| Phân loại | `speaker_position` | `bubble_type` | `pos_x` | `pos_y` | `width` | `height` | `tail_direction` |
|---|---|---|---|---|---|---|---|
| Người dẫn truyện | không dùng | `NARRATION` | 50 | 88 (đáy khung) | 240 | 60 | `none` |
| Thoại nhân vật | `left` | `SPEECH` | 30 | 18 | 170 | 95 | `down-left` |
| Thoại nhân vật | `right` | `SPEECH` | 70 | 18 | 170 | 95 | `down-right` |
| Thoại nhân vật | `center` | `SPEECH` | 30/70 luân phiên theo `panel_number` chẵn/lẻ | 18 | 170 | 95 | khớp `pos_x` |
| Thoại nhân vật, `panel_type=action` | bất kỳ | `SHOUT` | như dòng trên | 15 | 190 | 100 | khớp `pos_x` |
| Thoại nhân vật, thiếu `speaker_position` (dữ liệu cũ) | — | `SPEECH` | luân phiên theo `panel_number` | 20 | 160 | 100 | `down` |

`pos_x/pos_y` theo % kích thước panel. `tail_direction` là chuỗi mô tả
(`down`, `down-left`, `down-right`, `none`), FE tự quy đổi ra vector px lúc
render (xem Bước E).

`speaker_position` (`left|center|right`) là field mới, story-ai phải sinh
thêm — xem Bước A. Không cần AI đoán toạ độ pixel: chỉ cần biết nhân vật
đang nói đứng bên nào của khung để đặt bong bóng cùng phía, lệch lên trên.

---

## 3. Các bước sửa code

### Bước A — `story-ai`: sinh thêm field `speaker_position`

Phần bắt buộc `dialogue`/`speaker` không rỗng **đã xong** (xem mục "Đã hoàn
thành" ở đầu file). Còn lại trong Bước A chỉ là thêm `speaker_position`:

| File | Sửa gì |
|---|---|
| `story-ai/src/llm/prompt_template.py:6-18` (JSON schema) | Thêm `"speaker_position": "left \| center \| right"` vào schema mỗi panel — giá trị phải khớp vị trí đã mô tả trong `image_prompt` (rule SPATIAL POSITION, dòng 63-68) |
| `story-ai/src/server.py:67-72` (`PanelScript`) | Thêm `speaker_position: Optional[Literal["left","center","right"]] = "center"` |
| `story-ai/src/server.py:97-122` (`_get_mock_fallback`) | Thêm `speaker_position="center"` vào từng `PanelScript(...)` mock |
| `story-ai/src/llm/parser.py:16-21` (`PanelScriptModel`) | Thêm cùng field `speaker_position: Optional[Literal["left","center","right"]] = "center"` (model validate response LLM thật) — đặt trước `_ensure_dialogue_present` không ảnh hưởng gì vì 2 validator độc lập field |
| `story-ai/src/llm/parser.py` (thêm `field_validator` mới cho `speaker_position`) | **Bắt buộc, không được bỏ qua**: `Literal["left","center","right"]` chỉ chấp nhận đúng 3 giá trị này — nếu LLM lỡ trả `"top"`, `"middle"`, `""`, hoặc bất kỳ chuỗi nào khác, Pydantic sẽ raise `ValidationError` ngay (default `"center"` **không** cứu được trường hợp field có mặt nhưng sai giá trị, chỉ áp dụng khi field vắng mặt hoàn toàn) → làm hỏng toàn bộ response chỉ vì 1 field phụ. Phải thêm `@field_validator('speaker_position', mode='before')` để chuẩn hoá **trước khi** Pydantic validate kiểu `Literal`:<br>`python`<br>`@field_validator('speaker_position', mode='before')`<br>`@classmethod`<br>`def _normalize_position(cls, v):`<br>`    if isinstance(v, str) and v.strip().lower() in ("left", "right", "center"):`<br>`        return v.strip().lower()`<br>`    return "center"`<br>Cùng pattern phòng vệ như `_ensure_dialogue_present` đã làm với `dialogue` — không để 1 field LLM trả sai làm fail cả job |

### Bước B — `orchestrator-ai`: giữ `speaker`/`panel_type`, thêm `speaker_position`

| File | Sửa gì |
|---|---|
| `orchestrator-ai/src/clients/story_client.py:11-17` (`StoryPanelResult`) | Thêm `panel_type: str = "dialogue"`, `speaker_position: str = "center"` |
| `orchestrator-ai/src/clients/story_client.py:73-81` | Thêm `panel_type=raw_panel.get("panel_type") or "dialogue"`, `speaker_position=raw_panel.get("speaker_position") or "center"` |
| `orchestrator-ai/src/workflow/comic_job.py:24-28` (`PanelScriptData`) | Thêm `speaker: str = ""`, `panel_type: str = "dialogue"`, `speaker_position: str = "center"` |
| `orchestrator-ai/src/workflow/comic_job.py:214-222` | Truyền thêm `speaker=p.speaker, panel_type=p.panel_type, speaker_position=p.speaker_position` vào `PanelScriptData(...)` |
| `orchestrator-ai/src/workflow/comic_job.py:113-122` (`_empty_panel_dict`) | Thêm 3 field trên vào dict trả về |
| `orchestrator-ai/src/workflow/comic_job.py:99-109` (build `orchestrator_pb2.PanelResult(...)`) | Thêm `speaker=panel.get("speaker", ""), panel_type=panel.get("panel_type", ""), speaker_position=panel.get("speaker_position", "center")` |

### Bước C — proto: mở rộng `PanelResult` (field 8-10)

| File | Sửa gì |
|---|---|
| `orchestrator-ai/proto/orchestrator.proto:41-49` | Thêm `string speaker = 8; string panel_type = 9; string speaker_position = 10;` vào `message PanelResult` |
| `be-comic/src/proto/orchestrator.proto:41-49` | Y hệt (đồng bộ tay 2 file, xem `documents/scripts/check-contracts-sync.sh`) |
| `documents/contracts/orchestrator.proto` | Đồng bộ luôn |
| Cả 2 phía | Chạy lại `generate_proto.sh` tương ứng |

### Bước D — `be-comic`: implement thật `SpeechBubblesService`, tự tạo bubble khi lưu frame

| File | Sửa gì |
|---|---|
| `be-comic/src/module/generation-jobs/dto/panel.dto.ts` | Thêm `speaker?: string; panelType?: string; speakerPosition?: string;` |
| `be-comic/src/module/frames/frames.service.ts:34-50` (`saveFromPanels`) | **KHÔNG dùng `speechBubbleRepo.upsert(..., ['frame_id'])`** — xem cảnh báo bug ngay dưới bảng này. Sau khi `upsert` `Frame`: (1) lấy lại `frame` vừa upsert (`findOne({ where: { project_id: projectId, order_index: p.index ?? 0 } })`), (2) `speechBubbleRepo.delete({ frame_id: frame.id })` để dọn bong bóng auto-generate cũ (phòng khi job chạy lại/regenerate), (3) phân loại theo mục 1, (4) tính layout theo bảng mục 2 bằng 1 hàm thuần `computeBubbleLayout(classification, speakerPosition, panelNumber)`, (5) `speechBubbleRepo.save({ frame_id: frame.id, text_content: p.captionVi, ...layout })` (insert mới, không upsert) |
| `be-comic/src/module/speech-bubbles/speech-bubbles.service.ts` | Implement thật `create()`/`findAll()`/`findOne()`/`update()` bằng `Repository<SpeechBubble>` (`@InjectRepository`), xoá code stub NestJS CLI |

> ⚠️ **Bug nghiêm trọng nếu làm theo bản nháp trước của Bước D**: `COMIC_SPEECH_BUBBLE`
> chỉ có `PRIMARY KEY(id)` — **không có `UNIQUE`/index nào trên `frame_id`**
> (xác nhận trong migration `be-comic/src/db/migrations/1781493480257-InitialSchema.ts`,
> dòng `CREATE TABLE "COMIC_SPEECH_BUBBLE" (...)`, chỉ có
> `CONSTRAINT "PK_..." PRIMARY KEY ("id")`). Gọi
> `repo.upsert({...}, ['frame_id'])` khiến TypeORM sinh
> `ON CONFLICT ("frame_id") DO UPDATE...`, Postgres sẽ throw lỗi
> **`there is no unique or exclusion constraint matching the ON CONFLICT specification`**
> ngay khi `saveFromPanels` chạy → **crash toàn bộ bước lưu frame sau mỗi job**.
> Cách sửa đúng: dùng `delete` + `save` (insert mới) như bảng trên, **không**
> `upsert` theo `frame_id` trừ khi làm thêm 1 migration mới thêm
> `@Unique(['frame_id'])` vào `SpeechBubble` entity (không cần thiết — 1 frame
> vẫn có thể có nhiều bong bóng do user tự thêm tay ở FE, nên ràng buộc unique
> theo `frame_id` là sai bản chất dữ liệu).

### Bước E — `fe-comic`: nạp bubble từ BE vào editor

| File | Sửa gì |
|---|---|
| `fe-comic/src/app/core/api/frames-api.service.ts` (`FrameDto`, dòng 6-16) | Thêm field `speech_bubbles?: SpeechBubbleDto[];` vào interface (hiện interface này hoàn toàn chưa có field này — cần để TS compile được khi `hydrateBubblesFromFrames` đọc `frame.speech_bubbles`). Định nghĩa thêm `SpeechBubbleDto` khớp entity BE: `{ id: string; frame_id: string; text_content: string; bubble_type: 'SPEECH'\|'THOUGHT'\|'NARRATION'\|'SHOUT'; pos_x: number; pos_y: number; width: number; height: number; tail_direction: string \| null; style_config: Record<string, any>; }` |
| `fe-comic/.../comic-editor.service.ts` (`SpeechBubble` interface, dòng 4-20) | Thêm field tuỳ chọn `hasTail?: boolean` (mặc định `true`) — cần cho `NARRATION` (không đuôi) |
| `fe-comic/.../comic-editor.service.ts` | Thêm hàm `hydrateBubblesFromFrames(frames: FrameDto[])`: map `frame.speech_bubbles[]` (BE) → `SpeechBubble[]` (FE), 2 quy tắc: `bubble_type → type` (`SPEECH→'round'`, `THOUGHT→'cloud'`, `NARRATION→'square'`, `SHOUT→'square'`) và `tail_direction → tailX/tailY` bằng hàm quy đổi theo `width/height` bubble, ví dụ:<br>`down-left → {x:-0.25*w, y:0.6*h}`, `down-right → {x:0.25*w, y:0.6*h}`, `down → {x:0, y:0.65*h}`, `none → hasTail:false`.<br>Gán `panelIndex = frame.order_index`, gọi `updateState({ bubbles })` |
| `fe-comic/.../workspace-comic.ts` (`getTailPoints` dòng 251-269, `getTailStroke` dòng 271-289) | Trả `''` (không vẽ path đuôi) khi `b.hasTail === false` — nhưng **chỉ đủ cho `type='round'\|'square'`**, xem dòng dưới cho `type='cloud'` |
| `fe-comic/.../workspace-comic.html` (khối `<g class="cloud-tail">`, dòng 153-160) | Đuôi kiểu `cloud` KHÔNG đi qua `getTailPoints`/`getTailStroke` — nó là 3 `<circle>` vẽ trực tiếp từ `bubble.tailX/tailY`. Phải tự bọc thêm `@if (bubble.hasTail !== false)` quanh khối `<g class="cloud-tail">` này, nếu không bong bóng `NARRATION` dạng cloud vẫn hiện đuôi dù đã set `hasTail: false` |
| `fe-comic/.../workspace-comic.html` (khối `<g class="tail-handle-group">`, dòng 196-199) | Núm kéo đuôi trong `selection-handles` cũng cần bọc `@if (bubble.hasTail !== false)` — nếu không, chọn 1 bong bóng `NARRATION` (không đuôi) vẫn thấy 1 núm tròn lơ lửng ở giữa bubble (do `tailX/tailY = 0` mặc định) kéo được nhưng không có tác dụng gì, gây khó hiểu cho user |
| `fe-comic/.../workspace-comic.ts` (`exportComicAsImage`, khối vẽ đuôi dòng 411-430 và 486-515) | Thêm điều kiện `b.hasTail !== false` trước khi vẽ tam giác đuôi trên canvas export (áp dụng cho cả nhánh `cloud` — khối vẽ 3 vòng tròn đuôi mây dòng ~470-483 — không chỉ nhánh `round`/`square`) |
| `fe-comic/src/app/features/comic-editor/editor-comic/editor-comic.html` (khu vực hiện có `selectedBubble` controls, gần dòng 158-260) | *Đề xuất thêm, không bắt buộc để chạy được nhưng cần cho UX chỉnh sửa*: thêm 1 checkbox dùng đúng pattern `updateSelectedBubble({...})` đã có sẵn trong file này (vd dòng 227-236 dùng cho `textAlign`), để user tự bật/tắt đuôi cho bong bóng đang chọn — vì heuristic tự động có thể đặt sai loại (VD: muốn đổi 1 `SPEECH` do AI tạo thành caption không đuôi), mà hiện sidebar chỉ có nút đổi hình dạng (`round`/`square`/`cloud`) và sửa chữ, không có cách nào bật/tắt đuôi thủ công:<br>`<input type="checkbox" [ngModel]="selectedBubble?.hasTail !== false" (ngModelChange)="updateSelectedBubble({ hasTail: $event })" />` |
| `fe-comic/.../comic-editor-page.ts` — lưu `activeProjectId` | `generateComic()` (dòng 194-209): trong `switchMap((project) => ...)`, project object đã có sẵn `project.id` nhưng hiện không được lưu lại — thêm gán `this.activeProjectId = project.id;` (field mới của component) trước khi gọi `createComicJob` |
| `fe-comic/.../comic-editor-page.ts` — `handleJobStatus` (dòng 261-290) | Trong `switch (res.localJob.status)`, case `'COMPLETED'` (dòng 273): sau khi set `isGenerating = false`, gọi thêm `this.framesApi.getFramesByProject(this.activeProjectId).subscribe(frames => this.editorService.hydrateBubblesFromFrames(frames))` |
| `fe-comic/.../comic-editor-page.ts` — `loadExistingProject` (dòng 86-152) | `frames` đã được fetch sẵn ở dòng 92 (`forkJoin({ project, frames: this.framesApi.getFramesByProject(projectId) })`) nhưng hiện tại callback `next:` (dòng 110-143) chỉ map `frames` thành `panels[]` (ảnh/caption), **bỏ qua hoàn toàn `speech_bubbles`**. Ngay sau `this.editorService.reset()` (dòng 125), gọi thêm `this.editorService.hydrateBubblesFromFrames(frames)` — dùng lại đúng biến `frames` đã có trong closure, không cần gọi API lần 2. Đồng thời gán `this.activeProjectId = projectId;` ở đây luôn (để nhất quán, phòng khi user generate tiếp/regenerate sau khi mở lại project cũ) |

---

## 4. Thứ tự triển khai

1. **Bước A** (story-ai) — field optional, test độc lập bằng `story-ai/test_run.py`.
2. **Bước B + C** (orchestrator + proto) — làm cùng lúc vì cần generate lại code gRPC 2 phía; verify bằng `grpcurl` gọi `GetComicJobStatus` xem `speaker_position` có trả về không.
3. **Bước D** (be-comic) — verify bằng `GET /frames?projectId=` thấy `speech_bubbles[]` có dữ liệu sau khi 1 job chạy xong.
4. **Bước E** (fe-comic) — verify bằng mắt: mở trang truyện vừa generate, bong bóng tự nằm đúng phía nhân vật nói, caption người dẫn truyện nằm ở đáy khung.
