import Darwin
import Foundation

public let isolatedYarnRCFilename = ".sds-clean-no-project-rc.yml"

public func neutralYarnConfigurationIsolated() -> Bool {
    !FileManager.default.fileExists(atPath: "/\(isolatedYarnRCFilename)") && !FileManager.default.fileExists(atPath: "/.yarnrc.yml")
}

public protocol ProcessRunning: Sendable {
    func run(executable: String, arguments: [String], environment: [String: String], cwd: String) -> ProcessResult
}
public struct ProcessResult: Sendable { public let status: Int32; public let stdout: String; public let stderr: String }

public struct DirectProcessRunner: ProcessRunning {
    public init() {}
    public func run(executable: String, arguments: [String], environment: [String: String], cwd: String) -> ProcessResult {
        final class Collector: @unchecked Sendable {
            private let lock = NSLock(); private var data = Data(); private let limit = 64 * 1024
            func drain(_ handle: FileHandle) {
                while let chunk = try? handle.read(upToCount: 8 * 1024), !chunk.isEmpty {
                    lock.lock(); if data.count < limit { data.append(chunk.prefix(limit - data.count)) }; lock.unlock()
                }
            }
            func string() -> String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
        }
        let process = Process(); let output = Pipe(); let error = Pipe(); let outputCollector = Collector(); let errorCollector = Collector()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.environment = environment; process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = output; process.standardError = error
        do { try process.run() } catch { return ProcessResult(status: 127, stdout: "", stderr: String(describing: error)) }
        let readers = DispatchGroup()
        readers.enter(); DispatchQueue.global().async { outputCollector.drain(output.fileHandleForReading); readers.leave() }
        readers.enter(); DispatchQueue.global().async { errorCollector.drain(error.fileHandleForReading); readers.leave() }
        process.waitUntilExit()
        readers.wait()
        return ProcessResult(status: process.terminationStatus, stdout: outputCollector.string(), stderr: errorCollector.string())
    }
}

public protocol Trashing: Sendable { func trash(_ url: URL) throws }
public struct FoundationTrasher: Trashing {
    public init() {}
    public func trash(_ url: URL) throws { var resulting: NSURL?; try FileManager.default.trashItem(at: url, resultingItemURL: &resulting) }
}

private func trustedNodeBin(home: String) -> String? {
    let root = URL(fileURLWithPath: home).appendingPathComponent(".asdf/installs/nodejs")
    guard let versions = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
    return versions.sorted { $0.lastPathComponent > $1.lastPathComponent }.map { $0.appendingPathComponent("bin") }.first { directory in
        var info = stat(); let node = directory.appendingPathComponent("node").path
        return node.withCString { stat($0, &info) } == 0 && (info.st_uid == 0 || info.st_uid == geteuid()) && info.st_mode & 0o002 == 0
    }?.path
}

public func sanitizedEnvironment(home: String, executable: String? = nil, brew: Bool = false) -> [String: String] {
    let trustedBin: String
    if executable?.hasPrefix("/opt/homebrew/") == true { trustedBin = "/opt/homebrew/bin:" }
    else if executable?.hasPrefix("/usr/local/") == true { trustedBin = "/usr/local/bin:" }
    else if executable?.contains("/.asdf/shims/") == true { trustedBin = home + "/.asdf/shims:" + home + "/.asdf/bin:" }
    else if executable?.contains("/.local/share/mise/shims/") == true { trustedBin = home + "/.local/share/mise/shims:" }
    else { trustedBin = "" }
    let runtimeBin = trustedNodeBin(home: home).map { $0 + ":" } ?? ""
    var environment = ["HOME": home, "LANG": "C", "LC_ALL": "C", "NO_COLOR": "1", "DO_NOT_TRACK": "1", "PATH": trustedBin + runtimeBin + "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory(), "NPM_CONFIG_AUDIT": "false", "NPM_CONFIG_FUND": "false", "NPM_CONFIG_LOGS_MAX": "0", "NPM_CONFIG_UPDATE_NOTIFIER": "false", "COREPACK_ENABLE_NETWORK": "0", "COREPACK_ENABLE_PROJECT_SPEC": "0", "YARN_ENABLE_HARDENED_MODE": "0", "YARN_ENABLE_NETWORK": "0", "YARN_ENABLE_OFFLINE_MODE": "1", "YARN_ENABLE_PROGRESS_BARS": "0", "YARN_ENABLE_SCRIPTS": "0", "YARN_ENABLE_TELEMETRY": "0", "YARN_ENABLE_TIMERS": "0", "YARN_ENABLE_TIPS": "0", "YARN_IGNORE_PATH": "1", "YARN_RC_FILENAME": isolatedYarnRCFilename]
    if brew { environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"; environment["HOMEBREW_NO_ENV_HINTS"] = "1" }
    return environment
}

public func probeEnvironment(home: String, executable: String? = nil, brew: Bool = false) -> [String: String] {
    sanitizedEnvironment(home: home, executable: executable, brew: brew)
}

public func boundedDiagnostic(_ text: String, limit: Int = 240) -> String {
    let safe = terminalSafe(text.trimmingCharacters(in: .whitespacesAndNewlines))
    return String(safe.prefix(limit))
}

public func identity(at url: URL, followSymlink: Bool = false) throws -> FileIdentity {
    var info = stat()
    let result = url.path.withCString { pointer in
        if followSymlink { return stat(pointer, &info) }
        return lstat(pointer, &info)
    }
    guard result == 0 else { throw CocoaError(.fileReadNoSuchFile) }
    return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), size: UInt64(max(0, info.st_size)), modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000), ownerID: info.st_uid)
}

public func isSymlink(_ identity: FileIdentity, at url: URL) -> Bool {
    var info = stat(); guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0 else { return true }
    return (info.st_mode & S_IFMT) == S_IFLNK
}

public func directorySize(_ root: URL, ownerID: UInt32) -> UInt64? {
    guard let rootIdentity = try? identity(at: root), rootIdentity.ownerID == ownerID, !isSymlink(rootIdentity, at: root) else { return nil }
    let rootDevice = rootIdentity.device
    var encounteredError = false
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey], options: [], errorHandler: { _, _ in encounteredError = true; return false }) else { return nil }
    var total: UInt64 = 0; var count = 0
    while let url = enumerator.nextObject() as? URL {
        count += 1; if count > 250_000 { return nil }
        guard let item = try? identity(at: url), item.ownerID == ownerID, item.device == rootDevice else { return nil }
        if isSymlink(item, at: url) { continue }
        var info = stat(); guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0 else { return nil }
        if (info.st_mode & S_IFMT) == S_IFREG { total &+= UInt64(max(0, info.st_blocks)) * 512 }
    }
    return encounteredError ? nil : total
}

public func allocatedFileSize(_ url: URL) -> UInt64? {
    var info = stat()
    guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
    return UInt64(max(0, info.st_blocks)) * 512
}
