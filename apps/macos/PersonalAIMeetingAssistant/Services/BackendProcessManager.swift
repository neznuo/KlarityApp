import Foundation
import os.log

/// Manages the lifecycle of the bundled Python FastAPI backend process.
///
/// The backend lives at:
///   KlarityApp.app/Contents/Resources/backend/
/// with its virtualenv at:
///   KlarityApp.app/Contents/Resources/backend/venv/
///
/// This manager spawns that process on app launch and terminates it on quit —
/// so from the user's perspective the .app file handles everything.
@MainActor
final class BackendProcessManager: ObservableObject {
    static let shared = BackendProcessManager()

    @Published var isRunning = false
    @Published var startupError: String?

    private var process: Process?
    private let logger = AppLogger(category: "BackendProcess")

    private init() {}

    // MARK: - Paths

    /// Path to the `backend/` folder inside the app bundle's Resources directory.
    private var backendDir: URL? {
        // In a built .app bundle:
        //   Bundle.main.resourceURL → .../KlarityApp.app/Contents/Resources/
        // We place the backend folder here during the Xcode Copy Files build phase.
        guard let resources = Bundle.main.resourceURL else { return nil }
        return resources.appendingPathComponent("backend")
    }

    /// Path to the Python interpreter inside the bundled virtualenv.
    private var pythonExecutable: URL? {
        backendDir?.appendingPathComponent("venv/bin/python")
    }

    // MARK: - Lifecycle

    func start() {
        guard process == nil else { return }

        guard let backendDir,
              let python = pythonExecutable else {
            startupError = "Backend bundle not found inside .app/Contents/Resources/backend/"
            logger.error("Backend directory or venv not found in bundle.")
            return
        }

        guard FileManager.default.fileExists(atPath: python.path) else {
            startupError = "Python interpreter not found at \(python.path)"
            logger.error("Python not found: \(python.path)")
            return
        }

        // Pre-flight check: aggressively nuke any ghost processes clinging to our port
        // from a previous app crash or failed termination.
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-9", "-f", "uvicorn.*8765"]
        try? pkill.run()
        pkill.waitUntilExit()

        let proc = Process()
        proc.executableURL = python
        proc.arguments = [
            "-m", "uvicorn",
            "app.main:app",
            "--host", "127.0.0.1",
            "--port", "8765",
            "--log-level", "info",
        ]
        proc.currentDirectoryURL = backendDir

        // Inherit the bundle's environment and add PYTHONPATH so imports resolve.
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = backendDir.path
        // Point to the .env file inside the backend directory (if present).
        env["DOTENV_PATH"] = backendDir.appendingPathComponent(".env").path

        // Augment PATH with Homebrew locations. macOS GUI apps inherit a minimal
        // PATH (/usr/bin:/bin:/usr/sbin:/sbin) that never includes Homebrew, so
        // ffmpeg and other tools installed via brew are invisible to shutil.which().
        //   /opt/homebrew/bin  — Apple Silicon (default since Homebrew 3.0)
        //   /usr/local/bin     — Intel Macs / legacy installs
        let homebrewPaths = "/opt/homebrew/bin:/usr/local/bin"
        let existingPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "\(homebrewPaths):\(existingPath)"

        proc.environment = env

        // Pipe stdout and stderr to a physical file to bypass macOS <private> Console logging.
        let expandedPath = NSString(string: AppSettings.default.baseStorageDir).expandingTildeInPath
        let storageDir = URL(fileURLWithPath: expandedPath)
        let logURL = storageDir.appendingPathComponent("backend.log")
        
        // Ensure the storage directory exists before trying to write the log
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: nil)
        
        if let fileHandle = try? FileHandle(forWritingTo: logURL) {
            proc.standardOutput = fileHandle
            proc.standardError = fileHandle
            logger.info("Backend logging to file: \(logURL.path)")
        } else {
            // Fallback to unified logging
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError  = errPipe
            
            outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self?.logger.info("[backend] \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
            errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self?.logger.error("[backend stderr] \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
        }

        proc.terminationHandler = { [weak self] p in
            Task { @MainActor [weak self] in
                self?.isRunning = false
                self?.process = nil
                self?.logger.warn("Backend process terminated with code \(p.terminationStatus)")
            }
        }

        do {
            try proc.run()
            process = proc
            isRunning = true
            logger.info("Backend started — PID \(proc.processIdentifier)")

            // Give uvicorn ~2 seconds to be ready before the app checks health
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await AppState.shared?.checkBackend()
            }
        } catch {
            startupError = "Failed to launch backend: \(error.localizedDescription)"
            logger.error("Failed to launch backend: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard let proc = process, proc.isRunning else { return }
        logger.info("Sending SIGTERM to backend process tree (PID \(proc.processIdentifier))...")
        
        proc.terminate() // Ask nicely first
        
        // Wait up to 2 seconds for a clean shutdown
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            proc.waitUntilExit()
            sem.signal()
        }
        
        // If it refuses to terminate linearly, drop the hammer on it and all its children
        if sem.wait(timeout: .now() + 2.0) == .timedOut {
            logger.warn("Backend did not shut down cleanly. Obliterating process tree.")
            
            // Kill all child worker threads first
            let pkill = Process()
            pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            pkill.arguments = ["-9", "-P", String(proc.processIdentifier)]
            try? pkill.run()
            pkill.waitUntilExit()
            
            // Kill the parent
            kill(proc.processIdentifier, SIGKILL)
        }
        
        // Absolute fail-safe: kill anything running uvicorn on 8765
        let pkillAll = Process()
        pkillAll.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkillAll.arguments = ["-9", "-f", "uvicorn.*8765"]
        try? pkillAll.run()
        pkillAll.waitUntilExit()
        
        process = nil
        isRunning = false
        logger.info("Backend stopped.")
    }
}
