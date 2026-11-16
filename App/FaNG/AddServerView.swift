import FaNGKit
import SwiftUI

/// Server address and sign-in: the one thing that needs the app. Everything else happens in Files/Finder.
struct AddServerView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var port = 445
    @State private var username = ""
    @State private var password = ""
    @State private var encrypted = false
    @State private var shares: [String]?
    @State private var displayName = "FaNG"
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var canConnect: Bool {
        !host.trimmed.isEmpty && (1...65535).contains(port) && !isWorking
    }

    private var canAdd: Bool {
        canConnect && !displayName.trimmed.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Address", text: $host, prompt: Text(verbatim: "192.168.1.10"))
                        .accessibilityIdentifier("host")
                        .serverFieldStyle()
                    TextField("Port", value: $port, format: .number.grouping(.never))
                        .accessibilityIdentifier("port")
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    Toggle("Require Encryption (SMB3)", isOn: $encrypted)
                }

                Section("Sign In") {
                    TextField("Username", text: $username)
                        .accessibilityIdentifier("username")
                        .serverFieldStyle()
                        .textContentType(.username)
                    SecureField("Password", text: $password)
                        .accessibilityIdentifier("password")
                        .textContentType(.password)
                    Button("Test Connection", action: testConnection)
                        .disabled(!canConnect)
                }

                if let shares {
                    Section("Shares You Can Open") {
                        if shares.isEmpty {
                            Text("None")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(shares, id: \.self) { share in
                            Label(share, systemImage: "folder")
                        }
                    }
                }

                Section {
                    TextField("Name in \(ContentView.filesAppName)", text: $displayName)
                        .accessibilityIdentifier("displayName")
                } footer: {
                    Text("Every share you can open appears as a folder in this location.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button("Add", action: add)
                            .disabled(!canAdd)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private var account: ServerAccount {
        ServerAccount(
            displayName: displayName.trimmed, host: host.trimmed, port: port,
            username: username.trimmed, encrypted: encrypted
        )
    }

    private func testConnection() {
        run {
            shares = try await SMBBackend(account: account, password: password, timeout: 15).accessibleShares()
        }
    }

    /// Checks the login opens at least one share, then adds the server to Files/Finder.
    private func add() {
        run {
            let account = account
            let shares = try await SMBBackend(account: account, password: password, timeout: 15).accessibleShares()
            self.shares = shares
            guard !shares.isEmpty else { throw POSIXError(.EACCES) }
            try await DomainController.add(account, password: password)
            dismiss()
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await work()
            } catch {
                errorMessage = Self.message(for: error)
            }
            isWorking = false
        }
    }

    private static func message(for error: Error) -> String {
        guard let posix = error as? POSIXError else { return error.localizedDescription }
        switch posix.code {
        case .ECONNREFUSED:
            return "The server refused the connection. Check the username, password and port. (\(posix.localizedDescription))"
        case .ETIMEDOUT, .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN:
            return "Couldn't reach the server. Check the address, and that FaNG is allowed to use the local network. (\(posix.localizedDescription))"
        case .EACCES:
            return "This login can't open any shares on the server."
        default:
            return posix.localizedDescription
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

private extension View {
    /// Plain text entry for addresses, usernames and share names.
    func serverFieldStyle() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
        #else
        autocorrectionDisabled()
        #endif
    }
}

#Preview {
    AddServerView()
}
