import Foundation
import Observation
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

@MainActor
@Observable
final class AppLogger {
    static let shared = AppLogger()

    private(set) var recentEntries: [AppLogEntry] = []

    nonisolated private static let systemLogger = Logger(
        subsystem: "com.mjoe.sharebeacon",
        category: "mount"
    )
    private static let queue = DispatchQueue(label: "com.mjoe.sharebeacon.log")
    private static let maximumBytes: UInt64 = 2 * 1_024 * 1_024

    var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/sharebeacon.log")
    }

    func record(_ message: String, level: LogLevel = .info) {
        let entry = AppLogEntry(level: level, message: message)
        recentEntries.append(entry)
        if recentEntries.count > 200 {
            recentEntries.removeFirst(recentEntries.count - 200)
        }

        let sanitized = Self.sanitize(message)
        switch level {
        case .debug:
            Self.systemLogger.debug("\(sanitized, privacy: .public)")
        case .info:
            Self.systemLogger.info("\(sanitized, privacy: .public)")
        case .warning:
            Self.systemLogger.warning("\(sanitized, privacy: .public)")
        case .error:
            Self.systemLogger.error("\(sanitized, privacy: .public)")
        }

        let logURL = self.logURL
        let maximumBytes = Self.maximumBytes
        Self.queue.async {
            Self.rotateIfNeededIfNeeded(at: logURL, maximumBytes: maximumBytes)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let line = "\(formatter.string(from: Date())) [\(level.rawValue)] \(sanitized)\n"
            guard let data = line.data(using: .utf8) else { return }

            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: data)
                return
            }

            do {
                let handle = try FileHandle(forWritingTo: logURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                Self.systemLogger.error("Failed writing file log: \(error.localizedDescription)")
            }
        }
    }

    nonisolated private static func rotateIfNeededIfNeeded(at logURL: URL, maximumBytes: UInt64) {
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

@MainActor
func logDebug(_ message: String) {
    AppLogger.shared.record(message, level: .debug)
}

@MainActor
func logInfo(_ message: String) {
    AppLogger.shared.record(message, level: .info)
}

@MainActor
func logWarning(_ message: String) {
    AppLogger.shared.record(message, level: .warning)
}

@MainActor
func logError(_ message: String) {
    AppLogger.shared.record(message, level: .error)
}
