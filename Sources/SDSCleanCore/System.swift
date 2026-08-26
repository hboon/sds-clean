import Darwin
import Foundation

public protocol ProcessRunning: Sendable {
    func run(executable: String, arguments: [String], environment: [String: String], cwd: String) -> ProcessResult
}
public struct ProcessResult: Sendable { public let status: Int32; public let stdout: String; public let stderr: String }

public struct DirectProcessRunner: ProcessRunning {
    public init() {}
    public func run(executable: String, arguments: [String], environment: [String: String], cwd: String) -> ProcessResult {
        final class Collector: @unchecked Sendable {
            private let lock = NSLock(); private var data = Data(); private let limit = 64 * 1024
            func append(_ chunk: Data) { lock.lock(); defer { lock.unlock() }; if data.count < limit { data.append(chunk.prefix(limit - data.count)) } }
            func string() -> String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
        }
        let process = Process(); let output = Pipe(); let error = Pipe(); let outputCollector = Collector(); let errorCollector = Collector()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.environment = environment; process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = output; process.standardError = error
        output.fileHandleForReading.readabilityHandler = { handle in outputCollector.append(handle.availableData) }
        error.fileHandleForReading.readabilityHandler = { handle in errorCollector.append(handle.availableData) }
        do { try process.run(); process.waitUntilExit() } catch { return ProcessResult(status: 127, stdout: "", stderr: String(describing: error)) }
        output.fileHandleForReading.readabilityHandler = nil; error.fileHandleForReading.readabilityHandler = nil
        outputCollector.append(output.fileHandleForReading.readDataToEndOfFile()); errorCollector.append(error.fileHandleForReading.readDataToEndOfFile())
        return ProcessResult(status: process.terminationStatus, stdout: outputCollector.string(), stderr: errorCollector.string())
    }
}

public protocol Trashing: Sendable { func trash(_ url: URL) throws }
public struct FoundationTrasher: Trashing {
    public init() {}
    public func trash(_ url: URL) throws { var resulting: NSURL?; try FileManager.default.trashItem(at: url, resultingItemURL: &resulting) }
}

public func sanitizedEnvironment(home: String, executable: String? = nil, brew: Bool = false) -> [String: String] {
    let trustedBin = executable?.hasPrefix("/opt/homebrew/") == true ? "/opt/homebrew/bin:" : (executable?.hasPrefix("/usr/local/") == true ? "/usr/local/bin:" : "")
    var environment = ["HOME": home, "LANG": "C", "LC_ALL": "C", "NO_COLOR": "1", "DO_NOT_TRACK": "1", "PATH": trustedBin + "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory(), "NPM_CONFIG_AUDIT": "false", "NPM_CONFIG_FUND": "false", "NPM_CONFIG_LOGS_MAX": "0", "NPM_CONFIG_UPDATE_NOTIFIER": "false", "YARN_ENABLE_TELEMETRY": "0"]
    if brew { environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"; environment["HOMEBREW_NO_ENV_HINTS"] = "1" }
    return environment
}

public func probeEnvironment(executable: String? = nil, brew: Bool = false) -> [String: String] {
    sanitizedEnvironment(home: "/var/empty", executable: executable, brew: brew)
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
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey], options: [], errorHandler: { _, _ in true }) else { return nil }
    var total: UInt64 = 0; var count = 0
    while let url = enumerator.nextObject() as? URL {
        count += 1; if count > 250_000 { return nil }
        guard let item = try? identity(at: url), item.ownerID == ownerID, item.device == rootDevice else { enumerator.skipDescendants(); continue }
        if isSymlink(item, at: url) { continue }
        var info = stat(); guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0 else { continue }
        if (info.st_mode & S_IFMT) == S_IFREG { total &+= item.size }
    }
    return total
}
