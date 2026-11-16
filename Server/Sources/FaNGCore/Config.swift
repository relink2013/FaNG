import Foundation
import Logging
import PostgresNIO

/// The server's settings, from the environment the container sets.
public struct Config: Sendable {
    public var httpPort: Int
    public var postgres: PostgresClient.Configuration
    public var sharesFile: String
    public var sambaPIDFile: String
    public var logLevel: Logger.Level

    public enum Failure: Error, CustomStringConvertible {
        case missing(String)

        public var description: String {
            switch self {
            case .missing(let name): "\(name) isn't set."
            }
        }
    }

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Config {
        func required(_ name: String) throws -> String {
            guard let value = environment[name], !value.isEmpty else { throw Failure.missing(name) }
            return value
        }
        var postgres = PostgresClient.Configuration(
            host: environment["FANG_DB_HOST"] ?? "fang-postgres",
            port: 5432,
            username: environment["FANG_DB_USER"] ?? "fang",
            password: try required("FANG_DB_PASSWORD"),
            database: environment["FANG_DB_NAME"] ?? "fang",
            tls: .disable  // Only reachable on the stack's internal network.
        )
        // Enough connections for the workers each service runs, within Postgres's 100 for the three services.
        postgres.options.maximumConnections = Resources.workers(cpuShare: 1, memoryPerWorker: 1, limit: 30, setting: "FANG_DB_CONNECTIONS")
        return Config(
            httpPort: Int(environment["FANG_HTTPS_PORT"] ?? "") ?? 443,
            postgres: postgres,
            sharesFile: environment["FANG_SHARES_FILE"] ?? "/config/shares.conf",
            sambaPIDFile: environment["FANG_SAMBA_PID_FILE"] ?? "/run/samba/smbd.pid",
            logLevel: Logger.Level(rawValue: environment["FANG_LOG_LEVEL"] ?? "") ?? .info
        )
    }
}
