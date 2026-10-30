import SwiftUI
import PhotosUI
import UIKit

struct ContentView: View {
    @State private var creds: Creds? = CredStore.load()
    @State private var maFileText = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var log = ""
    @State private var status = "Sẵn sàng."
    @State private var busy = false

    var body: some View {
        NavigationStack {
            if creds == nil {
                setupView
            } else {
                approveView
            }
        }
    }

    // MARK: - Nhập maFile

    private var setupView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dán nội dung maFile")
                .font(.headline)
            Text("Mở file ...\\steamguard-cli\\maFiles\\<tên>.maFile bằng Notepad, copy toàn bộ rồi dán vào đây. Secret chỉ lưu trong Keychain của máy này.")
                .font(.footnote).foregroundStyle(.secondary)
            TextEditor(text: $maFileText)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.gray.opacity(0.4)))
            Button {
                do {
                    let c = try SteamApprover.parseMaFile(maFileText)
                    CredStore.save(c)
                    creds = c
                    status = "Đã lưu maFile cho \(c.steamID)."
                } catch {
                    status = error.localizedDescription
                }
            } label: {
                Text("Lưu maFile").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(maFileText.isEmpty)
            Text(status).font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
        .navigationTitle("Steam QR — Cài đặt")
    }

    // MARK: - Duyệt

    private var approveView: some View {
        VStack(spacing: 14) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Chọn ảnh QR & Duyệt", systemImage: "photo")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)

            Button {
                if let img = UIPasteboard.general.image {
                    runApprove(img)
                } else {
                    status = "Clipboard không có ảnh. Chụp QR rồi thử lại."
                }
            } label: {
                Label("Dán QR từ clipboard & Duyệt", systemImage: "doc.on.clipboard")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(busy)

            Text(status)
                .font(.subheadline)
                .foregroundStyle(busy ? .secondary : .primary)

            ScrollView {
                Text(log.isEmpty ? "(log sẽ hiện ở đây)" : log)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: .infinity)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.85)))
            .foregroundStyle(.green)

            Text("QR hết hạn sau vài chục giây. Cần mạng vào được Steam (bật VPN nếu bị chặn).")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
        .navigationTitle("Steam QR")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Xóa maFile", role: .destructive) {
                    CredStore.clear(); creds = nil; maFileText = ""; log = ""
                }
            }
        }
        .onChange(of: photoItem) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    runApprove(img)
                } else {
                    status = "Không đọc được ảnh đã chọn."
                }
            }
        }
    }

    private func addLog(_ s: String) { log += (log.isEmpty ? "" : "\n") + s }

    private func runApprove(_ image: UIImage) {
        guard var c = creds else { return }
        busy = true; status = "Đang duyệt..."
        addLog("> bắt đầu duyệt")
        Task {
            do {
                try await SteamApprover.approve(image: image, creds: &c)
                CredStore.save(c); creds = c          // lưu lại token đã refresh
                status = "✅ Đã duyệt đăng nhập!"
                addLog("THÀNH CÔNG")
            } catch {
                status = "❌ " + error.localizedDescription
                addLog("LỖI: " + error.localizedDescription)
            }
            busy = false
        }
    }
}
