# SteamQRApprover (iOS)

App iPhone duyệt đăng nhập Steam từ ảnh mã QR, dùng maFile của steamguard-cli.

> ⚠️ **Code này CHƯA được test trên thiết bị thật.** Nhiều khả năng cần sửa vài vòng.
> Build → sideload → thử → gửi log lỗi để sửa tiếp.

## Nó làm gì
1. Bạn dán nội dung **maFile** 1 lần (secret lưu trong Keychain của iPhone).
2. Chọn/dán ảnh QR đăng nhập Steam.
3. App đọc QR, tự làm mới token nếu cần, ký HMAC và gọi API Steam để duyệt.

Giao thức dựa trên:
- Chữ ký: HMAC-SHA256(key = base64decode(shared_secret),
  msg = version(2B LE) + client_id(8B LE) + steamid(8B LE)).
- `IAuthenticationService/UpdateAuthSessionWithMobileConfirmation/v1` (protobuf).
- Refresh token: `IAuthenticationService/GenerateAccessTokenForApp/v1`.

## Build ra .ipa bằng GitHub Actions (không cần Mac)

1. Tạo repo GitHub (private cũng được), đẩy toàn bộ thư mục này lên nhánh `main`.
   ```bash
   git init
   git add .
   git commit -m "SteamQRApprover"
   git branch -M main
   git remote add origin https://github.com/<bạn>/<repo>.git
   git push -u origin main
   ```
2. Vào tab **Actions** của repo → workflow **Build IPA** sẽ tự chạy (hoặc bấm
   "Run workflow"). Chờ ~3–5 phút.
3. Mở lần chạy xong → mục **Artifacts** → tải `SteamQRApprover-ipa` →
   giải nén được `SteamQRApprover.ipa` (chưa ký — AltStore/Sideloadly sẽ ký khi cài).

## Sideload lên iPhone (Apple ID miễn phí — hết hạn 7 ngày)

**Cách dễ nhất: AltStore**
1. Trên PC Windows cài **AltServer** (altstore.io). Cài **AltStore** lên iPhone qua AltServer
   (cắm cáp lần đầu, đăng nhập Apple ID — nên dùng Apple ID phụ).
2. Chép `SteamQRApprover.ipa` vào iPhone (AirDrop/Files/iCloud).
3. Mở **AltStore** trên iPhone → tab **My Apps** → dấu **+** → chọn file .ipa → nó ký & cài.
4. Vào **Cài đặt > Cài đặt chung > VPN & Quản lý thiết bị** → tin tưởng (trust) chứng chỉ
   developer của bạn.
5. **7 ngày/lần:** mở AltStore (khi PC bật AltServer cùng Wi-Fi) để nó tự ký gia hạn. Nếu
   quá hạn, app ngừng mở được → cài/refresh lại.

> Sideloadly (Windows) cũng làm được tương tự nếu không dùng AltStore.

## Dùng app
1. Mở app, dán nội dung maFile, bấm **Lưu maFile**.
2. Khi cần duyệt: chụp/chọn ảnh QR → bấm duyệt.
3. **Bật VPN** nếu mạng của bạn bị chặn Steam (giống trên PC).

## Nếu lỗi — gửi mình các thông tin này
- Dòng trong khung log đen của app (đặc biệt `HTTP ...`, `eresult=...`).
- Build fail trên Actions: copy đoạn đỏ trong log bước **Build (unsigned)**.

## Cấu trúc
```
project.yml                     # XcodeGen sinh ra .xcodeproj trên CI
Sources/App.swift               # entry SwiftUI
Sources/ContentView.swift       # giao diện
Sources/Store.swift             # lưu secret vào Keychain
Sources/SteamApprover.swift     # QR, crypto, protobuf, gọi API, refresh token
Sources/Protobuf.swift          # ghi/đọc protobuf tối giản
.github/workflows/build.yml     # build .ipa chưa ký
```

## Điểm có thể phải chỉnh (đã liệu trước)
- maFile của bạn có thể **không chứa** `refresh_token` → app báo "maFile không có refresh_token".
  Khi đó cần lấy token (chạy đăng nhập) — sẽ bổ sung luồng login nếu gặp.
- `access_token` gắn ở query; nếu Steam đòi ở chỗ khác sẽ chỉnh trong `SteamApprover.approve`.
- `PRODUCT_BUNDLE_IDENTIFIER` trong `project.yml` nên đổi thành của riêng bạn.
