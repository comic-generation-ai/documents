# Triển khai chi tiết các thành phần của hệ thống ComicSystem

*(Bản viết theo văn phong khoa học, dựa trên khảo sát trực tiếp source code, dùng
để đưa vào chương Thiết kế/Triển khai hệ thống của luận văn — tiếp nối mục
"Thiết kế giao tiếp giữa các dịch vụ". Số thứ tự mục/tiểu mục cần điều chỉnh lại
cho khớp với đề mục chung của luận văn. Thời điểm khảo sát: 18/07/2026.)*

## 1. Đặt vấn đề

Nếu mục trước trình bày **giao diện** (interface) giữa các dịch vụ — giao thức,
đặc tả dữ liệu trao đổi, chiến lược timeout/retry — thì mục này trình bày
**cách hiện thực hoá** từng dịch vụ phía sau giao diện đó: kiến trúc nội bộ, mô
hình dữ liệu, thuật toán nghiệp vụ và các kỹ thuật tối ưu được áp dụng. Nội
dung được tổ chức theo từng dịch vụ, theo đúng thứ tự luồng xử lý một yêu cầu
sinh truyện tranh: `fe-comic` → `be-comic` → `orchestrator-ai` → `story-ai` /
`image-ai`.

## 2. Triển khai tầng giao diện người dùng (fe-comic)

### 2.1. Kiến trúc ứng dụng

`fe-comic` được xây dựng trên Angular theo mô hình **standalone component**
(không sử dụng `NgModule`), kết hợp cơ chế **phát hiện thay đổi không vùng**
(zoneless change detection). Ứng dụng đồng thời bật kết xuất phía máy chủ
(server-side rendering) với hydration sự kiện phía client. Định tuyến sử dụng
tải chậm (lazy-load) ở cấp độ từng thành phần trang (`loadComponent`) thay vì
theo module.

Việc lựa chọn mô hình zoneless kéo theo một hệ quả kỹ thuật xuyên suốt mã
nguồn: do không còn cơ chế `zone.js` tự động kích hoạt phát hiện thay đổi sau
mỗi tác vụ bất đồng bộ, mọi cập nhật trạng thái phát sinh ngoài sự kiện DOM
trực tiếp (kết quả trả về từ luồng RxJS, hàm `setTimeout`, callback của lời
gọi HTTP) đều phải được ứng dụng chủ động kích hoạt phát hiện thay đổi thông
qua `ChangeDetectorRef`. Đây là một mẫu hình lặp lại nhất quán trong toàn bộ
mã nguồn giao diện, ví dụ:

```ts
// fe-comic/src/app/features/comic-editor/editor-comic/editor-comic.ts:79-84
// Zoneless: callback bất đồng bộ không tự kích hoạt change detection,
// phải gọi thủ công để cập nhật giao diện.
this.cdr.markForCheck();
this.cdr.detectChanges();
```

### 2.2. Cấu trúc thư mục và phân lớp trách nhiệm

Mã nguồn được tổ chức thành ba lớp: `core` (dịch vụ nền tảng dùng chung toàn
ứng dụng — các lớp gọi API theo tài nguyên REST, cơ chế xác thực, guard định
tuyến, interceptor HTTP, quốc tế hoá), `features` (từng trang chức năng —
đăng nhập/đăng ký, biên tập truyện tranh, bảng phân cảnh, trang thông tin
người dùng, bố cục chung) và `shared/ui` (các thành phần trình bày thuần tuý
tái sử dụng nhiều nơi).

Về cơ chế xác thực, một interceptor HTTP duy nhất (`auth-interceptor.ts`) đọc
token từ bộ nhớ cục bộ của trình duyệt và đính kèm vào header
`Authorization` của mọi yêu cầu; một guard định tuyến dạng hàm
(`CanActivateFn`) kiểm tra trạng thái đăng nhập trước khi cho phép truy cập
các trang yêu cầu xác thực. Qua khảo sát, mã nguồn còn tồn tại một
interceptor ghi log (`logging-interceptor.ts`) đã được cài đặt đầy đủ nhưng
chưa được đăng ký vào cấu hình ứng dụng — cho thấy có sự chuẩn bị cho một
tính năng chưa được kích hoạt trong phiên bản hiện tại.

### 2.3. Trang biên tập truyện tranh — luồng xử lý chính

Trang biên tập truyện tranh (comic editor) là thành phần trung tâm của tầng
giao diện, đảm nhận hai kịch bản khởi tạo dữ liệu: (i) khởi tạo một tác vụ
sinh truyện mới, trong đó dự án và tác vụ sinh truyện được tạo tuần tự trước
khi vòng lặp truy vấn trạng thái (đã trình bày ở mục giao tiếp) được kích
hoạt; (ii) mở lại một dự án đã tồn tại thông qua tham số truy vấn, trong đó
dữ liệu dự án và danh sách khung hình được tải song song, sau đó URL hiển thị
ảnh của từng khung hình được truy vấn lại riêng lẻ để đảm bảo tính hợp lệ của
URL có chữ ký tạm thời (phù hợp với thiết kế MinIO đã trình bày ở mục giao
tiếp: đối tượng ảnh được tham chiếu bằng khoá lưu trữ bền vững, URL truy cập
chỉ được ký lại tại thời điểm hiển thị).

Kết quả truy vấn trạng thái tác vụ được ánh xạ từ hai hệ quy chiếu trạng thái
song song (trạng thái lưu tại Postgres và trạng thái tức thời từ
`orchestrator-ai`) sang một mô hình hiển thị thống nhất ở tầng giao diện;
khi tác vụ hoàn thành, giao diện tải lại toàn bộ khung hình và khởi tạo lại
các bong bóng thoại đã được tính toán sẵn ở tầng nghiệp vụ trung tâm.

### 2.4. Quản lý trạng thái biên tập và đồng bộ hoá với backend

Trạng thái biên tập (cấu hình khung, danh sách bong bóng thoại, phần tử đang
được chọn) được quản lý tập trung bởi một dịch vụ trạng thái sử dụng luồng
phản ứng (`BehaviorSubject`), không sử dụng thư viện quản lý trạng thái
chuyên dụng. Hai đặc điểm cài đặt đáng chú ý:

- **Cơ chế hoàn tác/làm lại (undo/redo)** được cài đặt thủ công bằng hai ngăn
  xếp lưu trữ ảnh chụp (snapshot) tuần tự hoá của toàn bộ trạng thái, giới
  hạn tối đa 50 bước; các thao tác kéo-thả liên tục được đánh dấu bỏ qua ghi
  lịch sử nhằm tránh việc mỗi điểm ảnh di chuyển đều sinh ra một bước lịch sử
  riêng biệt.
- **Đồng bộ hoá bong bóng thoại với backend** được thực hiện theo nguyên tắc
  đối chiếu tập hợp định danh: tập định danh đã tồn tại ở cơ sở dữ liệu (ghi
  nhận từ lần tải/lưu gần nhất) được so sánh với tập định danh hiện tại trong
  trạng thái biên tập để suy ra tập thao tác cần thực hiện (tạo mới, cập
  nhật, hoặc xoá), sau đó toàn bộ các thao tác này được gộp thành một lượt
  gọi song song duy nhất. Bong bóng mới được gán một định danh tạm thời phía
  client và được ánh xạ lại thành định danh thật sau khi backend xác nhận,
  đảm bảo các lượt lưu tiếp theo được nhận diện đúng là thao tác cập nhật.

```ts
// fe-comic/src/app/features/comic-editor/comic-editor.service.ts:231-283
// Đối chiếu persistedBubbleIds với id hiện tại để suy ra POST/PATCH/DELETE,
// gộp thành một forkJoin thay vì gọi tuần tự từng thao tác.
```

Ngoài ra, do mô hình dữ liệu phía backend chỉ lưu hướng chỉ dẫn (tail) của
bong bóng thoại dưới dạng một trong bốn giá trị rời rạc, trong khi thao tác
kéo tự do ở giao diện cho phép đặt điểm chỉ dẫn tại toạ độ bất kỳ, hệ thống
lưu thêm toạ độ chính xác vào một trường cấu hình mở rộng (kiểu JSON) và luôn
ưu tiên đọc lại từ trường này khi khôi phục — một giải pháp kỹ thuật nhằm
tránh hiện tượng bong bóng thoại thay đổi vị trí sau khi tải lại trang.

### 2.5. Vẽ và xuất ảnh

Bong bóng thoại được vẽ trên giao diện biên tập bằng SVG, kết hợp hai cơ chế
kéo-thả song song: một cơ chế tự cài đặt bằng sự kiện chuột của trình duyệt
(phục vụ di chuyển/thay đổi kích thước/điều chỉnh điểm chỉ dẫn) và bộ công cụ
kéo-thả của Angular CDK (phục vụ di chuyển toàn khối bong bóng).

Chức năng xuất ảnh trang truyện hoàn chỉnh được cài đặt độc lập bằng việc vẽ
lại toàn bộ nội dung trang (khung hình, viền, bong bóng thoại với nhiều kiểu
hình dạng, văn bản có ngắt dòng thủ công) lên phần tử `canvas` ở độ phân giải
gấp đôi bằng API Canvas 2D, sau đó xuất tệp ảnh PNG. Việc hình học của bong
bóng thoại (đường viền, hình mây, điểm chỉ dẫn) được cài đặt hai lần độc lập
— một lần bằng SVG cho hiển thị tương tác, một lần bằng Canvas cho xuất ảnh —
là một điểm trùng lặp logic được ghi nhận, có thể được hợp nhất trong các
phiên bản kế tiếp thông qua chuyển đổi SVG sang ảnh trực tiếp.

## 3. Triển khai dịch vụ nghiệp vụ trung tâm (be-comic)

### 3.1. Kiến trúc module và mô hình dữ liệu

`be-comic` được tổ chức theo kiến trúc module của NestJS, với chín module
nghiệp vụ (người dùng, dự án, kịch bản, giao dịch, nhân vật, khung hình, bong
bóng thoại, tác vụ sinh truyện, xác thực) được nạp phẳng vào module gốc của
ứng dụng. Tầng truy xuất dữ liệu sử dụng TypeORM trên Postgres, với việc đồng
bộ hoá lược đồ tự động được tắt và thay bằng cơ chế di trú (migration) chạy tự
động khi khởi động dịch vụ.

Các thực thể dữ liệu chính đều kế thừa một thực thể cơ sở chung mang các
trường thời điểm tạo/cập nhật/xoá mềm. Đáng chú ý:

- Thực thể **khung hình** (`Frame`) sử dụng chỉ mục duy nhất tổng hợp trên
  cặp (dự án, số thứ tự khung), đóng vai trò khoá tự nhiên cho thao tác
  upsert khi lưu kết quả sinh ảnh; trường lưu trữ ảnh chỉ giữ **khoá đối
  tượng** trong kho lưu trữ, không lưu URL đầy đủ, đúng với nguyên tắc thiết
  kế đã trình bày ở mục giao tiếp.
- Thực thể **nhân vật** (`Character`) có đầy đủ trường mô tả ngoại hình,
  trang phục và ảnh tham chiếu cùng bộ thao tác quản lý hoàn chỉnh, tuy nhiên
  chưa được tham chiếu từ luồng xử lý tạo tác vụ sinh truyện — cho thấy đây
  là một mô hình dữ liệu đã được chuẩn bị sẵn cho một tính năng nhất quán
  nhân vật theo hướng thủ công, chưa được kết nối vào nghiệp vụ chính tại
  thời điểm khảo sát.

### 3.2. Nghiệp vụ khởi tạo, truy vấn và huỷ tác vụ sinh truyện

Thao tác khởi tạo tác vụ được cài đặt theo hai giai đoạn tách biệt: giai đoạn
một, một giao dịch cơ sở dữ liệu ghi nhận bản ghi tác vụ với trạng thái khởi
tạo; giai đoạn hai, sau khi giao dịch được xác nhận (commit), lời gọi gRPC
khởi động tác vụ ở `orchestrator-ai` mới được thực hiện. Việc tách giai đoạn
này có hệ quả là khi lời gọi gRPC thất bại, bản ghi tác vụ tại Postgres vẫn
tồn tại (ở trạng thái thất bại) thay vì được hoàn tác cùng giao dịch ban đầu
— một lựa chọn thiết kế có chủ đích nhằm giữ lại lịch sử tác vụ ngay cả khi
không khởi động được, nhưng cũng đồng nghĩa với việc hai giai đoạn này không
có tính nguyên tử (atomicity) xuyên suốt.

Thao tác truy vấn trạng thái áp dụng nguyên tắc "chỉ gọi lại tầng dưới khi
cần thiết": nếu bản ghi cục bộ đã ở trạng thái kết thúc, kết quả được trả về
trực tiếp từ Postgres; ngược lại, dịch vụ gọi `orchestrator-ai` để lấy trạng
thái tức thời, và khi tác vụ vừa đạt trạng thái thành công, kích hoạt việc
lưu trữ toàn bộ khung hình và bố cục bong bóng thoại. Thao tác huỷ tác vụ
được bọc trong một giao dịch duy nhất cho cả lời gọi gRPC và cập nhật cơ sở
dữ liệu, đảm bảo tính nhất quán giữa hai lớp khi có lỗi phát sinh.

### 3.3. Thuật toán lưu trữ kết quả và bố cục bong bóng thoại tự động

Một trong những phần nghiệp vụ phức tạp nhất của `be-comic` là quá trình
chuyển đổi kết quả trả về từ `orchestrator-ai` (danh sách khung hình cùng lời
thoại thô) thành dữ liệu hiển thị có bố cục hoàn chỉnh, được thực hiện hoàn
toàn ở tầng ứng dụng mà không phụ thuộc dữ liệu bố cục từ các dịch vụ sinh
ảnh/sinh kịch bản. Quy trình gồm ba bước:

1. **Chuẩn hoá URL lưu trữ:** URL có chữ ký tạm thời nhận được qua gRPC được
   phân giải ngược thành khoá đối tượng gốc (loại bỏ tham số chữ ký và thời
   hạn) trước khi lưu vào cơ sở dữ liệu, đảm bảo dữ liệu lưu trữ không phụ
   thuộc vào một URL có thời hạn.
2. **Phân loại bong bóng thoại:** mỗi khung hình được phân loại thành một
   trong các dạng (không có bong bóng, lời dẫn chuyện, lời thoại thông
   thường, lời hét) dựa trên loại cảnh và người nói do `story-ai` đề xuất;
   trường hợp người nói rỗng hoặc được xác định là người kể chuyện được xếp
   vào dạng lời dẫn.
3. **Ước lượng kích thước và vị trí:** kích thước bong bóng được ước lượng
   bằng một công thức tuyến tính theo độ dài văn bản (số điểm ảnh trên mỗi ký
   tự, số điểm ảnh trên mỗi dòng, có giới hạn trên); vị trí (trái/phải/giữa)
   được xác định theo gợi ý vị trí người nói do `story-ai` trả về, và trong
   trường hợp không có gợi ý hợp lệ, hệ thống áp dụng quy tắc dự phòng là xen
   kẽ trái–phải theo số thứ tự khung hình.

```ts
// be-comic/src/module/frames/frames.service.ts:190-196
private toObjectKey(presignedUrl: string): string {
  try { return new URL(presignedUrl).pathname.slice(1); }
  catch { return presignedUrl; }
}
```

### 3.4. Cơ chế xác thực và kiểm tra dữ liệu đầu vào

Xác thực người dùng sử dụng JSON Web Token theo chiến lược Passport, với
việc xác minh lại sự tồn tại của người dùng trong cơ sở dữ liệu tại mỗi lần
giải mã token (nhằm vô hiệu hoá ngay các token của tài khoản đã bị xoá dù
token về mặt kỹ thuật chưa hết hạn). Mật khẩu được băm bằng bcrypt; token
truy cập và token làm mới sử dụng khoá bí mật và thời hạn hiệu lực khác nhau.
Toàn bộ dữ liệu đầu vào của API được kiểm tra thông qua đối tượng truyền dữ
liệu (DTO) kết hợp bộ trang trí kiểm tra ràng buộc, với cấu hình toàn cục loại
bỏ trường dữ liệu không khai báo và tự động chuyển đổi kiểu dữ liệu.

Qua khảo sát, một số cấu phần xử lý lỗi/ghi log tập trung (bộ lọc ngoại lệ
toàn cục, interceptor ghi log) đã được cài đặt sẵn trong mã nguồn nhưng chưa
được đăng ký kích hoạt trong cấu hình khởi động ứng dụng, tương tự trường hợp
đã ghi nhận ở tầng giao diện.

## 4. Triển khai dịch vụ điều phối (orchestrator-ai)

### 4.1. Mô hình xử lý đồng thời

`orchestrator-ai` cài đặt máy chủ gRPC hoàn toàn theo mô hình đồng bộ, xử lý
các yêu cầu đến trên một nhóm luồng cố định (thread pool), không sử dụng mô
hình bất đồng bộ (asyncio). Đối với mỗi tác vụ sinh truyện, một luồng thực
thi riêng biệt được khởi tạo để thực hiện toàn bộ chuỗi xử lý tuần tự (gọi
`story-ai`, sau đó lần lượt gọi `image-ai` cho từng khung hình), tách biệt
hoàn toàn với các luồng xử lý yêu cầu gRPC đến (truy vấn trạng thái, yêu cầu
huỷ). Sự tách biệt này đặt ra yêu cầu về một cơ chế đồng bộ hoá trạng thái
giữa hai nhóm luồng, được giải quyết bằng cách sử dụng Redis làm nguồn dữ
liệu duy nhất và đáng tin cậy (single source of truth): các handler xử lý yêu
cầu gRPC không lưu giữ trạng thái nội bộ mà luôn tải lại toàn bộ trạng thái
tác vụ từ Redis tại mỗi lần xử lý.

```python
# orchestrator-ai/src/service/orchestrator_service.py (minh hoạ)
def GetComicJobStatus(self, request, context):
    state = self._workflow.get(request.job_id)   # luôn tải mới từ Redis
    return state.to_status_response()
```

### 4.2. Luồng xử lý một tác vụ sinh truyện

Toàn bộ luồng xử lý được cài đặt trong một hàm duy nhất, thực thi tuần tự
theo các giai đoạn: chuyển trạng thái sang "đang sinh kịch bản", gọi
`story-ai`; nhận kết quả kịch bản và khởi tạo cấu trúc dữ liệu khung hình
tương ứng; lặp tuần tự qua từng khung hình, với mỗi khung hình chuyển trạng
thái, gọi `image-ai` để sinh ảnh (đã bao gồm việc truy vấn định kỳ chờ kết
quả ở tầng client), rồi cập nhật tiến độ. Khung hình đầu tiên trong chuỗi
được chọn làm ảnh tham chiếu cho các khung hình tiếp theo, phục vụ cơ chế
nhất quán nhân vật đã trình bày ở mục giao tiếp. Sau mỗi lần chuyển trạng
thái, toàn bộ trạng thái tác vụ được ghi đè xuống Redis ngay lập tức — tần
suất ghi Redis do đó tỉ lệ thuận với số lần chuyển trạng thái/số khung hình
của tác vụ.

Một đặc điểm cài đặt đáng chú ý về xử lý lỗi: khi một khung hình bất kỳ gặp
lỗi trong quá trình sinh ảnh, ngoại lệ được lan truyền ra khỏi vòng lặp và
toàn bộ tác vụ được chuyển sang trạng thái thất bại — nghĩa là hệ thống hiện
tại không có cơ chế "thử lại một khung hình" hay "chấp nhận tác vụ hoàn thành
một phần"; một lỗi cục bộ ở khung hình bất kỳ sẽ làm thất bại toàn bộ tác vụ,
kể cả khi các khung hình khác đã sinh thành công trước đó.

### 4.3. Cơ chế huỷ tác vụ và một hạn chế được phát hiện qua khảo sát

Thao tác huỷ tác vụ đọc trạng thái hiện tại từ Redis, đặt cờ yêu cầu huỷ và
chuyển trạng thái sang "đã huỷ", ghi lại Redis, sau đó gọi thao tác huỷ cho
từng tác vụ sinh ảnh con đã ghi nhận. Về phía luồng xử lý chính, mã nguồn có
ba điểm kiểm tra cờ yêu cầu huỷ để dừng sớm giữa các giai đoạn xử lý.

Tuy nhiên, qua khảo sát trực tiếp, cờ yêu cầu huỷ được luồng xử lý chính kiểm
tra là một biến cục bộ trong bộ nhớ, được tải từ Redis đúng một lần tại thời
điểm luồng bắt đầu thực thi; các thao tác cập nhật trạng thái tiếp theo trong
luồng chỉ ghi đè giá trị của biến cục bộ này xuống Redis, không đọc lại giá
trị mới từ Redis. Hệ quả là nếu yêu cầu huỷ được gửi đến sau khi luồng xử lý
đã bắt đầu thực thi (thời điểm thường gặp trong thực tế, vì huỷ tác vụ là
thao tác của người dùng thực hiện trong khi tác vụ đang chạy), cờ huỷ được
ghi vào Redis bởi thao tác huỷ sẽ không được luồng xử lý chính nhận biết, và
tác vụ sẽ tiếp tục thực thi cho đến khi hoàn tất hoặc gặp lỗi tự nhiên, thay
vì dừng sớm như được kỳ vọng theo thiết kế. Cơ chế huỷ vẫn có tác dụng một
phần: trạng thái hiển thị cho người dùng được chuyển ngay sang "đã huỷ" và
các tác vụ sinh ảnh con đã ghi nhận được yêu cầu huỷ ở phía `image-ai`; điều
chưa đạt được là việc dừng sớm vòng lặp xử lý phía `orchestrator-ai`. Đây là
một hạn chế cài đặt cụ thể, khác với một quyết định thiết kế có chủ đích, và
được đề xuất như một điểm cần khắc phục trong định hướng phát triển tiếp
theo — giải pháp khả dĩ là tải lại trạng thái từ Redis tại mỗi điểm kiểm tra
thay vì chỉ đọc biến cục bộ.

### 4.4. Cấu hình

Cấu hình dịch vụ được quản lý tập trung bằng một lớp thiết lập kiểu, đọc từ
tệp môi trường theo đường dẫn cố định (không phụ thuộc thư mục làm việc hiện
hành khi khởi động tiến trình — một lựa chọn có chủ đích nhằm tránh sự cố cấu
hình sai do khác biệt thư mục thực thi giữa các môi trường). Thời gian chờ
gọi `story-ai` (270 giây) và ngưỡng chấp nhận kết quả dự phòng
(`STORY_ALLOW_FALLBACK`, mặc định tắt) là hai tham số cấu hình được ghi chú
rõ lý do lựa chọn giá trị ngay trong mã nguồn, thể hiện các quyết định thiết
kế đã được cân nhắc dựa trên vận hành thực tế trước đó.

## 5. Triển khai dịch vụ sinh kịch bản (story-ai)

### 5.1. Kiến trúc và mô hình ngôn ngữ sử dụng

`story-ai` là một ứng dụng FastAPI đơn giản, gồm một điểm cuối nghiệp vụ
chính (sinh kịch bản) và một điểm cuối kiểm tra hoạt động. Mô hình ngôn ngữ
lớn được truy cập thông qua giao diện tương thích chuẩn OpenAI, trỏ đến điểm
cuối dịch vụ MaaS (Model-as-a-Service) của Alibaba Cloud; mô hình chính được
sử dụng là `qwen3.7-plus`, với danh sách mô hình dự phòng được cấu hình sẵn
để chuyển sang khi mô hình chính gặp lỗi giới hạn tốc độ hoặc lỗi từ nhà cung
cấp.

### 5.2. Kỹ thuật xây dựng lời nhắc (prompt engineering)

Lời nhắc hệ thống (system prompt) được xây dựng công phu nhằm ràng buộc mô
hình ngôn ngữ trả về đúng cấu trúc dữ liệu mong muốn mà không cần sử dụng cơ
chế gọi hàm (function calling) hay ràng buộc lược đồ JSON của nhà cung cấp.
Các ràng buộc chính bao gồm: đầu ra phải là JSON thuần không kèm văn bản dẫn
nhập; mỗi khung hình bắt buộc phải có lời thoại (kể cả khung hình mang tính
hành động); mô tả ảnh (`image_prompt`) phải viết bằng tiếng Anh, giới hạn độ
dài, và tuân theo thứ tự ưu tiên nội dung xác định (nhân vật → hành động
chính → bối cảnh → góc máy/ánh sáng) — thứ tự này có chủ đích đặt các yếu tố
quan trọng nhất lên đầu chuỗi mô tả, do tầng sinh ảnh sẽ cắt bớt phần cuối
chuỗi nếu vượt quá giới hạn ký tự cho phép.

Đáng chú ý nhất là cơ chế **nhất quán nhân vật ở tầng văn bản**: lời nhắc yêu
cầu mô hình ngôn ngữ, ngay khi một nhân vật xuất hiện lần đầu, phải tạo ra
một "nhãn mô tả thị giác cố định" ngắn gọn (bao gồm giới tính, độ tuổi, đặc
điểm ước lệ) và sao chép nguyên văn nhãn này ở mọi khung hình sau có sự xuất
hiện của cùng nhân vật đó. Cơ chế này hoạt động độc lập và bổ sung cho cơ chế
nhất quán nhân vật dựa trên ảnh tham chiếu (IP-Adapter) ở tầng `image-ai` đã
trình bày tại mục giao tiếp — một cơ chế tác động ở tầng mô tả văn bản đầu
vào của mô hình sinh ảnh, một cơ chế tác động ở tầng điều kiện hoá thị giác
của quá trình khuếch tán.

Lời nhắc người dùng (user prompt) được sinh động theo số lượng khung hình yêu
cầu, áp dụng một khuôn mẫu cấu trúc kịch bản (dẫn nhập – phát triển – cao trào
– kết thúc, chia theo số khung hình) nhằm định hướng mô hình tạo ra một câu
chuyện có cấu trúc kịch tính thay vì các cảnh rời rạc.

### 5.3. Cơ chế tăng cường ngữ cảnh văn hoá dân gian

Một cơ chế đáng chú ý được phát hiện qua khảo sát mã nguồn — chưa được đề cập
ở mục thiết kế giao tiếp do đây là chi tiết nội tại của `story-ai` — là một
cơ sở tri thức tĩnh gồm hai mươi truyện dân gian và cổ tích Việt Nam (Thạch
Sanh, Tấm Cám, Thánh Gióng, Sơn Tinh Thuỷ Tinh, sự tích Hồ Gươm...), mỗi
truyện được gắn với một tập từ khoá nhận diện và một đoạn ngữ cảnh mô tả bối
cảnh, nhân vật và cốt truyện chuẩn. Khi tóm tắt do người dùng nhập vào khớp
với một truyện trong cơ sở tri thức này (thông qua so khớp từ khoá theo trọng
số, sau khi đã chuẩn hoá bỏ dấu tiếng Việt), ngữ cảnh chuẩn tương ứng được
chèn vào lời nhắc người dùng kèm chỉ dẫn bám sát dữ liệu văn hoá gốc, nhằm
hạn chế hiện tượng mô hình ngôn ngữ "hiện đại hoá" hoặc pha trộn chi tiết
không phù hợp với truyện dân gian truyền thống. Đây có thể được xem như một
cơ chế truy hồi tăng cường sinh (retrieval-augmented generation) ở dạng đơn
giản, dựa trên so khớp từ khoá thay vì biểu diễn vector ngữ nghĩa.

### 5.4. Ép buộc cấu trúc đầu ra và lớp phòng thủ dữ liệu

Do không sử dụng cơ chế ràng buộc lược đồ đầu ra của nhà cung cấp mô hình,
kết quả trả về được phân tích thủ công: loại bỏ phần suy luận trung gian (đối
với các mô hình có khả năng suy luận hiển thị), loại bỏ định dạng khối mã nếu
có, phân tích chuỗi JSON, rồi xác thực bằng một mô hình dữ liệu có ràng buộc.
Đáng chú ý, hệ thống không tin tưởng tuyệt đối vào việc mô hình ngôn ngữ tuân
thủ đúng chỉ dẫn trong lời nhắc: nếu kết quả phân tích vẫn cho ra một khung
hình thiếu lời thoại (vi phạm ràng buộc đã nêu trong lời nhắc), một quy tắc
xác thực bổ sung sẽ tự động bổ khuyết lời thoại mặc định thay vì để lỗi lan
truyền — thể hiện triết lý phòng thủ theo nhiều lớp thay vì chỉ dựa vào một
điểm kiểm soát duy nhất.

### 5.5. Chiến lược thử lại và kết quả dự phòng

Chiến lược thử lại được cài đặt theo hai trục kết hợp: trục đổi mô hình (khi
gặp lỗi giới hạn tốc độ hoặc lỗi nhà cung cấp, hệ thống thử ngay mô hình dự
phòng tiếp theo trước khi tính đến việc chờ và thử lại) và trục chờ-thử lại
cổ điển (khi đã hết mô hình dự phòng, hệ thống tính thời gian chờ dựa trên đề
xuất từ phản hồi lỗi, giới hạn trên ở một ngưỡng cố định nhằm đảm bảo tổng
thời gian xử lý không vượt quá thời gian chờ tối đa mà tầng gọi đã cấu hình).
Khi toàn bộ các lần thử đều thất bại, dịch vụ trả về một kết quả dự phòng
được tổng hợp một phần từ nội dung tóm tắt gốc do người dùng cung cấp (không
phải một kịch bản cố định hoàn toàn), kèm cờ đánh dấu rõ ràng để tầng điều
phối nhận diện và xử lý theo chính sách đã cấu hình.

## 6. Triển khai dịch vụ sinh ảnh (image-ai)

### 6.1. Mô hình sinh ảnh và tối ưu suy luận

Dịch vụ sử dụng một mô hình khuếch tán (diffusion model) nền tảng Stable
Diffusion 1.5 làm mặc định, với lớp pipeline suy luận được lựa chọn động theo
loại mô hình (kiến trúc SDXL hay SD1.5 cổ điển) và bộ lập lịch khuếch tán
(scheduler) được lựa chọn phù hợp với đặc tính mô hình (lập lịch chuyên biệt
cho mô hình rút gọn bước suy luận, hoặc lập lịch đa bước tổng quát cho các
mô hình còn lại). Hệ thống hỗ trợ tuỳ chọn tinh chỉnh trọng số nhẹ (LoRA)
tuy không bật theo mặc định.

Về mặt tối ưu vận hành, dịch vụ áp dụng nhiều kỹ thuật tuỳ theo phần cứng suy
luận thực tế: sử dụng độ chính xác nửa (fp16) và cơ chế tính chú ý hiệu quả
bộ nhớ trên GPU rời (CUDA); áp dụng các kỹ thuật giảm tải bộ nhớ (chia lát,
xếp gạch, dồn tính toán sang CPU) khi cấu hình chạy ở chế độ bộ nhớ hạn chế.
Một nhánh xử lý riêng biệt và khá phức tạp được cài đặt cho phần cứng Apple
Silicon nhằm giải quyết vấn đề đặc thù (giải mã ảnh cuối cùng bằng độ chính
xác đầy đủ trên CPU để tránh lỗi giá trị không hợp lệ khi chạy trên GPU tích
hợp của Apple) — cho thấy dịch vụ được thiết kế để chạy được cả trên môi
trường phát triển phần cứng hạn chế lẫn môi trường sản xuất có GPU chuyên
dụng. Ngoài ra, để vượt qua giới hạn 77 token của bộ mã hoá văn bản CLIP tiêu
chuẩn, hệ thống áp dụng kỹ thuật chia đoạn văn bản mô tả thành nhiều phần rồi
mã hoá riêng từng phần trước khi ghép lại.

### 6.2. Luồng xử lý một yêu cầu sinh ảnh

Một yêu cầu sinh ảnh đi qua ba tầng xử lý kế tiếp nhau: (i) tầng tiếp nhận
gRPC kiểm tra tính hợp lệ của tham số đầu vào (kích thước ảnh, số bước suy
luận, độ dài văn bản chú thích) trước khi đẩy tác vụ thực sự vào hàng đợi bất
đồng bộ Celery và trả về ngay định danh tác vụ; (ii) tác vụ Celery kiểm tra
lớp cache kết quả (trình bày ở mục 6.4) và áp dụng cơ chế khoá tránh trùng
lặp trước khi gọi đến lớp suy luận thực sự; (iii) lớp suy luận (pipeline
runner) xây dựng lời nhắc cuối cùng (kết hợp hậu tố phong cách cố định nhằm
ràng buộc mô hình chỉ sinh một khung cảnh đơn lẻ thay vì một trang truyện
nhiều khung), xử lý ảnh tham chiếu nếu cơ chế nhất quán nhân vật được bật,
thực thi suy luận trong một đoạn mã được bảo vệ bằng khoá luồng (đảm bảo GPU
xử lý tuần tự trong phạm vi một tiến trình worker), rồi chuyển kết quả qua các
bước hậu xử lý.

Các bước hậu xử lý gồm: kiểm tra ảnh đầu ra không bị hỏng/toàn màu đen (dựa
trên độ sáng trung bình), sàng lọc nội dung không phù hợp bằng một mô hình
phân loại chuyên biệt độc lập với bộ lọc an toàn tích hợp sẵn của thư viện
khuếch tán (vốn đã bị tắt do có xu hướng gây dương tính giả trên ảnh phong
cách truyện tranh), tăng cường màu sắc/độ tương phản, rồi tải lên kho lưu
trữ đối tượng và trả về URL có chữ ký tạm thời.

### 6.3. Cơ chế điều kiện hoá ảnh tham chiếu (IP-Adapter)

Khi cơ chế nhất quán nhân vật dựa trên ảnh tham chiếu được bật, mô hình được
nạp thêm bộ điều hợp ảnh (IP-Adapter) tương ứng với kiến trúc nền (SDXL hoặc
SD1.5) ngay tại thời điểm khởi tạo pipeline. Một ràng buộc kỹ thuật quan
trọng của thư viện khuếch tán được xử lý cẩn thận trong mã nguồn: một khi bộ
điều hợp ảnh đã được nạp vào pipeline, mọi lượt suy luận sau đó bắt buộc phải
truyền vào một ảnh điều kiện, kể cả khi không có ảnh tham chiếu thực sự (ví
dụ khung hình đầu tiên của một tác vụ, hoặc khi việc tải ảnh tham chiếu qua
mạng gặp lỗi). Giải pháp được áp dụng là sử dụng một ảnh trắng trơn kích
thước cố định làm ảnh điều kiện giả, đồng thời đặt hệ số ảnh hưởng của bộ
điều hợp về không, nhằm triệt tiêu hoàn toàn tác động thị giác của ảnh giả
này lên kết quả sinh ra — một giải pháp kỹ thuật cụ thể để dung hoà giữa ràng
buộc bắt buộc của API thư viện và ngữ nghĩa nghiệp vụ ("không có ảnh tham
chiếu" phải có nghĩa là không chịu ảnh hưởng).

```python
# image-ai/src/core/pipeline_runner.py (minh hoạ cơ chế placeholder)
def _blank_ip_adapter_image(self):
    # Diffusers yêu cầu luôn phải truyền ip_adapter_image một khi đã
    # load_ip_adapter() — không truyền sẽ gây lỗi thực thi. Dùng ảnh
    # trắng trơn kèm set_ip_adapter_scale(0) để triệt tiêu ảnh hưởng.
    return Image.new("RGB", (224, 224), color="white")
```

### 6.4. Cơ chế cache kết quả và kiểm soát tài nguyên GPU

Nhằm tránh chi phí suy luận lặp lại cho các yêu cầu có tham số hoàn toàn giống
nhau, hệ thống tính một giá trị băm từ toàn bộ tập tham số ảnh hưởng đến kết
quả sinh ảnh (nội dung mô tả đã chuẩn hoá, hạt giống ngẫu nhiên, kích thước,
số bước, định danh mô hình kèm cấu hình LoRA/IP-Adapter, hệ số hướng dẫn, ảnh
tham chiếu, định dạng và chất lượng ảnh xuất...) để làm khoá tra cứu kết quả
đã lưu trong Redis, với thời gian sống một giờ. Để tránh hiện tượng nhiều yêu
cầu giống hệt nhau cùng kích hoạt suy luận đồng thời khi chưa có kết quả trong
cache, hệ thống áp dụng khoá độc quyền theo khoá băm (thiết lập có điều kiện
kèm thời gian hết hạn), với các yêu cầu trùng lặp đến sau chờ có giới hạn thời
gian để tái sử dụng kết quả của yêu cầu đến trước thay vì tự chiếm quyền suy
luận.

Việc kiểm soát tài nguyên GPU không dựa trên cơ chế khoá đồng thời tường minh
ở tầng ứng dụng, mà dựa vào cấu hình của Celery giới hạn mỗi worker chỉ nhận
xử lý một tác vụ tại một thời điểm, kết hợp một khoá luồng cục bộ bao quanh
thao tác suy luận trong phạm vi một tiến trình. Sau mỗi lượt suy luận (dù
thành công hay thất bại), bộ nhớ GPU được chủ động giải phóng thông qua các
lệnh dọn bộ nhớ đệm tương ứng với nền tảng phần cứng đang chạy (CUDA hoặc
Apple Silicon).

## 7. Thảo luận tổng hợp về triển khai

Từ việc khảo sát chi tiết cách hiện thực hoá từng dịch vụ, có thể rút ra một
số nhận xét chung, bổ sung cho các nhận xét đã nêu ở mục thiết kế giao tiếp:

1. **Chiến lược chịu lỗi được cài đặt ở nhiều tầng độc lập, không đồng nhất
   về mức độ hoàn thiện.** Một số cơ chế được cài đặt kỹ lưỡng và có ghi chú
   rõ lý do lựa chọn tham số (thời gian chờ ở `story-ai`/`orchestrator-ai`,
   lớp phòng thủ dữ liệu sau khi phân tích JSON); một số cơ chế khác được
   thiết kế đúng về chủ đích nhưng còn khiếm khuyết trong hiện thực hoá — cụ
   thể là cơ chế dừng sớm khi huỷ tác vụ tại `orchestrator-ai` (mục 4.3),
   nơi cờ huỷ không được cập nhật lại từ nguồn dữ liệu dùng chung trong suốt
   quá trình luồng xử lý thực thi.
2. **Nhất quán nhân vật được tiếp cận đồng thời ở hai tầng độc lập:** tầng
   văn bản (nhãn mô tả thị giác cố định do mô hình ngôn ngữ tự sinh và lặp
   lại) và tầng thị giác (điều kiện hoá ảnh tham chiếu qua IP-Adapter, hiện
   đang tắt theo cấu hình mặc định). Hai cơ chế này độc lập nhau về mặt kỹ
   thuật nhưng cùng phục vụ một mục tiêu nghiệp vụ, cho thấy một hướng tiếp
   cận đa tầng đối với bài toán vốn được biết là khó của các mô hình sinh
   ảnh khuếch tán khi sinh độc lập từng khung hình.
3. **Một số lớp kiểm soát chất lượng đầu ra không xuất hiện ở tầng đặc tả
   giao tiếp** (được trình bày ở mục trước) **mà chỉ lộ diện khi khảo sát
   tầng triển khai**, cụ thể là bộ lọc nội dung không phù hợp và cơ chế kiểm
   tra ảnh hỏng tại `image-ai`. Điều này cho thấy đặc tả giao thức giữa các
   dịch vụ (protocol-level) không phản ánh đầy đủ các ràng buộc chất lượng
   được xử lý nội bộ trong từng dịch vụ, và việc đánh giá một hệ thống phân
   tán cần khảo sát ở cả hai tầng để có bức tranh đầy đủ.
4. **Một số cấu phần được cài đặt sẵn nhưng chưa được kích hoạt** (bộ lọc
   ngoại lệ và interceptor ghi log tại `be-comic`, interceptor ghi log tại
   `fe-comic`, mô hình dữ liệu nhân vật chưa nối vào luồng chính) cho thấy hệ
   thống có tính mở, được chuẩn bị cho các mở rộng đã dự trù nhưng chưa hoàn
   tất trong phạm vi phiên bản hiện tại.

Các nhận xét trên, cùng với các nhận xét đã nêu ở mục thiết kế giao tiếp,
được sử dụng làm cơ sở cho phần đánh giá kết quả và đề xuất hướng phát triển
ở chương kết luận của luận văn.
