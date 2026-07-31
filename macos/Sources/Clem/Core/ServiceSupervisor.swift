import Foundation

/// Owns child processes Clem starts (supermemory, optionally Ollama).
/// Retains Process handles so quit can terminate only what we spawned.
@MainActor
final class ServiceSupervisor {
    static let shared = ServiceSupervisor()

    private var engineProcess: Process?
    private var ollamaProcess: Process?
    private var lastAttempt = Date.distantPast
    private let throttle: TimeInterval = 30

    private init() {}

    func startIfNeeded(settings: Settings) async {
        guard settings.engineAutoStart else { return }
        guard Date().timeIntervalSince(lastAttempt) > throttle else { return }
        lastAttempt = Date()

        let sm = SupermemoryClient(baseURL: settings.supermemoryURLValue, apiKey: settings.supermemoryKey)
        if !(await sm.isUp()) {
            let cwd = resolvedEngineWorkdir(settings)
            if !cwd.isEmpty {
                engineProcess = spawn(
                    binary: settings.engineBinary,
                    args: [],
                    cwd: cwd,
                    logName: "engine.log",
                    replacing: engineProcess
                )
            }
        }

        if settings.llmProviderValue == .ollama {
            let ollama = OllamaClient(baseURL: settings.ollamaURLValue, model: settings.ollamaModel)
            if !(await ollama.isUp()),
               let bin = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]
                   .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                // Only adopt-spawn if nothing answers on the port — never kill a
                // pre-existing user ollama instance on shutdown.
                ollamaProcess = spawn(
                    binary: bin,
                    args: ["serve"],
                    cwd: nil,
                    logName: "ollama.log",
                    replacing: ollamaProcess
                )
            }
        }
    }

    func shutdown() {
        terminateOwned(&engineProcess)
        terminateOwned(&ollamaProcess)
    }

    private func resolvedEngineWorkdir(_ settings: Settings) -> String {
        if !settings.engineWorkdir.isEmpty {
            return (settings.engineWorkdir as NSString).expandingTildeInPath
        }
        // Default: Application Support so the engine never depends on repo cwd.
        let dir = Store.dataDir.appendingPathComponent("engine", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func spawn(
        binary: String,
        args: [String],
        cwd: String?,
        logName: String,
        replacing old: Process?
    ) -> Process? {
        if let old, old.isRunning { return old }

        let path = (binary as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        if let cwd, !cwd.isEmpty {
            proc.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        }

        let logs = Store.dataDir.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let logURL = logs.appendingPathComponent(logName)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            proc.standardOutput = handle
            proc.standardError = handle
        }

        proc.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                guard let self else { return }
                if self.engineProcess === finished { self.engineProcess = nil }
                if self.ollamaProcess === finished { self.ollamaProcess = nil }
            }
        }

        do {
            try proc.run()
            return proc
        } catch {
            NSLog("Clem: failed to spawn \(path): \(error.localizedDescription)")
            return nil
        }
    }

    private func terminateOwned(_ slot: inout Process?) {
        guard let proc = slot, proc.isRunning else {
            slot = nil
            return
        }
        proc.terminate()
        let deadline = Date().addingTimeInterval(2)
        while proc.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            proc.interrupt()
        }
        slot = nil
    }
}
