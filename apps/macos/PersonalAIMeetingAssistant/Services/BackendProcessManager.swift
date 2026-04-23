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
    @Published var isVenvHealthy = false
    @Published var isCreatingVenv = false
    @Published var venvCreationStatus: String = ""

    private var process: Process?
    private let logger = AppLogger(category: "BackendProcess")

    /// Where the user-local venv lives — survives app updates and fixes broken bundles.
    private var localVenvDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("KlarityApp/backend-venv")
    }

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

    /// Path to the Python interpreter.
    /// Prefers the user-local venv (survives app updates), falls back to bundled venv.
    private var pythonExecutable: URL? {
        let local = localVenvDir.appendingPathComponent("bin/python")
        if FileManager.default.fileExists(atPath: local.path) {
            return local
        }
        return backendDir?.appendingPathComponent("venv/bin/python")
    }

    /// Path to the bundled requirements.txt inside the app bundle.
    private var bundledRequirements: URL? {
        backendDir?.appendingPathComponent("requirements.txt")
    }

    // MARK: - Venv Health

    /// Run a smoke test against the given Python interpreter.
    func validateVenv(at pythonPath: URL) -> Bool {
        let proc = Process()
        proc.executableURL = pythonPath
        proc.arguments = ["-c", "import fastapi, uvicorn, sqlalchemy, httpx"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let healthy = proc.terminationStatus == 0
            logger.info("Venv validation at \(pythonPath.path): \(healthy ? "healthy" : "unhealthy")")
            return healthy
        } catch {
            logger.error("Venv validation failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Check whether the currently-resolved Python interpreter is healthy.
    func checkVenvHealth() {
        guard let python = pythonExecutable else {
            isVenvHealthy = false
            return
        }
        isVenvHealthy = validateVenv(at: python)
    }

    /// Create a fresh local venv in Application Support and install requirements.
    /// Progress is reported via the `venvCreationStatus` published property.
    func createLocalVenv() async {
        guard !isCreatingVenv else { return }
        isCreatingVenv = true
        defer { isCreatingVenv = false }

        let venvDir = localVenvDir
        let fm = FileManager.default

        guard let reqPath = bundledRequirements, fm.fileExists(atPath: reqPath.path) else {
            venvCreationStatus = "Requirements file not found in bundle."
            logger.error("requirements.txt missing at \(bundledRequirements?.path ?? "nil")")
            return
        }

        guard let systemPython = findPython3() else {
            venvCreationStatus = "Python 3 not found. Install via brew install python@3.11 or python.org."
            logger.error("Python 3 not found")
            return
        }

        let logFile = venvInstallLogURL
        try? "".write(to: logFile, atomically: true, encoding: .utf8)

        // 1. Clean up any broken local venv
        venvCreationStatus = "Preparing environment…"
        if fm.fileExists(atPath: venvDir.path) {
            try? fm.removeItem(at: venvDir)
        }
        try? fm.createDirectory(at: venvDir.deletingLastPathComponent(), withIntermediateDirectories: true)

        // 2. Create venv
        venvCreationStatus = "Creating Python virtual environment…"
        let createOk = await runProcess(
            executable: systemPython,
            arguments: ["-m", "venv", venvDir.path],
            currentDirectory: nil,
            logFile: logFile
        )
        guard createOk else {
            let output = lastLines(of: logFile, count: 20)
            venvCreationStatus = "Failed to create virtual environment.\n\n\(output)"
            logger.error("venv creation failed")
            return
        }

        // 3. Upgrade pip
        venvCreationStatus = "Upgrading pip…"
        let pipPath = venvDir.appendingPathComponent("bin/pip").path
        _ = await runProcess(
            executable: pipPath,
            arguments: ["install", "--upgrade", "pip"],
            currentDirectory: nil,
            logFile: logFile
        )

        // 4. Install requirements
        venvCreationStatus = "Installing dependencies (this may take a few minutes)…"
        let installOk = await runProcess(
            executable: pipPath,
            arguments: ["install", "-r", reqPath.path],
            currentDirectory: nil,
            logFile: logFile
        )
        guard installOk else {
            let output = lastLines(of: logFile, count: 20)
            venvCreationStatus = "Failed to install dependencies.\n\n\(output)"
            logger.error("pip install failed")
            return
        }

        // 5. Validate
        venvCreationStatus = "Verifying installation…"
        let venvPython = venvDir.appendingPathComponent("bin/python")
        let healthy = validateVenv(at: venvPython)
        isVenvHealthy = healthy
        venvCreationStatus = healthy
            ? "Backend environment ready."
            : "Installation verification failed."
        logger.info("Local venv creation finished: \(healthy ? "healthy" : "unhealthy")")
    }

    private var venvInstallLogURL: URL {
        let expanded = NSString(string: "~/Documents/AI-Meetings/logs").expandingTildeInPath
        let dir = URL(fileURLWithPath: expanded)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            return dir.appendingPathComponent("venv-install.log")
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("klarity-venv-install.log")
    }

    private func findPython3() -> String? {
        let candidates = [
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
        ]
        let fm = FileManager.default
        for path in candidates {
            if fm.isExecutableFile(atPath: path) {
                return path
            }
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["which", "python3"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty,
               fm.isExecutableFile(atPath: path) {
                return path
            }
        } catch {
            logger.error("which python3 failed: \(error.localizedDescription)")
        }
        return nil
    }

    private func lastLines(of url: URL, count: Int) -> String {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        let lines = text.components(separatedBy: .newlines)
        return lines.suffix(count).joined(separator: "\n")
    }

    /// Run a process asynchronously and return whether it exited successfully.
    private func runProcess(executable: String, arguments: [String], currentDirectory: URL?, logFile: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executable)
                proc.arguments = arguments
                if let cwd = currentDirectory {
                    proc.currentDirectoryURL = cwd
                }
                proc.environment = ProcessInfo.processInfo.environment

                FileManager.default.createFile(atPath: logFile.path, contents: nil, attributes: nil)
                guard let fileHandle = try? FileHandle(forWritingTo: logFile) else {
                    continuation.resume(returning: false)
                    return
                }
                fileHandle.seekToEndOfFile()
                proc.standardOutput = fileHandle
                proc.standardError = fileHandle

                do {
                    try proc.run()
                    proc.waitUntilExit()
                    fileHandle.closeFile()
                    continuation.resume(returning: proc.terminationStatus == 0)
                } catch {
                    fileHandle.closeFile()
                    continuation.resume(returning: false)
                }
            }
        }
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
        Task { await AppState.shared?.checkBackend() }
        logger.info("Backend stopped.")
    }
}
