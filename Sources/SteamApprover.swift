import Foundation
import CryptoKit
import Vision
import UIKit

enum ApproveError: LocalizedError {
    case noCreds
    case badQR
    case noTokens
    case refreshFailed(String)
    case approveFailed(String)

    var errorDescription: String? {
        switch self {
        case .noCreds: return "Chưa có maFile. Hãy dán maFile trước."
        case .badQR: return "Không đọc được mã QR đăng nhập Steam trong ảnh (phải là link s.team/q/...)."
        case .noTokens: return "maFile không có refresh_token. Chạy `steamguard qr-login` 1 lần trên PC để tạo token, rồi copy lại maFile."
        case .refreshFailed(let m): return "Làm mới token thất bại: \(m)"
        case .approveFailed(let m): return "Duyệt thất bại: \(m)"
        }
    }
}

/// Thông tin rút từ maFile.
struct Creds: Codable {
    var sharedSecret: String      // base64
    var refreshToken: String
    var accessToken: String?
    var steamID: UInt64
}

struct SteamApprover {

    // MARK: - QR

    static func decodeQR(_ image: UIImage) -> String? {
        guard let cg = image.cgImage else { return nil }
        let req = VNDetectBarcodesRequest()
        req.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([req])
        let obs = req.results?.compactMap { $0.payloadStringValue } ?? []
        return obs.first { $0.lowercased().hasPrefix("https://s.team/q/") }
    }

    /// Tách version + client_id từ URL https://s.team/q/<version>/<client_id>
    static func parseChallenge(_ url: String) -> (version: Int32, clientID: UInt64)? {
        guard let comps = URL(string: url)?.pathComponents else { return nil }
        // ["/", "q", "<version>", "<client_id>"]
        let parts = comps.filter { $0 != "/" }
        guard parts.count >= 3, parts[0].lowercased() == "q",
              let version = Int32(parts[1]), let clientID = UInt64(parts[2]) else { return nil }
        return (version, clientID)
    }

    // MARK: - maFile -> Creds

    static func parseMaFile(_ json: String) throws -> Creds {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw ApproveError.noCreds
        }
        guard let shared = findString(obj, keys: ["shared_secret"]) else { throw ApproveError.noCreds }
        guard let refresh = findString(obj, keys: ["refresh_token", "RefreshToken"]) else {
            throw ApproveError.noTokens
        }
        let access = findString(obj, keys: ["access_token", "AccessToken"])
        // steamid lấy từ JWT (chắc chắn đúng) rồi mới tới field trong maFile.
        let sid = jwtSub(refresh) ?? (access.flatMap(jwtSub)) ?? findSteamID(obj)
        guard let steamID = sid else { throw ApproveError.noTokens }
        return Creds(sharedSecret: shared, refreshToken: refresh, accessToken: access, steamID: steamID)
    }

    // MARK: - Duyệt

    static func approve(image: UIImage, creds: inout Creds) async throws {
        guard let qr = decodeQR(image), let ch = parseChallenge(qr) else { throw ApproveError.badQR }

        let token = try await validAccessToken(&creds)
        let sig = signature(sharedSecretB64: creds.sharedSecret,
                            version: ch.version, clientID: ch.clientID, steamID: creds.steamID)

        var w = ProtoWriter()
        w.int32(1, ch.version)
        w.uint64(2, ch.clientID)
        w.fixed64(3, creds.steamID)
        w.bytesField(4, [UInt8](sig))
        w.bool(5, true)        // confirm
        w.uint64(6, 1)         // persistence = k_ESessionPersistence_Persistent

        let b64 = w.data.base64EncodedString()
        var comps = URLComponents(string: "https://api.steampowered.com/IAuthenticationService/UpdateAuthSessionWithMobileConfirmation/v1/")!
        comps.queryItems = [URLQueryItem(name: "access_token", value: token)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form(["input_protobuf_encoded": b64])

        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ApproveError.approveFailed("không có HTTP response") }
        let eresult = http.value(forHTTPHeaderField: "x-eresult") ?? ""
        if http.statusCode == 200 && (eresult == "1" || eresult.isEmpty) {
            return
        }
        let errmsg = http.value(forHTTPHeaderField: "x-error_message") ?? ""
        throw ApproveError.approveFailed("HTTP \(http.statusCode), eresult=\(eresult) \(errmsg)")
    }

    // MARK: - Token

    /// Trả access_token còn hạn; tự refresh nếu cần (và lưu lại vào creds).
    static func validAccessToken(_ creds: inout Creds) async throws -> String {
        if let t = creds.accessToken, let exp = jwtExp(t), exp > Date().addingTimeInterval(60) {
            return t
        }
        var w = ProtoWriter()
        w.string(1, creds.refreshToken)   // refresh_token
        w.fixed64(2, creds.steamID)       // steamid
        w.uint64(3, 0)                    // renewal_type = None
        let b64 = w.data.base64EncodedString()

        let url = URL(string: "https://api.steampowered.com/IAuthenticationService/GenerateAccessTokenForApp/v1/")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form(["input_protobuf_encoded": b64])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw ApproveError.refreshFailed("HTTP \(code)")
        }
        var reader = ProtoReader(data)
        let fields = reader.readStringFields()
        guard let newAccess = fields[1], !newAccess.isEmpty else {
            throw ApproveError.refreshFailed("không nhận được access_token mới")
        }
        creds.accessToken = newAccess
        if let newRefresh = fields[2], !newRefresh.isEmpty { creds.refreshToken = newRefresh }
        return newAccess
    }

    // MARK: - Crypto

    static func signature(sharedSecretB64: String, version: Int32, clientID: UInt64, steamID: UInt64) -> Data {
        var msg = [UInt8]()
        withUnsafeBytes(of: UInt16(truncatingIfNeeded: version).littleEndian) { msg.append(contentsOf: $0) }
        withUnsafeBytes(of: clientID.littleEndian) { msg.append(contentsOf: $0) }
        withUnsafeBytes(of: steamID.littleEndian) { msg.append(contentsOf: $0) }
        let keyData = Data(base64Encoded: sharedSecretB64) ?? Data()
        let mac = HMAC<SHA256>.authenticationCode(for: Data(msg), using: SymmetricKey(data: keyData))
        return Data(mac)
    }

    // MARK: - Helpers

    private static func form(_ dict: [String: String]) -> Data {
        let pairs = dict.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? v)"
        }
        return pairs.joined(separator: "&").data(using: .utf8)!
    }

    private static func jwtPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var s = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let d = Data(base64Encoded: s),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return obj
    }

    private static func jwtExp(_ jwt: String) -> Date? {
        guard let p = jwtPayload(jwt), let exp = p["exp"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: exp.doubleValue)
    }

    private static func jwtSub(_ jwt: String) -> UInt64? {
        guard let p = jwtPayload(jwt), let sub = p["sub"] as? String else { return nil }
        return UInt64(sub)
    }

    private static func findString(_ obj: Any, keys: [String]) -> String? {
        if let dict = obj as? [String: Any] {
            for (k, v) in dict where keys.contains(where: { $0.caseInsensitiveCompare(k) == .orderedSame }) {
                if let s = v as? String, !s.isEmpty { return s }
            }
            for (_, v) in dict { if let r = findString(v, keys: keys) { return r } }
        } else if let arr = obj as? [Any] {
            for v in arr { if let r = findString(v, keys: keys) { return r } }
        }
        return nil
    }

    private static func findSteamID(_ obj: Any) -> UInt64? {
        if let dict = obj as? [String: Any] {
            for (k, v) in dict where ["steamid", "steam_id", "SteamID"].contains(where: { $0.caseInsensitiveCompare(k) == .orderedSame }) {
                if let s = v as? String, let n = UInt64(s) { return n }
                if let n = v as? NSNumber { return n.uint64Value }
            }
            for (_, v) in dict { if let r = findSteamID(v) { return r } }
        } else if let arr = obj as? [Any] {
            for v in arr { if let r = findSteamID(v) { return r } }
        }
        return nil
    }
}
