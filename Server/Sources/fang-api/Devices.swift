import Crypto
import Foundation

/// Device sign-in without a password over the network. The app picks a random token and creates an
/// empty file named after the token's SHA-256 in the hidden `fang$` share, over the SMB session it has
/// already authenticated. Samba creates the file as that user, so the file's owner says whose token it
/// is. Deleting the file revokes the device.
struct Devices: Sendable {
    /// The `devices` folder of the `fang$` share (mode 1733: anyone may add a file, nobody may list).
    var folder: String
    /// FaNG's users, `name:uid` a line.
    var usersFile: String

    /// A short name for the device a token belongs to (the start of its file name), for grouping conflicts.
    static func device(forToken token: Substring) -> String {
        String(SHA256.hash(data: Data(token.lowercased().utf8)).map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    /// The user a bearer token belongs to, or nil.
    func user(forToken token: Substring) -> String? {
        guard token.count == 64, token.allSatisfy(\.isHexDigit) else { return nil }
        let digest = SHA256.hash(data: Data(token.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: folder + "/" + digest),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let owner = (attributes[.ownerAccountID] as? NSNumber)?.intValue
        else { return nil }
        return users()[owner]
    }

    private func users() -> [Int: String] {
        guard let text = try? String(contentsOfFile: usersFile, encoding: .utf8) else { return [:] }
        var users: [Int: String] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: ":")
            if fields.count == 2, let uid = Int(fields[1]) {
                users[uid] = String(fields[0])
            }
        }
        return users
    }
}
