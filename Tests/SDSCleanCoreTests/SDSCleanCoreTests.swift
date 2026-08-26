import Darwin
import Foundation
import Testing
@testable import SDSCleanCore

struct FakeRunner: ProcessRunning {
    let handler: @Sendable (String, [String], [String: String], String) -> ProcessResult
    func run(executable: String, arguments: [String], environment: [String : String], cwd: String) -> ProcessResult { handler(executable, arguments, environment, cwd) }
}

final class RecordingTrasher: Trashing, @unchecked Sendable {
    private(set) var paths: [String] = []
    func trash(_ url: URL) throws { paths.append(url.path) }
}

@Test func argumentSafety() throws {
    #expect(try parseArguments(["--json"], isTTY: false).dryRun)
    #expect(throws: CLIError.self) { try parseArguments(["--yes"], isTTY: true) }
    #expect(throws: CLIError.self) { try parseArguments(["--yes", "--select", "all"], isTTY: false) }
    #expect(throws: CLIError.self) { try parseArguments(["--dry-run", "--yes", "--select", "all"], isTTY: true) }
    #expect(!isAffirmativeConfirmation(nil)); #expect(!isAffirmativeConfirmation("")); #expect(!isAffirmativeConfirmation(" yes")); #expect(!isAffirmativeConfirmation("yes "))
    #expect(isAffirmativeConfirmation("y")); #expect(isAffirmativeConfirmation("yes")); #expect(!isAffirmativeConfirmation("YES"))
    #expect(ExitCode.success.rawValue == 0); #expect(ExitCode.usage.rawValue == 2); #expect(ExitCode.partial.rawValue == 3); #expect(ExitCode.invalidated.rawValue == 4); #expect(ExitCode.cancelled.rawValue == 130)
}

@Test func selectionIsExplicitAndBounded() throws {
    let candidates = (1...3).map { CleanupCandidate(id: $0, name: "\($0)", mechanism: .moveToTrash, estimatedBytes: 1, scope: "/tmp", status: .ready, reason: nil, command: nil, argv: nil, filePath: "/tmp/\($0)", fileIdentity: nil) }
    #expect(try parseSelection("3,1,3", candidates: candidates).map(\.id) == [1, 3])
    #expect(throws: CLIError.self) { try parseSelection("", candidates: candidates) }
    #expect(throws: CLIError.self) { try parseSelection("4", candidates: candidates) }
}

@Test func allowlistIsExactAndYarnClassicOnly() {
    #expect(allowedTools.map(\.name) == ["Homebrew", "npm", "pnpm", "Yarn Classic", "Bun", "SwiftPM", "CocoaPods"])
    let yarn = allowedTools.first { $0.name == "Yarn Classic" }!
    #expect(yarn.acceptedVersion("1.22.22")); #expect(!yarn.acceptedVersion("2.4.3")); #expect(!yarn.acceptedVersion("4.1.0"))
    #expect(allowedTools.first { $0.name == "Homebrew" }!.cleanupArguments == ["cleanup", "--prune=120"])
}

@Test func dryRunReportAndJSONDeclareZeroMutation() throws {
    let report = DiscoveryReport(version: "0.1.0", dryRun: true, mutationPerformed: false, downloadsTotalBytes: 42, downloadsNote: "mixed personal data", candidates: [], notices: [])
    #expect(renderReport(report).contains("No mutations performed."))
    let data = try JSONEncoder().encode(report); let decoded = try JSONDecoder().decode(DiscoveryReport.self, from: data)
    #expect(decoded.schemaVersion == 1); #expect(decoded.mutationPerformed == false); #expect(decoded.dryRun)
}

@Test func promoIsRestrained() {
    #expect(shouldShowPromo(isTTY: true, environment: [:], hadErrors: false, cleanedCount: 1, dryRun: false))
    #expect(!shouldShowPromo(isTTY: true, environment: ["SDS_NO_PROMO": "1"], hadErrors: false, cleanedCount: 1, dryRun: false))
    #expect(!shouldShowPromo(isTTY: false, environment: [:], hadErrors: false, cleanedCount: 1, dryRun: false))
    #expect(!shouldShowPromo(isTTY: true, environment: ["CI": "1"], hadErrors: false, cleanedCount: 1, dryRun: false))
    #expect(!shouldShowPromo(isTTY: true, environment: [:], hadErrors: true, cleanedCount: 1, dryRun: false))
}

@Test func filePlanInvalidatesOnIdentityDriftAndNeverTrashes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let downloads = root.appendingPathComponent("Downloads"); try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    let file = downloads.appendingPathComponent("old.zip"); try Data("a".utf8).write(to: file)
    let original = try identity(at: file); try Data("changed".utf8).write(to: file)
    let candidate = CleanupCandidate(id: 1, name: "old", mechanism: .moveToTrash, estimatedBytes: original.size, scope: downloads.path, status: .ready, reason: nil, command: nil, argv: nil, filePath: file.path, fileIdentity: original)
    let trasher = RecordingTrasher(); let outcomes = Executor(home: root, ownerID: original.ownerID, trasher: trasher).execute(ExecutionPlan(candidates: [candidate]), cancellation: CancellationState())
    #expect(outcomes.first?.kind == .invalidated); #expect(trasher.paths.isEmpty)
    try FileManager.default.removeItem(at: root)
}

@Test func trashAdapterIsCalledWithoutDeletionFallback() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let downloads = root.appendingPathComponent("Downloads"); try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    let file = downloads.appendingPathComponent("old.zip"); try Data("a".utf8).write(to: file); try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-31 * 86_400)], ofItemAtPath: file.path); let item = try identity(at: file)
    let candidate = CleanupCandidate(id: 1, name: "old", mechanism: .moveToTrash, estimatedBytes: item.size, scope: downloads.path, status: .ready, reason: nil, command: nil, argv: nil, filePath: file.path, fileIdentity: item)
    let trasher = RecordingTrasher(); let outcomes = Executor(home: root, ownerID: item.ownerID, trasher: trasher).execute(ExecutionPlan(candidates: [candidate]), cancellation: CancellationState())
    #expect(outcomes.first?.kind == .trashed); #expect(trasher.paths == [file.path]); #expect(FileManager.default.fileExists(atPath: file.path))
    try FileManager.default.removeItem(at: root)
}

@Test func cancellationStopsBeforeNextItem() {
    let cancellation = CancellationState(); cancellation.cancel()
    let candidate = CleanupCandidate(id: 1, name: "x", mechanism: .moveToTrash, estimatedBytes: 1, scope: "/", status: .ready, reason: nil, command: nil, argv: nil, filePath: "/no", fileIdentity: nil)
    let outcomes = Executor(home: URL(fileURLWithPath: "/tmp")).execute(ExecutionPlan(candidates: [candidate]), cancellation: cancellation)
    #expect(outcomes.first?.kind == .notRun)
}

@Test func outputIsBoundedAndTrashIsNotFreedSpace() {
    let candidates = (1...250).map { CleanupCandidate(id: $0, name: "x", mechanism: .moveToTrash, estimatedBytes: 1, scope: "/tmp", status: .ready, reason: nil, command: nil, argv: nil, filePath: "/tmp/x", fileIdentity: nil) }
    let report = DiscoveryReport(version: "0.1.0", dryRun: true, mutationPerformed: false, downloadsTotalBytes: 0, downloadsNote: "mixed", candidates: candidates, notices: Array(repeating: "notice", count: 100))
    #expect(renderReport(report).components(separatedBy: "\n").count < 1_000)
    #expect(renderPlan(ExecutionPlan(candidates: Array(candidates.prefix(1)))).contains("Move to Trash"))
    #expect(terminalSafe("bad\nname\u{1b}") == "bad\\u{a}name\\u{1b}")
}

@Test func downloadsDiscoveryEnforcesSuffixAgeTopLevelAndSymlinkRules() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let downloads = root.appendingPathComponent("Downloads"); try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    let old = Date().addingTimeInterval(-31 * 86_400)
    for name in ["eligible.ZIP", "partial.zip.download", ".hidden.dmg", "wrong.txt"] {
        let url = downloads.appendingPathComponent(name); try Data(repeating: 1, count: name == "eligible.ZIP" ? 50 : 20).write(to: url); try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
    }
    let young = downloads.appendingPathComponent("young.dmg"); try Data(repeating: 1, count: 100).write(to: young)
    let nested = downloads.appendingPathComponent("nested"); try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true); try Data(repeating: 1, count: 200).write(to: nested.appendingPathComponent("nested.zip"))
    try FileManager.default.createSymbolicLink(at: downloads.appendingPathComponent("link.iso"), withDestinationURL: downloads.appendingPathComponent("eligible.ZIP"))
    let report = Discoverer(home: root, runner: FakeRunner { _, _, _, _ in ProcessResult(status: 1, stdout: "", stderr: "") }, ownerID: geteuid()).discover(version: "0.1.0")
    let downloadsCandidates = report.candidates.filter { $0.name.hasPrefix("Download:") }
    #expect(downloadsCandidates.map(\.name) == ["Download: eligible.ZIP"])
    #expect(report.downloadsTotalBytes == 410)
    try FileManager.default.removeItem(at: root)
}

@Test func downloadsDiscoveryCapsLargestTwenty() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let downloads = root.appendingPathComponent("Downloads"); try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    let old = Date().addingTimeInterval(-31 * 86_400)
    for number in 1...25 {
        let url = downloads.appendingPathComponent("\(number).zip"); try Data(repeating: 1, count: number).write(to: url); try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
    }
    let report = Discoverer(home: root, ownerID: geteuid()).discover(version: "0.1.0")
    let sizes = report.candidates.filter { $0.name.hasPrefix("Download:") }.compactMap(\.estimatedBytes)
    #expect(sizes.count == 20); #expect(sizes.first == 25); #expect(sizes.last == 6)
    try FileManager.default.removeItem(at: root)
}

@Test func permanentCommandUsesDirectArgvNeutralCWDAndNoFallback() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = root.appendingPathComponent("Library/Caches/org.swift.swiftpm"); try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let executable = "/usr/bin/swift"; let executableIdentity = try identity(at: URL(fileURLWithPath: executable), followSymlink: true); let cacheIdentity = try identity(at: cache)
    let command = CommandIdentity(path: executable, device: executableIdentity.device, inode: executableIdentity.inode, size: executableIdentity.size, modified: executableIdentity.modified, ownerID: executableIdentity.ownerID, version: "Apple Swift version 6.2")
    let candidate = CleanupCandidate(id: 1, name: "SwiftPM", mechanism: .permanentCommand, estimatedBytes: 0, scope: cache.path, status: .ready, reason: nil, command: command, argv: [executable, "package", "purge-cache"], cacheScopes: [CacheScopeIdentity(path: cache.path, identity: cacheIdentity)], filePath: nil, fileIdentity: nil)
    final class Calls: @unchecked Sendable { var values: [([String], [String: String], String)] = [] }
    let calls = Calls()
    let runner = FakeRunner { _, arguments, environment, cwd in
        calls.values.append((arguments, environment, cwd))
        if arguments == ["--version"] { return ProcessResult(status: 0, stdout: "Apple Swift version 6.2\n", stderr: "") }
        if arguments == ["package", "--help"] { return ProcessResult(status: 0, stdout: "purge-cache", stderr: "") }
        return ProcessResult(status: 9, stdout: "", stderr: "failed")
    }
    let outcomes = Executor(home: root, ownerID: geteuid(), runner: runner).execute(ExecutionPlan(candidates: [candidate]), cancellation: CancellationState())
    #expect(outcomes.first?.kind == .commandFailed); #expect(outcomes.first?.exitCode == 9)
    #expect(calls.values.last?.0 == ["package", "purge-cache"]); #expect(calls.values.allSatisfy { $0.2 == "/" })
    #expect(calls.values.last?.1["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin"); #expect(calls.values.last?.1["HOME"] == root.path)
    #expect(calls.values.dropLast().allSatisfy { $0.1["HOME"] == "/var/empty" })
    try FileManager.default.removeItem(at: root)
}

@Test func stableJSONHasDocumentedTopLevelKeys() throws {
    let report = DiscoveryReport(version: "0.1.0", dryRun: true, mutationPerformed: false, downloadsTotalBytes: nil, downloadsNote: "mixed", candidates: [], notices: [])
    let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
    #expect(Set(object.keys) == ["schemaVersion", "version", "dryRun", "mutationPerformed", "downloadsNote", "candidates", "notices"])
}

@Test func helpDriftInvalidatesBeforeCommandExecution() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = root.appendingPathComponent("Library/Caches/org.swift.swiftpm"); try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let executable = "/usr/bin/swift"; let executableIdentity = try identity(at: URL(fileURLWithPath: executable), followSymlink: true); let cacheIdentity = try identity(at: cache)
    let candidate = CleanupCandidate(id: 1, name: "SwiftPM", mechanism: .permanentCommand, estimatedBytes: 0, scope: cache.path, status: .ready, reason: nil, command: CommandIdentity(path: executable, device: executableIdentity.device, inode: executableIdentity.inode, size: executableIdentity.size, modified: executableIdentity.modified, ownerID: executableIdentity.ownerID, version: "Apple Swift version 6.2"), argv: [executable, "package", "purge-cache"], cacheScopes: [CacheScopeIdentity(path: cache.path, identity: cacheIdentity)], filePath: nil, fileIdentity: nil)
    final class Arguments: @unchecked Sendable { var values: [[String]] = [] }
    let arguments = Arguments()
    let runner = FakeRunner { _, received, _, _ in arguments.values.append(received); return received == ["--version"] ? ProcessResult(status: 0, stdout: "Apple Swift version 6.2\n", stderr: "") : ProcessResult(status: 0, stdout: "no matching subcommand", stderr: "") }
    let outcomes = Executor(home: root, ownerID: geteuid(), runner: runner).execute(ExecutionPlan(candidates: [candidate]), cancellation: CancellationState())
    #expect(outcomes.first?.kind == .invalidated); #expect(!arguments.values.contains(["package", "purge-cache"]))
    try FileManager.default.removeItem(at: root)
}

@Test func anyPlanDriftPreventsEarlierValidTrashItem() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let downloads = root.appendingPathComponent("Downloads"); try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    func candidate(_ name: String, id: Int) throws -> CleanupCandidate {
        let file = downloads.appendingPathComponent(name); try Data("a".utf8).write(to: file); try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-31 * 86_400)], ofItemAtPath: file.path); let item = try identity(at: file)
        return CleanupCandidate(id: id, name: name, mechanism: .moveToTrash, estimatedBytes: item.size, scope: downloads.path, status: .ready, reason: nil, command: nil, argv: nil, filePath: file.path, fileIdentity: item)
    }
    let first = try candidate("first.zip", id: 1); let second = try candidate("second.zip", id: 2)
    try Data("drift".utf8).write(to: URL(fileURLWithPath: second.filePath!))
    let trasher = RecordingTrasher(); let outcomes = Executor(home: root, ownerID: geteuid(), trasher: trasher).execute(ExecutionPlan(candidates: [first, second]), cancellation: CancellationState())
    #expect(trasher.paths.isEmpty); #expect(outcomes.map(\.kind) == [.notRun, .invalidated])
    try FileManager.default.removeItem(at: root)
}
