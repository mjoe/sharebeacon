import Foundation
import os

enum LogLevel: String, Codable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
}

struct AppLogEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let message: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: LogLevel,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
}

final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()

    private let systemLogger = Logger(
        subsystem: "com.valmayaki.mountjockey",
        category: "mount"
    )
    private let queue = DispatchQueue(label: "com.valmayaki.mountjockey.log")
    private let maximumBytes: UInt64 = 2 * 1_024 * 1_024

    var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/mountjockey.log")
    }

    func write(_ message: String, level: LogLevel = .info) {
        let sanitized = Self.sanitize(message)
        switch level {
        case .debug:
            systemLogger.debug("\(sanitized, privacy: .public)")
        case .info:
            systemLogger.info("\(sanitized, privacy: .public)")
        case .warning:
            systemLogger.warning("\(sanitized, privacy: .public)")
        case .error:
            systemLogger.error("\(sanitized, privacy: .public)")
        }

        queue.async {
            self.rotateIfNeeded()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let line = "\(formatter.string(from: Date())) [\(level.rawValue)] \(sanitized)\n"
            guard let data = line.data(using: .utf8) else { return }

            if !FileManager.default.fileExists(atPath: self.logURL.path) {
                FileManager.default.createFile(atPath: self.logURL.path, contents: data)
                return
            }

            do {
                let handle = try FileHandle(forWritingTo: self.logURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                self.systemLogger.error("Failed writing file log: \(error.localizedDescription)")
            }
        }
    }

    private func rotateIfNeeded() {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
            let size = attributes[.size] as? UInt64,
            size >= maximumBytes
        else {
            return
        }

        let rotated = logURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: logURL, to: rotated)
    }

    private static func sanitize(_ value: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?i)(smb://[^:\s/@]+):([^@\s]+)@"#
        ) else {
            return value
        }
        let range = NSRange(value.startIndex..., in: value)
        return expression.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: "$1:<redacted>@"
        )
    }
}

func logDebug(_ message: String) {
    AppLogger.shared.write(message, level: .debug)
}

func logInfo(_ message: String) {
    AppLogger.shared.write(message, level: .info)
}

func logWarning(_ message: String) {
    AppLogger.shared.write(message, level: .warning)
}

func logError(_ message: String) {
    AppLogger.shared.write(message, level: .error)
}
