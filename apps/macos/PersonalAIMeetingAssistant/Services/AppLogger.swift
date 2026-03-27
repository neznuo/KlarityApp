import Foundation
import os.log

/// Combined logger that mirrors messages to both os_log (for Console)
/// and a persistent logfile under ~/Documents/AI-Meetings/logs/app.log.
struct AppLogger {
    enum Level: String {
        case debug = "DEBUG"
        case info  = "INFO"
        case warn  = "WARN"
        case error = "ERROR"
    }

    private let category: String
    private let osLogger: Logger

    init(category: String) {
        self.category = category
        self.osLogger = Logger(subsystem: "com.klarity.meeting-assistant", category: category)
    }

    func debug(_ message: String) {
        osLogger.debug("\(message)")
        LogFileSink.shared.write(level: .debug, category: category, message: message)
    }

    func info(_ message: String) {
        osLogger.info("\(message)")
        LogFileSink.shared.write(level: .info, category: category, message: message)
    }

    func warn(_ message: String) {
        osLogger.warning("\(message)")
        LogFileSink.shared.write(level: .warn, category: category, message: message)
    }

    func error(_ message: String) {
        osLogger.error("\(message)")
        LogFileSink.shared.write(level: .error, category: category, message: message)
    }
}

// MARK: - File sink

final class LogFileSink {
    static let shared = LogFileSink()

    private let queue = DispatchQueue(label: "com.klarity.logfilesink")
    private var fileHandle: FileHandle?
    private let logURL: URL
    private let formatter: ISO8601DateFormatter

    var currentLogURL: URL { logURL }

    private init() {
        let basePath = NSString(string: AppSettings.default.baseStorageDir).expandingTildeInPath
        let logsDir = URL(fileURLWithPath: basePath).appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let url = logsDir.appendingPathComponent("app.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        logURL = url
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        fileHandle = try? FileHandle(forWritingTo: logURL)
        try? fileHandle?.seekToEnd()
    }

    func write(level: AppLogger.Level, category: String, message: String) {
        queue.async {
            do {
                if self.fileHandle == nil {
                    self.fileHandle = try FileHandle(forWritingTo: self.logURL)
                    try self.fileHandle?.seekToEnd()
                }
                guard let handle = self.fileHandle else { return }
                try handle.seekToEnd()
                let timestamp = self.formatter.string(from: Date())
                let line = "[\(timestamp)] [\(level.rawValue)] [\(category)] \(message)\n"
                if let data = line.data(using: .utf8) {
                    handle.write(data)
                }
            } catch {
                // If writing fails, reset the handle so a future attempt can reopen it.
                self.fileHandle = nil
            }
        }
    }
}
