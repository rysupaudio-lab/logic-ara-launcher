// Native app and CLI: no Python, compiler or Apple binaries in the distribution.
import AppKit
import CryptoKit
import Darwin

let launcherVersion = "0.2.0-candidate.2"
let enginePath = "Contents/Frameworks/MAAudioEngine.framework/Versions/A/MAAudioEngine"
let corePath = "Contents/Frameworks/MACore.framework/Versions/A/MACore"
let executablePath = "Contents/MacOS/Logic Pro"
let engineHash = "f1ec685f407cd8a9ec73d3e94cdf3f7929bdcaa2168f221913c950bae76fec24"
let coreHash = "331ce81830f253f3d47f9a219264a51c92bd1d66f03cafd166f04a8b5d6a745b"
let executableHash = "f55166a726ba181ce8abc2c068ad9ef7f4e39eb2dbb45be85fbd6b01b6634418"
let fm = FileManager.default
struct LaunchError: LocalizedError { let message: String; var errorDescription: String? { message } }
func fail(_ message: String) -> LaunchError { LaunchError(message: message) }
func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
func digest(_ url: URL) throws -> String {
    let stream = try FileHandle(forReadingFrom: url)
    defer { try? stream.close() }
    var hash = SHA256()
    while let data = try stream.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
@discardableResult func command(_ executable: String, _ arguments: [String]) throws -> String {
    let task = Process(); task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments
    let pipe = Pipe(); task.standardOutput = pipe; task.standardError = pipe
    try task.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self)
    guard task.terminationStatus == 0 else { throw fail("\(URL(fileURLWithPath: executable).lastPathComponent) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))") }
    return output
}
func inspect(_ input: URL) throws -> [String: Any] {
    #if !arch(arm64)
    throw fail("This release requires a native Apple Silicon Mac.")
    #endif
    var translated: Int32 = 0; var size = MemoryLayout<Int32>.size
    if sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0, translated != 0 {
        throw fail("Run natively on Apple Silicon; Rosetta is unsupported.")
    }
    let app = canonical(input)
    let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
    guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          info["CFBundleIdentifier"] as? String == "com.apple.logic10",
          info["CFBundleShortVersionString"] as? String == "12.4", info["CFBundleVersion"] as? String == "6707" else {
        throw fail("Unsupported Logic installation. This candidate supports only original Apple-signed Logic Pro 12.4 (6707).")
    }
    guard try digest(app.appendingPathComponent(enginePath)) == engineHash,
          try digest(app.appendingPathComponent(corePath)) == coreHash,
          try digest(app.appendingPathComponent(executablePath)) == executableHash else { throw fail("Logic executable/framework hashes differ from the qualified build. Refusing to launch.") }
    try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    try command("/usr/bin/codesign", ["--verify", "-R=anchor apple generic and identifier \"com.apple.logic10\"", app.path])
    return ["source": app.path, "version": "12.4", "build": "6707", "engine_sha256": engineHash,
            "macore_sha256": coreHash, "executable_sha256": executableHash]
}
let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
func unregister(_ app: URL) { _ = try? command(lsregister, ["-u", app.path]) }
func jsonWrite(_ value: [String: Any], _ path: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: path, options: .atomic)
}
func childAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
func processesUsing(_ executable: URL) throws -> [Int32] {
    // Launch Services (or a user) can start another process from the same copy.
    // A recorded child exiting is insufficient permission to delete that copy.
    let estimate = proc_listallpids(nil, 0)
    guard estimate > 0 else { throw fail("Could not inspect live processes; private copy preserved.") }
    var pids = [Int32](repeating: 0, count: min(65536, max(4096, Int(estimate) * 2 + 256)))
    let found = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    guard found > 0, found < pids.count else { throw fail("Could not complete live-process inspection; private copy preserved.") }
    let expected = canonical(executable).path
    return pids.prefix(Int(found)).filter { pid in
        guard pid > 0 else { return false }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN)) // PROC_PIDPATHINFO_MAXSIZE
        let size = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        return size > 0 && canonical(URL(fileURLWithPath: String(cString: path))).path == expected
    }.sorted()
}
final class OwnedChild {
    private(set) var processIdentifier: Int32 = 0
    private(set) var terminationStatus: Int32 = 0
    private var finished = false
    init(executable: URL, arguments: [String], environment: [String: String], directory: URL, console: FileHandle) throws {
        var actions: posix_spawn_file_actions_t?; var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, console.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, console.fileDescriptor, STDERR_FILENO)
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        // A terminal interrupt to the launcher must never terminate the user's Logic session.
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        var envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        let result = argv.withUnsafeMutableBufferPointer { av in envp.withUnsafeMutableBufferPointer { ev in
            posix_spawn(&processIdentifier, executable.path, &actions, &attributes, av.baseAddress!, ev.baseAddress!)
        } }
        guard result == 0 else { throw fail("Could not start the private Logic copy: \(String(cString: strerror(result)))") }
    }
    var isRunning: Bool {
        guard !finished else { return false }
        var status: Int32 = 0
        let result = waitpid(processIdentifier, &status, WNOHANG)
        if result == 0 || (result < 0 && errno == EINTR) { return true }
        if result < 0 { return childAlive(processIdentifier) }
        finished = true
        terminationStatus = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return false
    }
    func waitUntilExit() { while isRunning { Thread.sleep(forTimeInterval: 0.2) } }
}
func cleanupFinishedSession(_ cache: URL) throws -> String {
    let lock = cache.appendingPathComponent("active.lock")
    guard fm.fileExists(atPath: lock.path) else { return "There is no previous session to clean." }
    guard canonical(lock) == lock else { throw fail("The session lock is a symlink. Preserve it for manual review.") }
    let owner = try JSONSerialization.jsonObject(with: Data(contentsOf: lock.appendingPathComponent("owner.json"))) as? [String: Any]
    guard let path = owner?["session"] as? String else { throw fail("The previous session receipt is missing. Preserve the cache for manual review.") }
    let manifest = canonical(URL(fileURLWithPath: path)); let runs = canonical(cache.appendingPathComponent("runs"))
    guard manifest.lastPathComponent == "session.json", manifest.deletingLastPathComponent().deletingLastPathComponent() == runs else { throw fail("The previous session receipt is outside this launcher's runs directory.") }
    var receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any] ?? [:]
    let app = manifest.deletingLastPathComponent().appendingPathComponent("Logic Pro.app")
    guard receipt["owned_app"] as? String == app.path,
          receipt["run_directory"] as? String == manifest.deletingLastPathComponent().path else { throw fail("The previous receipt does not identify this exact private app. Preserve it for manual review.") }
    // Any live PID is a refusal, including PID reuse. Never adopt or signal it.
    for key in ["launcher_pid", "pid"] {
        let value = key == "launcher_pid" ? owner?[key] : receipt[key]
        if let pid = value as? Int32, pid != getpid(), childAlive(pid) { throw fail("A previous launcher or Logic PID is still alive. Quit that session normally before cleanup.") }
    }
    let liveCopies = try processesUsing(app.appendingPathComponent(executablePath))
    guard liveCopies.isEmpty else { throw fail("Processes \(liveCopies) still use this private Logic copy. Quit them normally before cleanup.") }
    if fm.fileExists(atPath: app.path) {
        guard canonical(app).path == app.standardizedFileURL.path,
              try app.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw fail("The previous app path is a symlink. Preserve it for manual review.") }
        unregister(app); try fm.removeItem(at: app)
    }
    receipt["cleanup_pending"] = nil; receipt["status"] = "cleaned_after_exit"; try jsonWrite(receipt, manifest)
    try fm.removeItem(at: lock.appendingPathComponent("owner.json")); try fm.removeItem(at: lock)
    return "The exited session's private application copy was removed. Its diagnostics were kept."
}
final class Session {
    let cache: URL; let helper: URL
    var process: OwnedChild?
    var changed: (String) -> Void = { _ in }
    init(cache: URL, helper: URL) { self.cache = canonical(cache); self.helper = canonical(helper) }
    func launch(source: URL, project: URL?) throws {
        let source = canonical(source)
        changed("Verifying the installed Logic signature and exact build…")
        var receipt = try inspect(source)
        guard cache.path != source.path, !cache.path.hasPrefix(source.path + "/") else { throw fail("The working folder must be outside the installed Logic application.") }
        if cache.path.hasPrefix("/Volumes/") {
            let components = cache.pathComponents
            guard components.count >= 3 else { throw fail("Select a folder on a mounted working disk.") }
            let volume = "/Volumes/" + components[2]
            let mounted = fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
            guard mounted.contains(where: { canonical($0).path == canonical(URL(fileURLWithPath: volume)).path }) else { throw fail("The selected working disk is not mounted. Reconnect it before launching.") }
        }
        guard fm.fileExists(atPath: helper.path), !helper.path.contains(":") else { throw fail("The bundled native bridge is missing or its path contains a colon.") }
        let helperHash = try digest(helper)
        if let project {
            guard project.pathExtension == "logicx", fm.fileExists(atPath: project.path) else { throw fail("Choose an existing, backed-up .logicx project.") }
            guard !canonical(project).path.hasPrefix(source.path + "/") else { throw fail("Copy this project out of the installed Logic application before opening it.") }
        }
        try fm.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = cache.appendingPathComponent("active.lock")
        guard Darwin.mkdir(lock.path, 0o700) == 0 else { throw fail("A launcher session is active, or needs cleanup. Quit its Logic copy normally, then choose Clean finished session.") }
        let run = cache.appendingPathComponent("runs/\(UUID().uuidString.lowercased())")
        do { try fm.createDirectory(at: run, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { try? fm.removeItem(at: lock); throw error }
        let app = run.appendingPathComponent("Logic Pro.app"), manifest = run.appendingPathComponent("session.json")
        let log = run.appendingPathComponent("bridge.log")
        receipt.merge(["launcher_version": launcherVersion, "launcher_implementation": "native-swift", "launcher_pid": getpid(), "run_directory": run.path,
                       "owned_app": app.path, "project": project?.path as Any? ?? NSNull(), "helper_sha256": helperHash, "status": "preparing"]) { _, new in new }
        var operationError: Error?
        do {
            try jsonWrite(receipt, manifest)
            try jsonWrite(["launcher_pid": getpid(), "session": manifest.path], lock.appendingPathComponent("owner.json"))
            changed("Verifying and preparing a private Logic copy…")
            let sourceFS = try fm.attributesOfFileSystem(forPath: source.path)[.systemNumber] as? NSNumber
            let targetFS = try fm.attributesOfFileSystem(forPath: run.path)[.systemNumber] as? NSNumber
            if sourceFS != nil && sourceFS == targetFS {
                receipt["copy_strategy"] = "same_filesystem_clone_request"
                try command("/bin/cp", ["-cR", source.path, app.path])
            } else {
                receipt["copy_strategy"] = "cross_filesystem_signature_preserving_copy"
                changed("Copying Logic to the selected working disk and verifying its original signature…")
                try command("/usr/bin/ditto", ["--rsrc", "--extattr", source.path, app.path])
            }
            let copy = try inspect(app)
            for key in ["engine_sha256", "macore_sha256", "executable_sha256"] {
                guard copy[key] as? String == receipt[key] as? String else { throw fail("Private copy failed verification.") }
            }
            unregister(app)
            var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") }
            env.merge(["DYLD_INSERT_LIBRARIES": helper.path, "LOGIC_ARA_APP_PATH": app.path, "LOGIC_ARA_LOG_PATH": log.path,
                       "LOGIC_ARA_PROJECT_PATH": project?.path ?? "", "LOGIC_ARA_PARENT_PID": String(getpid()),
                       "LOGIC_ARA_PREFERENCES_DOMAIN": "org.rysupaudio.logic-ara-launcher"]) { _, new in new }
            let consoleURL = run.appendingPathComponent("console.log"); fm.createFile(atPath: consoleURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let console = try FileHandle(forWritingTo: consoleURL); defer { try? console.close() }
            let task = try OwnedChild(executable: app.appendingPathComponent(executablePath),
                                      arguments: (project.map { [$0.path] } ?? []) + ["-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO"], environment: env, directory: run, console: console)
            process = task
            receipt["pid"] = task.processIdentifier; receipt["process_group"] = getpgid(task.processIdentifier); receipt["status"] = "starting"; try jsonWrite(receipt, manifest)
            changed("Starting the private Logic copy and waiting for its ARA bridge…")
            // First launch may validate tens of thousands of bundle resources
            // and update a large AU catalog before our constructor can run.
            let deadline = ProcessInfo.processInfo.systemUptime + 180
            var ready = false
            while ProcessInfo.processInfo.systemUptime < deadline {
                let content = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                if content.contains("bridge_refused") { throw fail("The bridge refused this process. See \(run.path).") }
                if content.contains("bridge_ready") { ready = true; break }
                guard task.isRunning else { throw fail("The private Logic copy exited before bridge startup. See \(run.path).") }
                Thread.sleep(forTimeInterval: 0.2)
            }
            guard ready else { throw fail("Bridge startup was not confirmed. Any live Logic copy is preserved. See \(run.path).") }
            receipt["status"] = "running"; try jsonWrite(receipt, manifest); unregister(app)
            changed("ARA bridge ready. Use the visible Logic copy normally. Quit that copy when finished.\nDiagnostics: \(run.path)")
            print("Private Logic PID \(task.processIdentifier). Diagnostics: \(run.path)")
            while task.isRunning {
                if receipt["ara_runtime_compatible"] as? Bool != false,
                   let handle = try? FileHandle(forReadingFrom: log) {
                    let size = (try? handle.seekToEnd()) ?? 0
                    try? handle.seek(toOffset: size > 8192 ? size - 8192 : 0)
                    let tail = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
                    try? handle.close()
                    if tail.contains("bridge_runtime_degraded") {
                        receipt["ara_runtime_compatible"] = false
                        receipt["runtime_warning"] = "ARA compatibility check failed; save your work, remove the affected insert and restart before further ARA editing. Live Logic is preserved."
                        try jsonWrite(receipt, manifest)
                        changed("ARA compatibility check failed. Logic remains open so you can save your work. Follow its compatibility alert, then restart before further ARA editing.\nDiagnostics: \(run.path)")
                    }
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            receipt["status"] = "exited"; receipt["exit_code"] = task.terminationStatus
        } catch {
            operationError = error; receipt["status"] = "failed"; receipt["error"] = error.localizedDescription
        }
        // Preserve every live child; a startup PID is never permission to kill a user session.
        var liveCopies: [Int32] = []
        var processInspectionFailed = false
        do { liveCopies = try processesUsing(app.appendingPathComponent(executablePath)) }
        catch { receipt["cleanup_error"] = error.localizedDescription; operationError = error; processInspectionFailed = true }
        let alive = process?.isRunning == true || !liveCopies.isEmpty || processInspectionFailed
        if alive {
            receipt["status"] = "detached"; receipt["cleanup_pending"] = "A process may still use this private copy; application and lock preserved."
            receipt["live_copy_pids"] = liveCopies
            if operationError == nil { operationError = fail("Another live process uses the private Logic copy. Quit it normally, then use Clean finished session.") }
        } else {
            if fm.fileExists(atPath: app.path) {
                do {
                    guard canonical(app).path == app.standardizedFileURL.path,
                          try app.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw fail("Private app path changed; copy and lock preserved for review.") }
                    unregister(app); try fm.removeItem(at: app)
                } catch { receipt["cleanup_error"] = error.localizedDescription; operationError = error }
            }
            if receipt["cleanup_error"] == nil {
                try? fm.removeItem(at: lock.appendingPathComponent("owner.json")); try? fm.removeItem(at: lock)
            }
        }
        do {
            let after = try inspect(source)
            receipt["source_unchanged"] = ["engine_sha256", "macore_sha256", "executable_sha256"].allSatisfy { after[$0] as? String == receipt[$0] as? String }
            if receipt["source_unchanged"] as? Bool != true { throw fail("Post-run source verification failed.") }
        } catch { receipt["source_unchanged"] = false; receipt["source_verification_error"] = error.localizedDescription; operationError = error }
        try jsonWrite(receipt, manifest)
        if let operationError { throw operationError }
        changed("Logic exited. Private copy removed and original installation verified unchanged.\nDiagnostics: \(run.path)")
    }
}
func defaultCache() -> URL {
    if let path = ProcessInfo.processInfo.environment["LOGIC_ARA_CACHE_ROOT"], path.hasPrefix("/") { return canonical(URL(fileURLWithPath: path)) }
    return fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/LogicARALauncher")
}
func bundledHelper() -> URL { Bundle.main.resourceURL!.appendingPathComponent("native/LogicARABridge.dylib") }
final class LauncherDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!; var status: NSTextField!; var buttons: [NSButton] = []; var busy = false; var session: Session?
    var source = URL(fileURLWithPath: "/Applications/Logic Pro.app")
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(); let appItem = NSMenuItem(); menu.addItem(appItem)
        let submenu = NSMenu(); submenu.addItem(withTitle: "Quit Logic ARA Launcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); appItem.submenu = submenu; NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 380), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Logic ARA Launcher"; window.delegate = self; window.center(); window.isReleasedWhenClosed = false
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14; stack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "Native ARA 2 • Logic Pro 12.4 (6707)"); title.font = .boldSystemFont(ofSize: 20); stack.addArrangedSubview(title)
        let intro = NSTextField(wrappingLabelWithString: "Experimental candidate. Launches an unchanged private copy of your licensed Logic. Use backed-up projects. Your installed Logic stays untouched. Third-party plug-in licenses are required."); stack.addArrangedSubview(intro)
        for (label, action) in [("Launch Logic", #selector(launchEmpty)), ("Open a backed-up project…", #selector(openProject)), ("Check compatibility…", #selector(check)), ("Choose Logic application…", #selector(chooseLogic)), ("Clean finished session", #selector(cleanup))] {
            let button = NSButton(title: label, target: self, action: action); buttons.append(button); stack.addArrangedSubview(button)
        }
        status = NSTextField(wrappingLabelWithString: "Ready. Keep this launcher open while using its Logic copy."); status.font = .systemFont(ofSize: 12); stack.addArrangedSubview(status)
        window.contentView!.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)])
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func alert(_ text: String) { let alert = NSAlert(); alert.messageText = "Logic ARA Launcher"; alert.informativeText = text; alert.runModal() }
    @objc func chooseLogic() { let panel = NSOpenPanel(); panel.title = "Select your licensed Logic Pro application"; panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowedContentTypes = [.applicationBundle]; if panel.runModal() == .OK, let url = panel.url { source = canonical(url); status.stringValue = "Selected: \(source.path)" } }
    func work(_ block: @escaping () throws -> String) {
        guard !busy else { return }; busy = true; buttons.forEach { $0.isEnabled = false }
        DispatchQueue.global(qos: .userInitiated).async {
            var message: String
            do { message = try block() } catch { message = error.localizedDescription }
            DispatchQueue.main.async { self.status.stringValue = message; self.busy = false; self.buttons.forEach { $0.isEnabled = true } }
        }
    }
    @objc func check() { work { _ = try inspect(self.source); return "Compatible: Logic Pro 12.4 (6707), exact framework hashes and original Apple signature verified." } }
    @objc func cleanup() { work { try cleanupFinishedSession(defaultCache()) } }
    @objc func launchEmpty() { start(nil) }
    @objc func openProject() {
        let panel = NSOpenPanel(); panel.title = "Select a backed-up .logicx project"; panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.treatsFilePackagesAsDirectories = false
        if panel.runModal() == .OK, let url = panel.url { guard url.pathExtension == "logicx" else { alert("Select a .logicx project."); return }; start(canonical(url)) }
    }
    func start(_ project: URL?) {
        guard fm.fileExists(atPath: source.path) else { chooseLogic(); return }
        let session = Session(cache: defaultCache(), helper: bundledHelper()); self.session = session
        session.changed = { [weak self] text in DispatchQueue.main.async { self?.status.stringValue = text } }
        work { try session.launch(source: self.source, project: project); return self.statusText() }
    }
    func statusText() -> String { "Logic exited. Private copy removed and original installation verified unchanged. Diagnostics: \(defaultCache().path)." }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if busy {
            let alert = NSAlert(); alert.messageText = "Keep the launcher running?"; alert.informativeText = "Leaving now preserves any running Logic copy and its session lock. Quit that Logic copy normally, then use Clean finished session next time."; alert.addButton(withTitle: "Keep launcher running"); alert.addButton(withTitle: "Leave Logic open and quit launcher")
            return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
        }
        return .terminateNow
    }
}
var args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args == ["--gui"] {
    let app = NSApplication.shared; let delegate = LauncherDelegate(); app.delegate = delegate; app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
} else {
    do {
        var source = URL(fileURLWithPath: "/Applications/Logic Pro.app"), project: URL?, cache = defaultCache(); var check = false, cleanup = false
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--version": print(launcherVersion); exit(0)
            case "--check": check = true
            case "--cleanup": cleanup = true
            case "--logic", "--cache":
                guard !args.isEmpty else { throw fail("\(arg) requires a path.") }; let path = URL(fileURLWithPath: args.removeFirst()); if arg == "--logic" { source = path } else { cache = path }
            default: guard !arg.hasPrefix("-"), project == nil else { throw fail("Unknown argument: \(arg)") }; project = canonical(URL(fileURLWithPath: arg))
            }
        }
        if check { let data = try JSONSerialization.data(withJSONObject: inspect(source), options: [.prettyPrinted, .sortedKeys]); print(String(decoding: data, as: UTF8.self)) }
        else if cleanup { print(try cleanupFinishedSession(canonical(cache))) }
        else { try Session(cache: cache, helper: bundledHelper()).launch(source: source, project: project) }
    } catch { fputs("Logic ARA Launcher: \(error.localizedDescription)\n", stderr); exit(1) }
}
