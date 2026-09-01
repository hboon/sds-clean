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

final class SelectiveTrasher: Trashing, @unchecked Sendable {
    private(set) var paths: [String] = []
    let failingName: String
    init(failingName: String) { self.failingName = failingName }
    func trash(_ url: URL) throws {
        paths.append(url.path)
        if url.lastPathComponent == failingName { throw CocoaError(.fileWriteUnknown) }
    }
}

private func trashFixture(id: Int, name: String, bytes: UInt64?, scope: String, filePath: String?, fileIdentity: FileIdentity? = nil) -> CleanupCandidate {
    CleanupCandidate(id: id, name: name, mechanism: .moveToTrash, currentScopeBytes: bytes, estimatedReclaimBytes: nil, trashMoveBytes: bytes, estimateBasis: "test Trash size", scope: scope, status: .ready, reason: nil, command: nil, argv: nil, filePath: filePath, fileIdentity: fileIdentity)
}

private func toolFixture(id: Int, name: String, bytes: UInt64?, scope: String, command: CommandIdentity? = nil, argv: [String]? = nil, cacheScopes: [CacheScopeIdentity]? = nil) -> CleanupCandidate {
    CleanupCandidate(id: id, name: name, mechanism: .permanentCommand, currentScopeBytes: bytes, estimatedReclaimBytes: bytes, trashMoveBytes: nil, estimateBasis: "test reclaim estimate", scope: scope, status: .ready, reason: nil, command: command, argv: argv, cacheScopes: cacheScopes, filePath: nil, fileIdentity: nil)
}

@Test func argumentSafety() throws {
    #expect(try parseArguments([], isTTY: false) == CLIOptions())
    #expect(try parseArguments(["--json"], isTTY: false).dryRun)
    #expect(try parseArguments(["--delete"], isTTY: true).delete)
    #expect(throws: CLIError.self) { try parseArguments(["--yes"], isTTY: true) }
    #expect(throws: CLIError.self) { try parseArguments(["--delete", "--yes", "--select", "all"], isTTY: false) }
    #expect(throws: CLIError.self) { try parseArguments(["--yes", "--select", "all"], isTTY: true) }
    #expect(throws: CLIError.self) { try parseArguments(["--dry-run", "--delete"], isTTY: true) }
    #expect(throws: CLIError.self) { try parseArguments(["--dry-run", "--json"], isTTY: false) }
    #expect(throws: CLIError.self) { try parseArguments(["--help", "--dry-run"], isTTY: false) }
    #expect(throws: CLIError.self) { try parseArguments(["--delete", "--yes"], isTTY: true) }
    #expect(throws: CLIError.self) { try parseArguments(["--delete", "--select", "all"], isTTY: true) }
    #expect(modeSummary.components(separatedBy: "\n").count == 3); #expect(modeSummary.contains("--dry-run")); #expect(modeSummary.contains("--delete"))
    #expect(!isAffirmativeConfirmation(nil)); #expect(!isAffirmativeConfirmation("")); #expect(!isAffirmativeConfirmation(" yes")); #expect(!isAffirmativeConfirmation("yes "))
    #expect(isAffirmativeConfirmation("y")); #expect(isAffirmativeConfirmation("yes")); #expect(!isAffirmativeConfirmation("YES"))
    #expect(ExitCode.success.rawValue == 0); #expect(ExitCode.usage.rawValue == 2); #expect(ExitCode.partial.rawValue == 3); #expect(ExitCode.invalidated.rawValue == 4); #expect(ExitCode.cancelled.rawValue == 130)
}

@Test func allowlistPreservesYarnClassicAndAddsModernGlobalOnly() {
    #expect(allowedTools.map(\.name) == ["Homebrew", "npm", "pnpm", "Yarn Classic", "Yarn global cache", "Bun", "SwiftPM", "CocoaPods"])
    let yarn = allowedTools.first { $0.name == "Yarn Classic" }!
    #expect(yarn.acceptedVersion("1.22.22")); #expect(!yarn.acceptedVersion("2.4.3")); #expect(!yarn.acceptedVersion("4.1.0"))
    let modern = allowedTools.first { $0.name == "Yarn global cache" }!
    #expect(!modern.acceptedVersion("1.22.22")); #expect(modern.acceptedVersion("2.4.3")); #expect(modern.acceptedVersion("3.8.7")); #expect(modern.acceptedVersion("4.18.0"))
    #expect(modern.cleanupArguments == ["cache", "clean", "--mirror"])
    #expect(modern.cacheLocationArguments == ["config", "get", "globalFolder"])
    #expect(allowedTools.first { $0.name == "Homebrew" }!.cleanupArguments == ["cleanup", "--prune=120"])
    #expect(allowedTools.first { $0.name == "SwiftPM" }!.helpArguments == ["package", "help", "purge-cache"])
}

private func modernYarnFixture(
    version: String = "4.18.0",
    help: ProcessResult = ProcessResult(status: 0, stdout: "--mirror  Remove the global cache files instead of the local cache files", stderr: ""),
    globalFolderPath: String? = nil,
    makeGlobalFolder: Bool = true,
    symlinkGlobalFolder: Bool = false,
    ownerID: UInt32 = geteuid()
) throws -> (URL, DiscoveryReport, [[String]], [[String: String]]) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let folder = root.appendingPathComponent(".yarn/berry")
    let launcher = root.appendingPathComponent("trusted/bin/yarn")
    try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true); try Data().write(to: launcher); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
    if makeGlobalFolder {
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        if symlinkGlobalFolder { try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: root.appendingPathComponent("elsewhere")) }
        else { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); try Data(repeating: 1, count: 17).write(to: folder.appendingPathComponent("cache-entry.zip")) }
    }
    final class Calls: @unchecked Sendable { var arguments: [[String]] = []; var environments: [[String: String]] = [] }
    let calls = Calls()
    let runner = FakeRunner { _, arguments, environment, cwd in
        #expect(cwd == "/"); calls.arguments.append(arguments); calls.environments.append(environment)
        switch arguments {
        case ["--version"]: return ProcessResult(status: 0, stdout: version, stderr: "")
        case ["cache", "clean", "--help"]: return help
        case ["config", "get", "globalFolder"]: return ProcessResult(status: 0, stdout: (globalFolderPath ?? folder.path) + "\n", stderr: "")
        default: return ProcessResult(status: 1, stdout: "", stderr: "unexpected")
        }
    }
    var overrides = Dictionary(uniqueKeysWithValues: allowedTools.map { ($0.executableNames[0], [String]()) })
    overrides["yarn-modern"] = [launcher.path]
    let report = Discoverer(home: root, runner: runner, ownerID: ownerID, executableOverrides: overrides, installationValidator: { name, candidate, resolved, _ in name == "Yarn global cache" && candidate == launcher.path && resolved == launcher.path }).discover(version: "test")
    return (root, report, calls.arguments, calls.environments)
}

@Test func modernYarnDiscoveryIsGlobalOnlyOfflineAndUnestimated() throws {
    let fixture = try modernYarnFixture()
    defer { try? FileManager.default.removeItem(at: fixture.0) }
    let candidate = try #require(fixture.1.candidates.first { $0.name == "Yarn global cache" })
    #expect(candidate.scope == fixture.0.appendingPathComponent(".yarn/berry").path)
    #expect(candidate.argv == [fixture.0.appendingPathComponent("trusted/bin/yarn").path, "cache", "clean", "--mirror"])
    #expect(candidate.currentScopeBytes == directorySize(fixture.0.appendingPathComponent(".yarn/berry"), ownerID: geteuid()))
    #expect(candidate.estimatedReclaimBytes == nil)
    #expect(!fixture.2.contains(["cache", "clean", "--mirror"]))
    #expect(fixture.3.allSatisfy { $0["YARN_ENABLE_NETWORK"] == "0" && $0["YARN_ENABLE_TELEMETRY"] == "0" && $0["YARN_IGNORE_PATH"] == "1" && $0["YARN_RC_FILENAME"] == isolatedYarnRCFilename && $0["COREPACK_ENABLE_NETWORK"] == "0" })
}

@Test func modernYarnRequiresExactMirrorHelpOption() throws {
    #expect(helpAdvertisesExactOption("--mirror, remove global", option: "--mirror"))
    #expect(!helpAdvertisesExactOption("--mirrorish remove global", option: "--mirror"))
    let fixture = try modernYarnFixture(help: ProcessResult(status: 0, stdout: "--all --mirrorish", stderr: ""))
    defer { try? FileManager.default.removeItem(at: fixture.0) }
    #expect(!fixture.1.candidates.contains { $0.name == "Yarn global cache" })
    #expect(fixture.1.notices.contains { $0.contains("Yarn global cache: cleanup disabled — required cleanup command is unavailable") })
}

@Test func modernYarnNeverSelectsProjectCacheOrZeroInstallsArtifacts() throws {
    let fixture = try modernYarnFixture()
    defer { try? FileManager.default.removeItem(at: fixture.0) }
    let project = fixture.0.appendingPathComponent("project")
    for relative in [".yarn/cache/zero-install.zip", ".yarn/unplugged/pkg/data", ".yarn/install-state.gz"] {
        let file = project.appendingPathComponent(relative); try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true); try Data([1]).write(to: file)
    }
    let candidate = try #require(fixture.1.candidates.first { $0.name == "Yarn global cache" })
    #expect(candidate.cacheScopes?.allSatisfy { !$0.path.hasPrefix(project.path + "/") } == true)
    #expect(candidate.argv?.contains("--all") == false)
}

@Test func modernYarnFailsClosedForUnsafeGlobalFolders() throws {
    var fixture = try modernYarnFixture(globalFolderPath: "/tmp/yarn-global", makeGlobalFolder: false)
    #expect(!fixture.1.candidates.contains { $0.name == "Yarn global cache" }); try FileManager.default.removeItem(at: fixture.0)
    fixture = try modernYarnFixture(makeGlobalFolder: true, symlinkGlobalFolder: true)
    #expect(!fixture.1.candidates.contains { $0.name == "Yarn global cache" }); try FileManager.default.removeItem(at: fixture.0)
    fixture = try modernYarnFixture(makeGlobalFolder: false)
    #expect(!fixture.1.candidates.contains { $0.name == "Yarn global cache" }); try FileManager.default.removeItem(at: fixture.0)
    fixture = try modernYarnFixture(ownerID: 0)
    #expect(!fixture.1.candidates.contains { $0.name == "Yarn global cache" }); try FileManager.default.removeItem(at: fixture.0)
}

@Test func modernYarnRefusesCorepackAndProjectLocalLaunchersWithoutPathLeak() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for relative in [".asdf/shims/yarn", "project/.yarn/releases/yarn-4.18.0.cjs"] {
        let launcher = root.appendingPathComponent(relative); try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true); try Data().write(to: launcher); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        var overrides = Dictionary(uniqueKeysWithValues: allowedTools.map { ($0.executableNames[0], [String]()) }); overrides["yarn-modern"] = [launcher.path]
        let report = Discoverer(home: root, executableOverrides: overrides).discover(version: "test")
        #expect(!report.candidates.contains { $0.name == "Yarn global cache" })
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!json.contains(launcher.path)); #expect(json.contains("installation layout is not supported"))
    }
}

@Test func modernYarnActionValidationDetectsVersionPathAndIdentityDriftAndUsesDirectArgv() throws {
    let fixture = try modernYarnFixture()
    defer { try? FileManager.default.removeItem(at: fixture.0) }
    let candidate = try #require(fixture.1.candidates.first { $0.name == "Yarn global cache" })
    final class Calls: @unchecked Sendable { var arguments: [[String]] = [] }
    func runner(version: String = "4.18.0", folder: String? = nil, calls: Calls = Calls()) -> (FakeRunner, Calls) {
        let fake = FakeRunner { _, arguments, environment, cwd in
            #expect(cwd == "/"); #expect(environment["YARN_ENABLE_NETWORK"] == "0"); calls.arguments.append(arguments)
            switch arguments {
            case ["--version"]: return ProcessResult(status: 0, stdout: version, stderr: "")
            case ["cache", "clean", "--help"]: return ProcessResult(status: 0, stdout: "--mirror Remove global cache", stderr: "")
            case ["config", "get", "globalFolder"]: return ProcessResult(status: 0, stdout: (folder ?? candidate.scope) + "\n", stderr: "")
            case ["cache", "clean", "--mirror"]: return ProcessResult(status: 0, stdout: "", stderr: "")
            default: return ProcessResult(status: 1, stdout: "", stderr: "unexpected")
            }
        }
        return (fake, calls)
    }
    var pair = runner(version: "4.18.1")
    let acceptFixtureYarn: @Sendable (String, String, String, URL) -> Bool = { name, candidatePath, resolved, _ in name == "Yarn global cache" && candidatePath == candidate.command?.path && resolved == candidate.command?.path }
    #expect(Executor(home: fixture.0, runner: pair.0, installationValidator: acceptFixtureYarn).execute(ExecutionPlan(candidates: [candidate]), cancellation: CancellationState()).first?.kind == .invalidated)
    #expect(!pair.1.arguments.contains(["cache", "clean", "--mirror"]))
    let changed = fixture.0.appendingPathComponent(".yarn/changed"); try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: true)
    pair = runner(folder: changed.path)
    #expect(Executor(home: fixture.0, runner: pair.0, installationValidator: acceptFixtureYarn).execute(ExecutionPlan(candidates: [candidate]), cancellation: CancellationState()).first?.detail == "configured cache scope changed")
    #expect(!pair.1.arguments.contains(["cache", "clean", "--mirror"]))
    let scope = try #require(candidate.cacheScopes?.first)
    let wrongMountIdentity = FileIdentity(device: scope.identity.device &+ 1, inode: scope.identity.inode, size: scope.identity.size, modified: scope.identity.modified, ownerID: scope.identity.ownerID)
    let wrongMount = CleanupCandidate(id: candidate.id, name: candidate.name, mechanism: candidate.mechanism, currentScopeBytes: candidate.currentScopeBytes, estimatedReclaimBytes: candidate.estimatedReclaimBytes, trashMoveBytes: candidate.trashMoveBytes, estimateBasis: candidate.estimateBasis, scope: candidate.scope, status: candidate.status, reason: candidate.reason, command: candidate.command, argv: candidate.argv, cacheScopes: [CacheScopeIdentity(path: scope.path, identity: wrongMountIdentity)], filePath: nil, fileIdentity: nil)
    pair = runner()
    #expect(Executor(home: fixture.0, runner: pair.0, installationValidator: acceptFixtureYarn).execute(ExecutionPlan(candidates: [wrongMount]), cancellation: CancellationState()).first?.detail == "cache scope identity, ownership, mount, or containment changed")
    #expect(!pair.1.arguments.contains(["cache", "clean", "--mirror"]))
    let originalFolder = fixture.0.appendingPathComponent(".yarn/berry"); let movedFolder = fixture.0.appendingPathComponent(".yarn/berry-old")
    try FileManager.default.moveItem(at: originalFolder, to: movedFolder); try FileManager.default.createDirectory(at: originalFolder, withIntermediateDirectories: true)
    pair = runner()
    #expect(Executor(home: fixture.0, runner: pair.0, installationValidator: acceptFixtureYarn).execute(ExecutionPlan(candidates: [candidate]), cancellation: CancellationState()).first?.kind == .invalidated)
    #expect(!pair.1.arguments.contains(["cache", "clean", "--mirror"]))

    let refreshedFixture = try modernYarnFixture(); defer { try? FileManager.default.removeItem(at: refreshedFixture.0) }
    let refreshed = try #require(refreshedFixture.1.candidates.first { $0.name == "Yarn global cache" }); pair = runner(folder: refreshed.scope)
    let acceptRefreshedYarn: @Sendable (String, String, String, URL) -> Bool = { name, candidatePath, resolved, _ in name == "Yarn global cache" && candidatePath == refreshed.command?.path && resolved == refreshed.command?.path }
    let outcome = try #require(Executor(home: refreshedFixture.0, runner: pair.0, installationValidator: acceptRefreshedYarn).execute(ExecutionPlan(candidates: [refreshed]), cancellation: CancellationState()).first)
    #expect(outcome.kind == .commandSucceeded); #expect(pair.1.arguments.last == ["cache", "clean", "--mirror"])
    #expect(FileManager.default.fileExists(atPath: refreshedFixture.0.appendingPathComponent(".yarn/berry/cache-entry.zip").path))
}

@Test func yarnClassicAndModernAliasesDeduplicateIdenticalCommandOwnedScope() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); let cache = root.appendingPathComponent("shared-yarn-cache")
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
    let launcher = root.appendingPathComponent("trusted/bin/yarn"); try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true); try Data().write(to: launcher); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
    final class State: @unchecked Sendable { var versionCalls = 0 }
    let state = State()
    let runner = FakeRunner { _, arguments, _, _ in
        if arguments == ["--version"] { state.versionCalls += 1; return ProcessResult(status: 0, stdout: state.versionCalls == 1 ? "1.22.19" : "4.18.0", stderr: "") }
        if arguments == ["cache", "--help"] { return ProcessResult(status: 0, stdout: "cache clean", stderr: "") }
        if arguments == ["cache", "dir"] { return ProcessResult(status: 0, stdout: cache.path + "\n", stderr: "") }
        if arguments == ["cache", "clean", "--help"] { return ProcessResult(status: 0, stdout: "--mirror Remove global cache", stderr: "") }
        if arguments == ["config", "get", "globalFolder"] { return ProcessResult(status: 0, stdout: cache.path + "\n", stderr: "") }
        return ProcessResult(status: 1, stdout: "", stderr: "unexpected")
    }
    var overrides = Dictionary(uniqueKeysWithValues: allowedTools.map { ($0.executableNames[0], [String]()) })
    overrides["yarn"] = [launcher.path]; overrides["yarn-modern"] = [launcher.path]
    let report = Discoverer(home: root, runner: runner, executableOverrides: overrides, installationValidator: { _, candidate, resolved, _ in candidate == launcher.path && resolved == launcher.path }).discover(version: "test")
    #expect(report.candidates.filter { $0.scope == cache.path }.count == 1)
    #expect(report.notices.contains { $0.contains("duplicate command-owned cache scope") })
}

@Test func pnpmContractRemainsPruneOnlyAndUnestimated() throws {
    let pnpm = try #require(allowedTools.first { $0.name == "pnpm" })
    #expect(pnpm.cleanupArguments == ["store", "prune"])
    if case .unavailable = pnpm.estimate {} else { Issue.record("pnpm estimate must remain unavailable") }
    #expect(pnpm.cachePaths == ["Library/pnpm/store", ".local/share/pnpm/store"])
}

@Test func commandReportedCacheScopesAreExactAndContained() throws {
    let home = URL(fileURLWithPath: "/Users/tester")
    let npm = try #require(allowedTools.first { $0.name == "npm" })
    let yarn = try #require(allowedTools.first { $0.name == "Yarn Classic" })
    let runner = FakeRunner { _, arguments, _, cwd in
        #expect(cwd == "/")
        if arguments == ["config", "get", "cache"] { return ProcessResult(status: 0, stdout: "/Users/tester/.npm\n", stderr: "") }
        if arguments == ["cache", "dir"] { return ProcessResult(status: 0, stdout: "/Users/tester/Library/Caches/Yarn/v6\n", stderr: "") }
        return ProcessResult(status: 1, stdout: "", stderr: "unexpected")
    }
    #expect(resolvedCachePaths(for: npm, executable: "/usr/local/bin/npm", runner: runner, environment: [:], home: home)?.map(\.path) == ["/Users/tester/.npm/_cacache"])
    #expect(resolvedCachePaths(for: yarn, executable: "/opt/homebrew/bin/yarn", runner: runner, environment: [:], home: home)?.map(\.path) == ["/Users/tester/Library/Caches/Yarn/v6"])
    let escaping = FakeRunner { _, _, _, _ in ProcessResult(status: 0, stdout: "/tmp/cache\n", stderr: "") }
    #expect(resolvedCachePaths(for: npm, executable: "/usr/local/bin/npm", runner: escaping, environment: [:], home: home) == nil)
}

@Test func allocatedDirectorySizeDoesNotFollowSymlinkMembers() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("data"); try Data(repeating: 1, count: 10).write(to: file)
    #expect(directorySize(root, ownerID: geteuid()) == allocatedFileSize(file))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: file)
    #expect(directorySize(root, ownerID: geteuid()) == allocatedFileSize(file))
    try FileManager.default.removeItem(at: root)
}

@Test func downloadsOutputDistinguishesEligibleFromWholeFolderUsageWithoutPaths() throws {
    let candidate = CleanupCandidate(id: 1, name: "Downloads", mechanism: .moveToTrash, currentScopeBytes: 20_914_176, totalScopeBytes: 216_190_976, estimatedReclaimBytes: nil, trashMoveBytes: 20_914_176, estimateBasis: "393 eligible items", scope: "/Users/private/Downloads", status: .ready, reason: nil, command: nil, argv: nil, filePath: nil, fileIdentity: nil, eligibleItemCount: 393, eligibleItemBytes: 20_914_176)
    let report = DiscoveryReport(version: "x", dryRun: true, mutationPerformed: false, candidates: [candidate], notices: [])
    let output = renderReport(report)
    #expect(output.contains("- Downloads: 20.9 MB eligible (206.2 MB total)"))
    #expect(!output.contains("/Users/private")); #expect(!output.contains("393"))
    let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
    #expect(json.contains("\"totalScopeBytes\":216190976")); #expect(!json.contains("secret-member.zip"))
}

@Test func dryRunReportAndJSONDeclareZeroMutation() throws {
    let report = DiscoveryReport(version: "0.1.0", dryRun: true, mutationPerformed: false, candidates: [], notices: [])
    #expect(renderReport(report).hasSuffix("This is a dry run; no files will be deleted."))
    let data = try JSONEncoder().encode(report); let decoded = try JSONDecoder().decode(DiscoveryReport.self, from: data)
    #expect(decoded.schemaVersion == 5); #expect(decoded.mutationPerformed == false); #expect(decoded.dryRun)
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
    let candidate = trashFixture(id: 1, name: "old", bytes: original.size, scope: downloads.path, filePath: file.path, fileIdentity: original)
    let trasher = RecordingTrasher(); let outcomes = Executor(home: root, ownerID: original.ownerID, trasher: trasher).execute(ExecutionPlan(candidates: [candidate]), cancellation: CancellationState())
    #expect(outcomes.first?.kind == .invalidated); #expect(trasher.paths.isEmpty)
    try FileManager.default.removeItem(at: root)
}

@Test func trashAdapterIsCalledWithoutDeletionFallback() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let downloads = root.appendingPathComponent("Downloads"); try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    let file = downloads.appendingPathComponent("old.zip"); try Data("a".utf8).write(to: file); try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-31 * 86_400)], ofItemAtPath: file.path); let item = try identity(at: file)
    let candidate = trashFixture(id: 1, name: "old", bytes: item.size, scope: downloads.path, filePath: file.path, fileIdentity: item)
    let trasher = RecordingTrasher(); let outcomes = Executor(home: root, ownerID: item.ownerID, trasher: trasher).execute(ExecutionPlan(candidates: [candidate]), cancellation: CancellationState())
    #expect(outcomes.first?.kind == .trashed); #expect(trasher.paths == [file.path]); #expect(FileManager.default.fileExists(atPath: file.path))
    try FileManager.default.removeItem(at: root)
}

@Test func cancellationStopsBeforeNextItem() {
    let cancellation = CancellationState(); cancellation.cancel()
    let candidate = trashFixture(id: 1, name: "x", bytes: 1, scope: "/", filePath: "/no")
    let outcomes = Executor(home: URL(fileURLWithPath: "/tmp")).execute(ExecutionPlan(candidates: [candidate]), cancellation: cancellation)
    #expect(outcomes.first?.kind == .notRun)
}

@Test func outputIsBoundedAndTrashIsNotFreedSpace() {
    let candidates = (1...250).map { trashFixture(id: $0, name: "x", bytes: 1, scope: "/tmp", filePath: "/tmp/x") }
    let report = DiscoveryReport(version: "0.1.0", dryRun: true, mutationPerformed: false, candidates: candidates, notices: Array(repeating: "notice", count: 100))
    #expect(renderReport(report).components(separatedBy: "\n").count < 1_000)
    #expect(renderPlan(ExecutionPlan(candidates: Array(candidates.prefix(1)))).contains("Move to Trash"))
    #expect(renderReport(report).contains("you can undo by restoring from Trash"))
    #expect(!renderReport(report).contains("total size"))
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
    let downloadsCandidates = report.candidates.filter { $0.name == "Downloads" }
    #expect(downloadsCandidates.count == 1)
    #expect(downloadsCandidates.first?.status == .ready); #expect(downloadsCandidates.first?.mechanism == .moveToTrash)
    #expect(downloadsCandidates.first?.currentScopeBytes == allocatedFileSize(downloads.appendingPathComponent("eligible.ZIP")))
    #expect(downloadsCandidates.first?.eligibleItemCount == 1)
    #expect(downloadsCandidates.first?.eligibleItemBytes == allocatedFileSize(downloads.appendingPathComponent("eligible.ZIP")))
    #expect(downloadsCandidates.first?.totalScopeBytes == directorySize(downloads, ownerID: geteuid()))
    #expect(!renderReport(report).contains("eligible.ZIP"))
    #expect(!String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("eligible.ZIP"))
    let aggregate = try #require(downloadsCandidates.first); let trasher = RecordingTrasher()
    let outcome = try #require(Executor(home: root, ownerID: geteuid(), trasher: trasher).execute(ExecutionPlan(candidates: [aggregate]), cancellation: CancellationState()).first)
    #expect(outcome.kind == .trashed); #expect(outcome.succeededItemCount == 1); #expect(trasher.paths.map { URL(fileURLWithPath: $0).lastPathComponent } == ["eligible.ZIP"])
    #expect(!trasher.paths.contains { URL(fileURLWithPath: $0).lastPathComponent == "Downloads" })
    try Data(repeating: 2, count: 51).write(to: downloads.appendingPathComponent("eligible.ZIP"))
    let driftTrasher = RecordingTrasher(); let driftOutcome = try #require(Executor(home: root, ownerID: geteuid(), trasher: driftTrasher).execute(ExecutionPlan(candidates: [aggregate]), cancellation: CancellationState()).first)
    #expect(driftOutcome.kind == .invalidated); #expect(driftTrasher.paths.isEmpty)
    try FileManager.default.removeItem(at: root)
}

@Test func downloadsDiscoveryIsOneAggregateWithoutItemNames() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let downloads = root.appendingPathComponent("Downloads"); try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    let old = Date().addingTimeInterval(-31 * 86_400)
    for number in 1...25 {
        let url = downloads.appendingPathComponent("\(number).zip"); try Data(repeating: 1, count: number).write(to: url); try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
    }
    let report = Discoverer(home: root, ownerID: geteuid()).discover(version: "0.1.0")
    let downloadRows = report.candidates.filter { $0.name == "Downloads" }
    #expect(downloadRows.count == 1); #expect(downloadRows.first?.eligibleItemCount == 25)
    #expect(downloadRows.first?.status == .ready); #expect(downloadRows.first?.mechanism == .moveToTrash)
    #expect(!renderReport(report).contains("25.zip")); #expect(!renderReport(report).contains("1.zip"))
    try FileManager.default.removeItem(at: root)
}

@Test func permanentCommandUsesDirectArgvNeutralCWDAndNoFallback() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = root.appendingPathComponent("Library/Caches/org.swift.swiftpm"); try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let executable = "/usr/bin/swift"; let executableIdentity = try identity(at: URL(fileURLWithPath: executable), followSymlink: true); let cacheIdentity = try identity(at: cache)
    let command = CommandIdentity(path: executable, device: executableIdentity.device, inode: executableIdentity.inode, size: executableIdentity.size, modified: executableIdentity.modified, ownerID: executableIdentity.ownerID, version: "Apple Swift version 6.2")
    let candidate = toolFixture(id: 1, name: "SwiftPM", bytes: 0, scope: cache.path, command: command, argv: [executable, "package", "purge-cache"], cacheScopes: [CacheScopeIdentity(path: cache.path, identity: cacheIdentity)])
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
    let report = DiscoveryReport(version: "0.1.0", dryRun: true, mutationPerformed: false, candidates: [], notices: [])
    let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
    #expect(Set(object.keys) == ["schemaVersion", "version", "dryRun", "mutationPerformed", "estimatedPermanentReclaimBytes", "unestimatedPermanentCandidateCount", "plannedTrashBytes", "unestimatedTrashSelectionCount", "candidates", "notices"])
}

@Test func stableJSONMatchesExactSnapshot() throws {
    let report = DiscoveryReport(version: "0.1.0", dryRun: true, mutationPerformed: false, candidates: [], notices: [])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let snapshot = String(decoding: try encoder.encode(report), as: UTF8.self)
    #expect(snapshot == #"{"candidates":[],"dryRun":true,"estimatedPermanentReclaimBytes":0,"mutationPerformed":false,"notices":[],"plannedTrashBytes":0,"schemaVersion":5,"unestimatedPermanentCandidateCount":0,"unestimatedTrashSelectionCount":0,"version":"0.1.0"}"#)
}

@Test func acceptedSwiftPMPlanDoesNotReprobeHelpBeforeCommandExecution() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = root.appendingPathComponent("Library/Caches/org.swift.swiftpm"); try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = "/usr/bin/swift"; let executableIdentity = try identity(at: URL(fileURLWithPath: executable), followSymlink: true); let cacheIdentity = try identity(at: cache)
    let candidate = toolFixture(id: 1, name: "SwiftPM", bytes: 0, scope: cache.path, command: CommandIdentity(path: executable, device: executableIdentity.device, inode: executableIdentity.inode, size: executableIdentity.size, modified: executableIdentity.modified, ownerID: executableIdentity.ownerID, version: "Apple Swift version 6.2"), argv: [executable, "package", "purge-cache"], cacheScopes: [CacheScopeIdentity(path: cache.path, identity: cacheIdentity)])
    final class Arguments: @unchecked Sendable { var values: [[String]] = [] }
    let arguments = Arguments()
    let runner = FakeRunner { _, received, _, _ in
        arguments.values.append(received)
        if received == ["--version"] { return ProcessResult(status: 0, stdout: "Apple Swift version 6.2\n", stderr: "") }
        if received == ["package", "help", "purge-cache"] { return ProcessResult(status: 1, stdout: "", stderr: "error: unknown option") }
        if received == ["package", "purge-cache"] { return ProcessResult(status: 0, stdout: "", stderr: "") }
        return ProcessResult(status: 1, stdout: "", stderr: "unexpected")
    }
    let outcome = try #require(Executor(home: root, ownerID: geteuid(), runner: runner).execute(ExecutionPlan(candidates: [candidate]), cancellation: CancellationState()).first)
    #expect(outcome.kind == .commandSucceeded)
    #expect(arguments.values.contains(["package", "purge-cache"]))
    #expect(!arguments.values.contains(["package", "help", "purge-cache"]))
}

@Test func unchangedSwiftPMAndTrashAggregateProceedWithoutExecutionTimeHelpProbe() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = root.appendingPathComponent("Library/Caches/org.swift.swiftpm")
    let downloads = root.appendingPathComponent("Downloads")
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = downloads.appendingPathComponent("old.zip"); try Data([1]).write(to: archive)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-31 * 86_400)], ofItemAtPath: archive.path)
    let executable = "/usr/bin/swift"; let executableIdentity = try identity(at: URL(fileURLWithPath: executable), followSymlink: true)
    let swiftPM = toolFixture(id: 1, name: "SwiftPM", bytes: 0, scope: cache.path, command: CommandIdentity(path: executable, device: executableIdentity.device, inode: executableIdentity.inode, size: executableIdentity.size, modified: executableIdentity.modified, ownerID: executableIdentity.ownerID, version: "Apple Swift version 6.2"), argv: [executable, "package", "purge-cache"], cacheScopes: [CacheScopeIdentity(path: cache.path, identity: try identity(at: cache))])
    let memberIdentity = try identity(at: archive)
    let downloadsCandidate = CleanupCandidate(id: 2, name: "Downloads", mechanism: .moveToTrash, currentScopeBytes: memberIdentity.size, estimatedReclaimBytes: nil, trashMoveBytes: memberIdentity.size, estimateBasis: "1 eligible item", scope: downloads.path, status: .ready, reason: nil, command: nil, argv: nil, cacheScopes: nil, filePath: nil, fileIdentity: nil, eligibleItemCount: 1, eligibleItemBytes: memberIdentity.size, executionMembers: [TrashMember(path: archive.path, identity: memberIdentity, bytes: memberIdentity.size)])
    final class Arguments: @unchecked Sendable { var values: [[String]] = [] }
    let arguments = Arguments(); let trasher = RecordingTrasher()
    let runner = FakeRunner { _, received, _, _ in
        arguments.values.append(received)
        if received == ["--version"] { return ProcessResult(status: 0, stdout: "Apple Swift version 6.2\n", stderr: "") }
        if received == ["package", "purge-cache"] { return ProcessResult(status: 0, stdout: "", stderr: "") }
        return ProcessResult(status: 1, stdout: "", stderr: "execution-time help probe would fail")
    }
    let outcomes = Executor(home: root, ownerID: geteuid(), runner: runner, trasher: trasher).execute(ExecutionPlan(candidates: [swiftPM, downloadsCandidate]), cancellation: CancellationState())
    #expect(outcomes.map(\.kind) == [.commandSucceeded, .trashed])
    #expect(arguments.values.contains(["package", "purge-cache"]))
    #expect(!arguments.values.contains(["package", "help", "purge-cache"]))
    #expect(trasher.paths == [archive.path])
    #expect(outcomes[1].detail.contains("moved separately to Trash"))
}

@Test func configuredCacheScopeDriftInvalidatesBeforeCleanup() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let original = root.appendingPathComponent(".npm/_cacache"); let changed = root.appendingPathComponent("other/_cacache")
    try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: true)
    let executable = "/usr/bin/true"; let executableIdentity = try identity(at: URL(fileURLWithPath: executable), followSymlink: true)
    let scopeIdentity = try identity(at: original)
    let candidate = CleanupCandidate(id: 1, name: "npm", mechanism: .permanentCommand, currentScopeBytes: 0, estimatedReclaimBytes: 0, trashMoveBytes: nil, estimateBasis: "test", scope: original.path, status: .ready, reason: nil, command: CommandIdentity(path: executable, device: executableIdentity.device, inode: executableIdentity.inode, size: executableIdentity.size, modified: executableIdentity.modified, ownerID: executableIdentity.ownerID, version: "8.18.0"), argv: [executable, "cache", "clean", "--force"], cacheScopes: [CacheScopeIdentity(path: original.path, identity: scopeIdentity)], filePath: nil, fileIdentity: nil)
    final class Calls: @unchecked Sendable { var cleanupRan = false }
    let calls = Calls()
    let runner = FakeRunner { _, arguments, _, cwd in
        #expect(cwd == "/")
        if arguments == ["--version"] { return ProcessResult(status: 0, stdout: "8.18.0\n", stderr: "") }
        if arguments == ["cache", "--help"] { return ProcessResult(status: 0, stdout: "cache clean", stderr: "") }
        if arguments == ["config", "get", "cache"] { return ProcessResult(status: 0, stdout: changed.deletingLastPathComponent().path + "\n", stderr: "") }
        calls.cleanupRan = true; return ProcessResult(status: 0, stdout: "", stderr: "")
    }
    let outcome = try #require(Executor(home: root, ownerID: geteuid(), runner: runner, installationValidator: { _, candidatePath, resolved, _ in candidatePath == executable && resolved == executable }).execute(ExecutionPlan(candidates: [candidate]), cancellation: CancellationState()).first)
    #expect(outcome.kind == .invalidated); #expect(outcome.detail == "configured cache scope changed"); #expect(!calls.cleanupRan)
    try FileManager.default.removeItem(at: root)
}

@Test func launcherLayoutsCoverAcceptedRealVariantsAndRejectEscapes() {
    let home = URL(fileURLWithPath: "/Users/tester")
    #expect(installationLayoutAllowed(name: "Homebrew", launcher: "/opt/homebrew/bin/brew", resolved: "/opt/homebrew/bin/brew", home: home))
    #expect(installationLayoutAllowed(name: "npm", launcher: "/usr/local/bin/npm", resolved: "/usr/local/lib/node_modules/npm/bin/npm-cli.js", home: home))
    #expect(installationLayoutAllowed(name: "Yarn Classic", launcher: "/opt/homebrew/bin/yarn", resolved: "/opt/homebrew/Cellar/yarn/1.22.22/bin/yarn", home: home))
    #expect(installationLayoutAllowed(name: "Yarn global cache", launcher: "/usr/bin/yarn", resolved: "/usr/bin/yarn", home: home))
    #expect(!installationLayoutAllowed(name: "Yarn global cache", launcher: "/opt/homebrew/bin/yarn", resolved: "/opt/homebrew/lib/node_modules/corepack/dist/yarn.js", home: home))
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

@Test func completePlanHasNoPartialSelectionSurface() throws {
    #expect(!isAffirmativeConfirmation("")); #expect(!isAffirmativeConfirmation("n")); #expect(isAffirmativeConfirmation("yes"))
    #expect(throws: CLIError.self) { try parseArguments(["--delete", "--select", "1"], isTTY: true) }
    #expect(throws: CLIError.self) { try parseArguments(["--delete", "--yes"], isTTY: true) }
}

@Test func dryRunAndDeleteRenderTheSamePlanBody() {
    let candidate = CleanupCandidate(id: 1, name: "Downloads", mechanism: .moveToTrash, currentScopeBytes: 42, estimatedReclaimBytes: nil, trashMoveBytes: 42, estimateBasis: "2 eligible files", scope: "/Downloads", status: .ready, reason: nil, command: nil, argv: nil, filePath: nil, fileIdentity: nil, eligibleItemCount: 2, eligibleItemBytes: 42)
    let report = DiscoveryReport(version: "x", dryRun: true, mutationPerformed: false, candidates: [candidate], notices: [])
    let dryLines = renderReport(report, dryRun: true).components(separatedBy: "\n")
    let deleteLines = renderReport(report, dryRun: false).components(separatedBy: "\n")
    #expect(Array(dryLines.dropLast(2)) == deleteLines)
    #expect(dryLines.first == "Estimated disk cleanup: 42 bytes")
    #expect(dryLines.last == "This is a dry run; no files will be deleted.")
}

@Test func humanOutputOnlyShowsCompactCleanupEstimates() {
    let candidate = CleanupCandidate(id: 1, name: "Homebrew", mechanism: .permanentCommand, currentScopeBytes: 298_500_000, estimatedReclaimBytes: 346_100_000, trashMoveBytes: nil, estimateBasis: "reported by brew cleanup --prune=120 --dry-run", scope: "/Users/test/Library/Caches/Homebrew", status: .ready, reason: nil, command: nil, argv: ["/opt/homebrew/bin/brew", "cleanup", "--prune=120"], filePath: nil, fileIdentity: nil)
    let output = renderReport(DiscoveryReport(version: "x", dryRun: true, mutationPerformed: false, candidates: [candidate], notices: []))
    #expect(output.contains("- Homebrew: 346.1 MB"))
    #expect(!output.contains("| estimate:"))
    for hidden in ["298.5 MB", "measured", "estimate basis", "/Users/test", "/opt/homebrew", "argv", "formula versions"] {
        #expect(!output.contains(hidden))
    }
}

@Test func homebrewDryRunParserIsStrictAndUsesDecimalUnits() {
    #expect(parseHomebrewReclaimBytes("Would free: 298.5MB.") == 298_500_000)
    #expect(parseHomebrewReclaimBytes("This operation would free approximately 346.1MB of disk space.") == 346_100_000)
    #expect(parseHomebrewReclaimBytes("Removing x\nWould free: 4.14 GB\n") == 4_140_000_000)
    #expect(parseHomebrewReclaimBytes("cache scope is 298.5 MB") == nil)
}

@Test func totalsSeparatePermanentReclaimTrashAndUnknownEstimates() {
    let known = CleanupCandidate(id: 1, name: "npm", mechanism: .permanentCommand, currentScopeBytes: 30, estimatedReclaimBytes: 20, trashMoveBytes: nil, estimateBasis: "full", scope: "/cache", status: .ready, reason: nil, command: nil, argv: nil, filePath: nil, fileIdentity: nil)
    let unknown = CleanupCandidate(id: 2, name: "pnpm", mechanism: .permanentCommand, currentScopeBytes: 40, estimatedReclaimBytes: nil, trashMoveBytes: nil, estimateBasis: "unknown", scope: "/store", status: .ready, reason: nil, command: nil, argv: nil, filePath: nil, fileIdentity: nil)
    let trash = CleanupCandidate(id: 3, name: "DerivedData: old", mechanism: .moveToTrash, currentScopeBytes: 10, estimatedReclaimBytes: nil, trashMoveBytes: 10, estimateBasis: "trash", scope: "/DerivedData", status: .ready, reason: nil, command: nil, argv: nil, filePath: "/DerivedData/old", fileIdentity: nil)
    let unknownTrash = CleanupCandidate(id: 4, name: "DerivedData: unreadable", mechanism: .moveToTrash, currentScopeBytes: nil, estimatedReclaimBytes: nil, trashMoveBytes: nil, estimateBasis: "unknown", scope: "/DerivedData", status: .ready, reason: nil, command: nil, argv: nil, filePath: "/DerivedData/unreadable", fileIdentity: nil)
    let report = DiscoveryReport(version: "x", dryRun: true, mutationPerformed: false, candidates: [known, unknown, trash, unknownTrash], notices: [])
    #expect(report.estimatedPermanentReclaimBytes == 20); #expect(report.unestimatedPermanentCandidateCount == 1); #expect(report.plannedTrashBytes == 10); #expect(report.unestimatedTrashSelectionCount == 1)
    let output = renderReport(report)
    #expect(output.contains("Estimated disk cleanup: 30 bytes plus items with unavailable estimates"))
    #expect(output.contains("Permanent: 20 bytes")); #expect(output.contains("Move to Trash: 10 bytes"))
    #expect(output.contains("- npm: 20 bytes")); #expect(output.contains("- pnpm: estimate unavailable"))
    #expect(output.contains("- DerivedData: old: 10 bytes")); #expect(output.contains("- DerivedData: unreadable: estimate unavailable"))
    #expect(!output.contains("| estimate:"))
    #expect(output.contains("you can undo by restoring from Trash"))
}

@Test func compactHumanPlanMatchesRequiredStructureAndHidesDiagnostics() {
    let candidates = [
        CleanupCandidate(id: 1, name: "Homebrew", mechanism: .permanentCommand, currentScopeBytes: 1, estimatedReclaimBytes: 346_100_000, trashMoveBytes: nil, estimateBasis: "private basis", scope: "/private/homebrew", status: .ready, reason: nil, command: nil, argv: ["/private/brew", "cleanup"], filePath: nil, fileIdentity: nil),
        CleanupCandidate(id: 2, name: "npm", mechanism: .permanentCommand, currentScopeBytes: 2, estimatedReclaimBytes: 29_470_000_000, trashMoveBytes: nil, estimateBasis: "private basis", scope: "/private/npm", status: .ready, reason: nil, command: nil, argv: nil, filePath: nil, fileIdentity: nil),
        CleanupCandidate(id: 3, name: "Yarn Classic", mechanism: .permanentCommand, currentScopeBytes: 3, estimatedReclaimBytes: 6_000, trashMoveBytes: nil, estimateBasis: "private basis", scope: "/private/yarn", status: .ready, reason: nil, command: nil, argv: nil, filePath: nil, fileIdentity: nil),
        CleanupCandidate(id: 4, name: "SwiftPM", mechanism: .permanentCommand, currentScopeBytes: 4, estimatedReclaimBytes: 4_140_000_000, trashMoveBytes: nil, estimateBasis: "private basis", scope: "/private/swift", status: .ready, reason: nil, command: nil, argv: nil, filePath: nil, fileIdentity: nil),
        CleanupCandidate(id: 5, name: "Xcode DerivedData", mechanism: .moveToTrash, currentScopeBytes: 16_730_000_000, estimatedReclaimBytes: nil, trashMoveBytes: 16_730_000_000, estimateBasis: "99 private members", scope: "/private/DerivedData", status: .ready, reason: nil, command: nil, argv: nil, filePath: nil, fileIdentity: nil, eligibleItemCount: 99, eligibleItemBytes: 16_730_000_000),
        CleanupCandidate(id: 6, name: "Downloads", mechanism: .moveToTrash, currentScopeBytes: 20_000_000, estimatedReclaimBytes: nil, trashMoveBytes: 20_000_000, estimateBasis: "2 private members", scope: "/private/Downloads", status: .ready, reason: nil, command: nil, argv: nil, filePath: nil, fileIdentity: nil, eligibleItemCount: 2, eligibleItemBytes: 20_000_000),
        CleanupCandidate(id: 7, name: "Disabled tool", mechanism: .permanentCommand, currentScopeBytes: nil, estimatedReclaimBytes: nil, trashMoveBytes: nil, estimateBasis: "private diagnostic", scope: "/private/disabled", status: .skipped, reason: "not eligible", command: nil, argv: nil, filePath: nil, fileIdentity: nil),
    ]
    let report = DiscoveryReport(version: "secret-version", dryRun: true, mutationPerformed: false, candidates: candidates, notices: ["private notice"])
    let expected = """
    Estimated disk cleanup: 50.71 GB
      Permanent: 33.96 GB
      Move to Trash: 16.75 GB (you can undo by restoring from Trash)

    Permanent: 33.96 GB
    - Homebrew: 346.1 MB
    - npm: 29.47 GB
    - Yarn Classic: 6 KB
    - SwiftPM: 4.14 GB

    Move to Trash: 16.75 GB
    - Xcode DerivedData: 16.73 GB
    - Downloads: 20 MB

    This is a dry run; no files will be deleted.
    """
    #expect(renderReport(report) == expected)
    #expect(!renderReport(report).contains("Disabled tool"))
    #expect(renderReport(report).components(separatedBy: "you can undo by restoring from Trash").count == 2)
    #expect(renderPlan(ExecutionPlan(candidates: candidates.filter { $0.status == .ready })) == expected.components(separatedBy: "\n\nThis is a dry run").first)
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
    let derived = report.candidates.filter { $0.name == "Xcode DerivedData" }
    #expect(derived.count == 1); #expect(derived.first?.eligibleItemCount == 1); #expect(report.notices.contains { $0.contains("3 top-level item(s) modified today or yesterday excluded") })
    let discovered = try #require(derived.first); let member = try #require(discovered.executionMembers.first)
    try FileManager.default.setAttributes([.modificationDate: startToday], ofItemAtPath: member.path)
    let recentIdentity = try identity(at: URL(fileURLWithPath: member.path))
    let candidate = CleanupCandidate(id: discovered.id, name: discovered.name, mechanism: .moveToTrash, currentScopeBytes: discovered.currentScopeBytes, estimatedReclaimBytes: nil, trashMoveBytes: discovered.trashMoveBytes, estimateBasis: discovered.estimateBasis, scope: discovered.scope, status: .ready, reason: nil, command: nil, argv: nil, filePath: nil, fileIdentity: nil, eligibleItemCount: 1, eligibleItemBytes: discovered.eligibleItemBytes, executionMembers: [TrashMember(path: member.path, identity: recentIdentity, bytes: member.bytes)])
    let trasher = RecordingTrasher(); let outcomes = Executor(home: root, trasher: trasher, now: now, calendar: calendar).execute(ExecutionPlan(candidates: [candidate]), cancellation: CancellationState())
    #expect(outcomes.first?.kind == .invalidated); #expect(outcomes.first?.detail.contains("recent-modification eligibility") == true); #expect(trasher.paths.isEmpty); try FileManager.default.removeItem(at: root)
}

@Test func derivedDataAggregateIsAuthoritativeBoundedAndMovesChildrenSeparately() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let parent = root.appendingPathComponent("Library/Developer/Xcode/DerivedData"); try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let old = Date().addingTimeInterval(-3 * 86_400)
    for name in ["alpha-secret", "beta-secret"] {
        let child = parent.appendingPathComponent(name); try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data(repeating: 1, count: name == "alpha-secret" ? 10 : 20).write(to: child.appendingPathComponent("data"))
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: child.path)
    }
    let overrides = Dictionary(uniqueKeysWithValues: allowedTools.map { ($0.executableNames[0], [String]()) })
    let report = Discoverer(home: root, executableOverrides: overrides).discover(version: "x")
    let aggregate = try #require(report.candidates.first { $0.name == "Xcode DerivedData" })
    #expect(aggregate.eligibleItemCount == 2); #expect(aggregate.trashMoveBytes == directorySize(parent, ownerID: geteuid())); #expect(aggregate.filePath == nil)
    #expect(!renderReport(report).contains("alpha-secret")); #expect(!renderPlan(ExecutionPlan(candidates: [aggregate])).contains("beta-secret"))
    let json = try JSONEncoder().encode(report); let jsonText = String(decoding: json, as: UTF8.self)
    #expect(!jsonText.contains("executionMembers")); #expect(!jsonText.contains("alpha-secret")); #expect(jsonText.contains("eligibleItemCount")); #expect(jsonText.contains("eligibleItemBytes"))
    let trasher = RecordingTrasher(); let outcomes = Executor(home: root, trasher: trasher).execute(ExecutionPlan(candidates: [aggregate]), cancellation: CancellationState())
    #expect(outcomes.count == 1); #expect(outcomes.first?.kind == .trashed); #expect(outcomes.first?.succeededItemCount == 2); #expect(outcomes.first?.failedItemCount == 0)
    #expect(Set(trasher.paths.map { URL(fileURLWithPath: $0).lastPathComponent }) == Set(["alpha-secret", "beta-secret"])); #expect(!trasher.paths.contains { URL(fileURLWithPath: $0).lastPathComponent == "DerivedData" })
    try FileManager.default.removeItem(at: root)
}

@Test func derivedDataAggregateReportsPartialFailureAsOneBoundedResult() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let parent = root.appendingPathComponent("Library/Developer/Xcode/DerivedData"); try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    var members: [TrashMember] = []
    for name in ["first-private-name", "second-private-name"] {
        let child = parent.appendingPathComponent(name); try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86_400)], ofItemAtPath: child.path)
        members.append(TrashMember(path: child.path, identity: try identity(at: child), bytes: 0))
    }
    let candidate = CleanupCandidate(id: 7, name: "Xcode DerivedData", mechanism: .moveToTrash, currentScopeBytes: 0, estimatedReclaimBytes: nil, trashMoveBytes: 0, estimateBasis: "2 eligible top-level items", scope: parent.path, status: .ready, reason: nil, command: nil, argv: nil, filePath: nil, fileIdentity: nil, eligibleItemCount: 2, eligibleItemBytes: 0, executionMembers: members)
    let trasher = SelectiveTrasher(failingName: "second-private-name")
    let outcome = try #require(Executor(home: root, trasher: trasher).execute(ExecutionPlan(candidates: [candidate]), cancellation: CancellationState()).first)
    #expect(outcome.kind == .commandFailed); #expect(outcome.succeededItemCount == 1); #expect(outcome.failedItemCount == 1); #expect(outcome.notRunItemCount == 0)
    #expect(!outcome.detail.contains("first-private-name")); #expect(!outcome.detail.contains("second-private-name")); #expect(outcome.detail.contains("DerivedData folder was not moved"))
    try FileManager.default.removeItem(at: root)
}

@Test func directProcessRunnerWaitsForLateStdoutAndStderr() {
    let result = DirectProcessRunner().run(
        executable: "/bin/sh",
        arguments: ["-c", "printf 'stdout-first\\n'; printf 'stderr-first\\n' >&2; sleep 0.05; printf 'stdout-late\\n'; printf 'stderr-late\\n' >&2"],
        environment: sanitizedEnvironment(home: FileManager.default.homeDirectoryForCurrentUser.path),
        cwd: "/"
    )
    #expect(result.status == 0)
    #expect(result.stdout == "stdout-first\nstdout-late\n")
    #expect(result.stderr == "stderr-first\nstderr-late\n")
}

@Test func trashInspectionReminderRequiresAnActualTrashMove() {
    let notRun = ItemOutcome(candidateID: 1, kind: .notRun, exitCode: nil, detail: "not run", succeededItemCount: 0, failedItemCount: 0, notRunItemCount: 2)
    let invalidated = ItemOutcome(candidateID: 2, kind: .invalidated, exitCode: nil, detail: "drift")
    let partialMove = ItemOutcome(candidateID: 3, kind: .commandFailed, exitCode: nil, detail: "partial", succeededItemCount: 1, failedItemCount: 1, notRunItemCount: 0)
    let trashed = ItemOutcome(candidateID: 4, kind: .trashed, exitCode: nil, detail: "moved")
    #expect(!shouldShowTrashInspectionReminder([]))
    #expect(!shouldShowTrashInspectionReminder([notRun, invalidated]))
    #expect(shouldShowTrashInspectionReminder([partialMove]))
    #expect(shouldShowTrashInspectionReminder([trashed]))
}

@Test func anyPlanDriftPreventsEarlierValidTrashItem() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let downloads = root.appendingPathComponent("Downloads"); try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    func candidate(_ name: String, id: Int) throws -> CleanupCandidate {
        let file = downloads.appendingPathComponent(name); try Data("a".utf8).write(to: file); try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-31 * 86_400)], ofItemAtPath: file.path); let item = try identity(at: file)
        return trashFixture(id: id, name: name, bytes: item.size, scope: downloads.path, filePath: file.path, fileIdentity: item)
    }
    let first = try candidate("first.zip", id: 1); let second = try candidate("second.zip", id: 2)
    try Data("drift".utf8).write(to: URL(fileURLWithPath: second.filePath!))
    let trasher = RecordingTrasher(); let outcomes = Executor(home: root, ownerID: geteuid(), trasher: trasher).execute(ExecutionPlan(candidates: [first, second]), cancellation: CancellationState())
    #expect(trasher.paths.isEmpty); #expect(outcomes.map(\.kind) == [.notRun, .invalidated])
    try FileManager.default.removeItem(at: root)
}
