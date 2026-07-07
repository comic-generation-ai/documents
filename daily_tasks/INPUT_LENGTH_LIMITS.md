# Giới hạn độ dài input/output trong pipeline sinh truyện tranh

> Ngày: 2026-07-07
> Mục đích: chặn summary quá dài từ người dùng và ép lời thoại (dialogue) sinh ra gọn gàng,
> tránh panel bị image-ai reject do caption vượt giới hạn.

## Bối cảnh

Chuỗi dữ liệu: **FE → be-comic (REST) → orchestrator-ai (gRPC) → story-ai (LLM) → orchestrator-ai → image-ai (gRPC)**.

Trước thay đổi này:
- `summary` từ FE **không có giới hạn độ dài** (chỉ check không rỗng) → user có thể dán cả chương truyện vào prompt LLM.
- `dialogue` do LLM sinh ra **không bị ràng buộc độ dài**, trong khi image-ai **reject cứng**
  `caption_text > 500 ký tự` (`CAPTION_MAX_LENGTH`, xem `image-ai/src/service/image_service.py:68`)
  → thoại dài làm **fail cả panel** thay vì bị cắt gọn.

## Các thay đổi

### 1. be-comic — giới hạn input từ FE

**File:** `be-comic/src/module/generation-jobs/dto/create-generation-job.dto.ts`

| Field | Trước | Sau |
|---|---|---|
| `summary` | `@IsString @IsNotEmpty` | thêm **`@MaxLength(1000)`** |
| `style` | `@IsString @IsOptional` | thêm **`@MaxLength(100)`** |

Request vượt giới hạn sẽ bị NestJS `ValidationPipe` trả **400 Bad Request** trước khi chạm tới orchestrator.

### 2a. story-ai — chỉ dẫn LLM viết thoại ngắn (tầng prompt)

**File:** `story-ai/src/llm/prompt_template.py` (hàm `get_system_prompt`)

- Mô tả field `dialogue` trong JSON schema: thêm **"Maximum 120 characters."**
- RULES FOR NATURAL DIALOGUE: `maximum 2 short sentences` → **`maximum 2 short sentences and NEVER more than 120 characters`**.
- RULES FOR NARRATION CAPTIONS: thêm dòng **"Narrator captions must also stay under 120 characters."**

### 2b. story-ai — validator cắt mềm (tầng bảo hiểm)

**File:** `story-ai/src/llm/parser.py`

- Thêm hằng số **`MAX_DIALOGUE_CHARS = 150`**.
- Thêm `@field_validator("dialogue")` trong `PanelScriptModel`: nếu LLM trả thoại dài hơn 150 ký tự
  thì **cắt còn 149 + "…"** và ghi `logger.warning`, thay vì để nguyên (fail ở image-ai) hoặc raise lỗi (fail cả job).

LLM không tuân thủ ràng buộc độ dài 100%, nên tầng prompt (2a) chỉ là định hướng — tầng validator (2b) mới là chốt chặn.

## Chuỗi giới hạn sau thay đổi

| Điểm | Field | Giới hạn | Hành vi khi vượt |
|---|---|---|---|
| be-comic DTO | `summary` | 1000 ký tự | 400 Bad Request |
| be-comic DTO | `style` | 100 ký tự | 400 Bad Request |
| be-comic DTO | `numPanels` | 1–10 (đã có sẵn) | 400 Bad Request |
| story-ai prompt | `dialogue` | ~120 ký tự (chỉ dẫn LLM) | không cưỡng chế |
| story-ai parser | `dialogue` | 150 ký tự | cắt mềm + "…" + log warning |
| image-ai (đã có sẵn) | `caption_text` | 500 ký tự | reject `INVALID_ARGUMENT` — giờ không thể chạm tới vì đã chặn ở 150 |
| image-ai (đã có sẵn) | `prompt` | `MAX_PROMPT_CHARS=380` | image-ai tự cắt (`pipeline_runner.py`) — không cần xử lý thêm |

## Không thay đổi

- **Giới hạn tổng ký tự message JSON giữa các service**: không cần — các service giao tiếp bằng
  gRPC/protobuf (default max message 4MB), và mọi field tự do đã bị giới hạn tại nguồn.
- **orchestrator-ai**: giữ nguyên (chỉ check summary không rỗng) — be-comic là gRPC client duy nhất
  và đã validate ở DTO.

## Việc FE cần làm (khuyến nghị)

- Thêm `maxlength={1000}` + counter ký tự cho ô nhập summary để user không bị 400 bất ngờ.

## Đã kiểm tra

- Validator parser: dialogue 300 ký tự → cắt còn đúng 150 kết thúc bằng "…", có log warning;
  thoại ngắn và `null` giữ nguyên; đánh số panel vẫn chuẩn hóa 1..N như cũ.
