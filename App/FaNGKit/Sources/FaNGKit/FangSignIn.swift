import CryptoKit
import Foundation

/// Finds a FaNG server behind an SMB login and signs this device in to its API, without sending the
/// password anywhere but SMB. Both go through the hidden `fang$` share, over the session the login
/// already authenticated:
/// - `server.json` holds the API's port and certificate fingerprint;
/// - an empty file in `devices/` named after the SHA-256 of a random token makes that token this user's
///   (Samba creates the file as the signed-in user, and the server trusts the file's owner).
public enum FangSignIn {
    static let share = "fang$"

    /// The FaNG server behind this login, or nil for plain SMB (no `fang$` share).
    public static func detect(on backend: SMBBackend) async -> FangServer? {
        guard let data = try? await backend.read("\(share)/server.json", range: 0..<4096),
              let server = try? JSONDecoder().decode(FangServer.self, from: data)
        else { return nil }
        return server
    }

    /// Makes a new device token and registers it. Returns the token.
    public static func signIn(on backend: SMBBackend) async throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw POSIXError(.EIO) }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let name = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        let empty = FileManager.default.temporaryDirectory.appending(path: "fang-token-\(UUID().uuidString)")
        try Data().write(to: empty)
        defer { try? FileManager.default.removeItem(at: empty) }
        try await backend.upload(empty, to: "\(share)/devices/\(name)", from: 0, progress: Progress())
        return token
    }
}
