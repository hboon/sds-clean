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
    #expect(allowedTools.first { $0.name == "SwiftPM" }!.helpArguments == ["package", "help", "purge-cache"])
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
        if arguments == ["package", "help", "purge-cache"] { return ProcessResult(status: 0, stdout: "purge-cache", stderr: "") }
        return ProcessResult(status: 9, stdout: "", stderr: "failed")
    }
    let outcomes = Executor(home: root, ownerID: geteuid(), runner: runner).execute(ExecutionPlan(candidates: [candidate]), cancellation: CancellationState())
    #expect(outcomes.first?.kind == .commandFailed); #expect(outcomes.first?.exitCode == 9)
    #expect(calls.values.last?.0 == ["package", "purge-cache"]); #expect(calls.values.allSatisfy { $0.2 == "/" })
    #expect(calls.values.last?.1["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin"); #expect(calls.values.allSatisfy { $0.1["HOME"] == root.path })
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

@Test func launcherLayoutsCoverAcceptedRealVariantsAndRejectEscapes() {
    let home = URL(fileURLWithPath: "/Users/tester")
    #expect(installationLayoutAllowed(name: "Homebrew", launcher: "/opt/homebrew/bin/brew", resolved: "/opt/homebrew/bin/brew", home: home))
    #expect(installationLayoutAllowed(name: "npm", launcher: "/usr/local/bin/npm", resolved: "/usr/local/lib/node_modules/npm/bin/npm-cli.js", home: home))
    #expect(installationLayoutAllowed(name: "Yarn Classic", launcher: "/opt/homebrew/bin/yarn", resolved: "/opt/homebrew/Cellar/yarn/1.22.22/bin/yarn", home: home))
    #expect(installationLayoutAllowed(name: "pnpm", launcher: "/Users/tester/.asdf/shims/pnpm", resolved: "/Users/tester/.asdf/shims/pnpm", home: home))
    #expect(installationLayoutAllowed(name: "pnpm", launcher: "/Users/tester/.local/share/mise/shims/pnpm", resolved: "/Users/tester/.local/share/mise/shims/pnpm", home: home))
    #expect(!installationLayoutAllowed(name: "pnpm", launcher: "/Users/tester/bin/pnpm", resolved: "/tmp/pnpm", home: home))
    #expect(!installationLayoutAllowed(name: "Homebrew", launcher: "/tmp/brew", resolved: "/opt/homebrew/bin/brew", home: home))
}

private func pnpmFixture(result: ProcessResult, cache: Bool = true, helpResult: ProcessResult = ProcessResult(status: 0, stdout: "store prune", stderr: "")) throws -> (URL, DiscoveryReport) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let shim = root.appendingPathComponent(".asdf/shims/pnpm"); try FileManager.default.createDirectory(at: shim.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: shim); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
    if cache { try FileManager.default.createDirectory(at: root.appendingPathComponent("Library/pnpm/store"), withIntermediateDirectories: true) }
    let overrides = Dictionary(uniqueKeysWithValues: allowedTools.map { ($0.executableNames[0], $0.name == "pnpm" ? [shim.path] : []) })
    let runner = FakeRunner { _, arguments, environment, _ in
        #expect(environment["HOME"] == root.path)
        #expect(environment["PATH"]?.contains("/.asdf/shims") == true)
        if arguments == ["store", "--help"] { return helpResult }
        return result
    }
    return (root, Discoverer(home: root, runner: runner, ownerID: geteuid(), executableOverrides: overrides).discover(version: "0.1.0"))
}

@Test func probeDiagnosticsSeparateFailureMalformedValidAndAbsentScope() throws {
    var fixture = try pnpmFixture(result: ProcessResult(status: 7, stdout: "", stderr: "node failed\n\u{1b}"))
    #expect(fixture.1.notices.contains { $0.contains("version probe exited 7: node failed\\u{a}\\u{1b}") }); try FileManager.default.removeItem(at: fixture.0)
    fixture = try pnpmFixture(result: ProcessResult(status: 0, stdout: "", stderr: ""))
    #expect(fixture.1.notices.contains { $0.contains("version output was not recognized (empty output)") }); try FileManager.default.removeItem(at: fixture.0)
    fixture = try pnpmFixture(result: ProcessResult(status: 0, stdout: "not-a-version", stderr: ""))
    #expect(fixture.1.notices.contains { $0.contains("version output was not recognized: not-a-version") }); try FileManager.default.removeItem(at: fixture.0)
    fixture = try pnpmFixture(result: ProcessResult(status: 0, stdout: "9.1.0", stderr: ""), helpResult: ProcessResult(status: 2, stdout: "", stderr: "unknown command"))
    #expect(fixture.1.notices.contains { $0.contains("required cleanup command is unavailable in current help") }); try FileManager.default.removeItem(at: fixture.0)
    fixture = try pnpmFixture(result: ProcessResult(status: 0, stdout: "9.1.0", stderr: ""), cache: false)
    #expect(fixture.1.notices.contains { $0.contains("nothing eligible found") }); try FileManager.default.removeItem(at: fixture.0)
    fixture = try pnpmFixture(result: ProcessResult(status: 0, stdout: "9.1.0", stderr: ""))
    #expect(fixture.1.candidates.contains { $0.name == "pnpm" }); try FileManager.default.removeItem(at: fixture.0)
}

@Test func absenceAndUnsupportedLayoutHaveTruthfulDistinctLabels() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var overrides = Dictionary(uniqueKeysWithValues: allowedTools.map { ($0.executableNames[0], [String]()) })
    var report = Discoverer(home: root, executableOverrides: overrides).discover(version: "0.1.0")
    #expect(report.notices.contains { $0.contains("executable not found in supported locations") })
    #expect(report.notices.contains { $0.contains("Downloads: unavailable or blocked by macOS privacy controls; skipped without requesting Full Disk Access or sudo") })
    let bad = root.appendingPathComponent("bin/pnpm"); try FileManager.default.createDirectory(at: bad.deletingLastPathComponent(), withIntermediateDirectories: true); try Data().write(to: bad); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bad.path)
    overrides["pnpm"] = [bad.path]; report = Discoverer(home: root, executableOverrides: overrides).discover(version: "0.1.0")
    #expect(report.notices.contains { $0.contains("pnpm: cleanup disabled — installation layout is not supported") }); try FileManager.default.removeItem(at: root)
}

@Test func downloadsAllExclusionAndExplicitConfirmationSafety() throws {
    let tool = CleanupCandidate(id: 1, name: "pnpm", mechanism: .permanentCommand, estimatedBytes: 1, scope: "/cache", status: .ready, reason: nil, command: nil, argv: nil, filePath: nil, fileIdentity: nil)
    let download = CleanupCandidate(id: 2, name: "Download: old.zip", mechanism: .moveToTrash, estimatedBytes: 1, scope: "/Downloads", status: .ready, reason: nil, command: nil, argv: nil, filePath: "/Downloads/old.zip", fileIdentity: nil)
    #expect(try parseSelection("all", candidates: [tool, download]).map(\.id) == [1])
    #expect(throws: CLIError.self) { try parseSelection("all", candidates: [download]) }
    #expect(try parseSelection("2", candidates: [tool, download]).map(\.id) == [2])
    #expect(!isAffirmativeConfirmation("")); #expect(!isAffirmativeConfirmation("n")); #expect(isAffirmativeConfirmation("yes"))
    let report = DiscoveryReport(version: "x", dryRun: true, mutationPerformed: false, downloadsTotalBytes: 1, downloadsNote: "Downloads folder is never cleared; only individually listed files can be selected and moved to Trash. 'all' excludes them.", candidates: [download], notices: [])
    #expect(renderReport(report).contains("Downloads folder is never cleared"))
}

@Test func derivedDataUsesDeterministicCalendarDaysAndRevalidates() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let parent = root.appendingPathComponent("Library/Developer/Xcode/DerivedData"); try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    let now = Date(timeIntervalSince1970: 1_767_276_000) // fixed instant
    let startToday = calendar.startOfDay(for: now); let cutoff = calendar.date(byAdding: .day, value: -1, to: startToday)!
    for (name, date) in [("today", startToday.addingTimeInterval(1)), ("yesterday", cutoff.addingTimeInterval(1)), ("old", cutoff.addingTimeInterval(-1)), ("future", now.addingTimeInterval(86_400))] {
        let child = parent.appendingPathComponent(name); try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true); try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: child.path)
    }
    let overrides = Dictionary(uniqueKeysWithValues: allowedTools.map { ($0.executableNames[0], [String]()) })
    let report = Discoverer(home: root, now: now, calendar: calendar, executableOverrides: overrides).discover(version: "x")
    let derived = report.candidates.filter { $0.name.hasPrefix("DerivedData:") }
    #expect(derived.map(\.name) == ["DerivedData: old"]); #expect(report.notices.contains { $0.contains("3 top-level item(s) modified today or yesterday excluded") })
    let discovered = try #require(derived.first); try FileManager.default.setAttributes([.modificationDate: startToday], ofItemAtPath: discovered.filePath!)
    let recentIdentity = try identity(at: URL(fileURLWithPath: discovered.filePath!))
    let candidate = CleanupCandidate(id: discovered.id, name: discovered.name, mechanism: discovered.mechanism, estimatedBytes: discovered.estimatedBytes, scope: discovered.scope, status: discovered.status, reason: discovered.reason, command: nil, argv: nil, filePath: discovered.filePath, fileIdentity: recentIdentity)
    let trasher = RecordingTrasher(); let outcomes = Executor(home: root, trasher: trasher, now: now, calendar: calendar).execute(ExecutionPlan(candidates: [candidate]), cancellation: CancellationState())
    #expect(outcomes.first?.kind == .invalidated); #expect(outcomes.first?.detail.contains("recent-modification eligibility") == true); #expect(trasher.paths.isEmpty); try FileManager.default.removeItem(at: root)
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
