import Darwin
import Foundation

public final class CancellationState: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    public init() {}
    public func cancel() { lock.lock(); value = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

public struct Executor {
    public let home: URL; public let ownerID: UInt32; public let runner: any ProcessRunning; public let trasher: any Trashing; public let now: Date; public let calendar: Calendar
    private let installationValidator: @Sendable (String, String, String, URL) -> Bool
    public init(home: URL, ownerID: UInt32 = geteuid(), runner: any ProcessRunning = DirectProcessRunner(), trasher: any Trashing = FoundationTrasher(), now: Date = Date(), calendar: Calendar = .current, installationValidator: @escaping @Sendable (String, String, String, URL) -> Bool = installationLayoutAllowed) { self.home = home.standardizedFileURL; self.ownerID = ownerID; self.runner = runner; self.trasher = trasher; self.now = now; self.calendar = calendar; self.installationValidator = installationValidator }

    public func validate(_ candidate: CleanupCandidate) -> String? {
        if candidate.mechanism == .permanentCommand {
            guard let expected = candidate.command, let actual = try? identity(at: URL(fileURLWithPath: expected.path), followSymlink: true), actual.device == expected.device, actual.inode == expected.inode, actual.size == expected.size, actual.modified == expected.modified, actual.ownerID == expected.ownerID, (actual.ownerID == 0 || actual.ownerID == ownerID),
                  let definition = allowedTools.first(where: { $0.cleanupArguments == Array((candidate.argv ?? []).dropFirst()) }) else { return "command identity or allowlist changed" }
            guard installationValidator(definition.name, expected.path, expected.path, home), secureInstallationPath(expected.path, ownerID: ownerID) else { return "command installation layout or security changed" }
            if definition.name == "Yarn global cache", !neutralYarnConfigurationIsolated() { return "neutral Yarn configuration isolation changed" }
            let result = runner.run(executable: expected.path, arguments: definition.versionArguments, environment: probeEnvironment(home: home.path, executable: expected.path, brew: definition.name == "Homebrew"), cwd: "/")
            guard result.status == 0, result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == expected.version else { return "command version changed" }
            let help = runner.run(executable: expected.path, arguments: definition.helpArguments, environment: probeEnvironment(home: home.path, executable: expected.path, brew: definition.name == "Homebrew"), cwd: "/")
            let helpText = help.stdout + help.stderr
            guard help.status == 0, helpText.localizedCaseInsensitiveContains(definition.helpToken), definition.requiredHelpOption.map({ helpAdvertisesExactOption(helpText, option: $0) }) ?? true else { return "command help support changed" }
            guard let scopes = candidate.cacheScopes, !scopes.isEmpty else { return "cache scope is missing" }
            let environment = probeEnvironment(home: home.path, executable: expected.path, brew: definition.name == "Homebrew")
            guard let currentPaths = resolvedCachePaths(for: definition, executable: expected.path, runner: runner, environment: environment, home: home), Set(currentPaths.map(\.path)) == Set(scopes.map(\.path)) else { return "configured cache scope changed" }
            for scope in scopes {
                let url = URL(fileURLWithPath: scope.path).standardizedFileURL
                guard url.path.hasPrefix(home.path + "/"), let actual = try? identity(at: url), let homeIdentity = try? identity(at: home), actual == scope.identity, actual.ownerID == ownerID, actual.device == homeIdentity.device, !isSymlink(actual, at: url), directorySize(url, ownerID: ownerID) != nil else { return "cache scope identity, ownership, mount, or containment changed" }
            }
            return nil
        }
        if !candidate.executionMembers.isEmpty {
            guard candidate.eligibleItemCount == candidate.executionMembers.count else { return "aggregate member count changed" }
            for member in candidate.executionMembers {
                if let reason = validateTrashMember(path: member.path, expected: member.identity) { return reason }
            }
            return nil
        }
        guard let path = candidate.filePath, let expected = candidate.fileIdentity else { return "missing file identity" }
        return validateTrashMember(path: path, expected: expected)
    }

    private func validateTrashMember(path: String, expected: FileIdentity) -> String? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let allowedParents = [home.appendingPathComponent("Downloads").standardizedFileURL, home.appendingPathComponent("Library/Developer/Xcode/DerivedData").standardizedFileURL]
        guard let parentIndex = allowedParents.firstIndex(of: url.deletingLastPathComponent().standardizedFileURL), url.path.hasPrefix(home.path + "/"), let actual = try? identity(at: url), actual == expected, actual.ownerID == ownerID, !isSymlink(actual, at: url), let parentIdentity = try? identity(at: url.deletingLastPathComponent()), let homeIdentity = try? identity(at: home), parentIdentity.ownerID == ownerID, !isSymlink(parentIdentity, at: url.deletingLastPathComponent()), actual.device == parentIdentity.device, parentIdentity.device == homeIdentity.device else { return "file identity, type, ownership, mount, or containment changed" }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .isAliasFileKey])
        if parentIndex == 0 {
            guard values?.isRegularFile == true, values?.isPackage != true, values?.isAliasFile != true, isEligibleDownloadName(url.lastPathComponent), actual.modified <= now.addingTimeInterval(-30 * 86_400) else { return "Downloads eligibility changed" }
        } else {
            let cutoff = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
            guard values?.isDirectory == true, actual.modified < cutoff else { return "DerivedData item type or recent-modification eligibility changed" }
        }
        return nil
    }

    public func execute(_ plan: ExecutionPlan, cancellation: CancellationState) -> [ItemOutcome] {
        if cancellation.isCancelled { return plan.candidates.map { ItemOutcome(candidateID: $0.id, kind: .notRun, exitCode: nil, detail: "cancelled before mutation") } }
        for candidate in plan.candidates {
            if let reason = validate(candidate) {
                return plan.candidates.map { ItemOutcome(candidateID: $0.id, kind: $0.id == candidate.id ? .invalidated : .notRun, exitCode: nil, detail: $0.id == candidate.id ? reason : "plan invalidated before mutation") }
            }
        }
        var outcomes: [ItemOutcome] = []
        for (offset, candidate) in plan.candidates.enumerated() {
            if cancellation.isCancelled {
                outcomes += plan.candidates[offset...].map { ItemOutcome(candidateID: $0.id, kind: .notRun, exitCode: nil, detail: "cancelled before item") }; break
            }
            if let reason = validate(candidate) { outcomes.append(ItemOutcome(candidateID: candidate.id, kind: .invalidated, exitCode: nil, detail: reason)); outcomes += plan.candidates.dropFirst(offset + 1).map { ItemOutcome(candidateID: $0.id, kind: .notRun, exitCode: nil, detail: "plan invalidated") }; break }
            if candidate.mechanism == .permanentCommand, let argv = candidate.argv, let executable = argv.first {
                let brew = candidate.name == "Homebrew"; let result = runner.run(executable: executable, arguments: Array(argv.dropFirst()), environment: sanitizedEnvironment(home: home.path, executable: executable, brew: brew), cwd: "/")
                let after = candidate.cacheScopes?.compactMap { directorySize(URL(fileURLWithPath: $0.path), ownerID: ownerID) }.reduce(0, &+)
                outcomes.append(ItemOutcome(candidateID: candidate.id, kind: result.status == 0 ? .commandSucceeded : .commandFailed, exitCode: result.status, beforeEstimateBytes: candidate.currentScopeBytes, afterEstimateBytes: after, detail: result.status == 0 ? "Permanent cleanup command completed" : "Permanent cleanup command failed; no deletion fallback used: \(result.stderr.prefix(240))"))
            } else if !candidate.executionMembers.isEmpty {
                outcomes.append(executeAggregate(candidate, cancellation: cancellation))
            } else if let path = candidate.filePath {
                do { try trasher.trash(URL(fileURLWithPath: path)); outcomes.append(ItemOutcome(candidateID: candidate.id, kind: .trashed, exitCode: nil, beforeEstimateBytes: candidate.trashMoveBytes, afterEstimateBytes: nil, detail: "Moved to Trash; after estimate is not asserted and this does not equal freed disk space")) }
                catch { outcomes.append(ItemOutcome(candidateID: candidate.id, kind: .commandFailed, exitCode: nil, beforeEstimateBytes: candidate.trashMoveBytes, afterEstimateBytes: candidate.trashMoveBytes, detail: "Move to Trash failed: \(error)")) }
            }
        }
        return outcomes
    }

    private func executeAggregate(_ candidate: CleanupCandidate, cancellation: CancellationState) -> ItemOutcome {
        var succeeded = 0; var failed = 0; var notRun = 0; var invalidated = false; var remainingBytes: UInt64 = 0; var remainingSizeKnown = true
        for (offset, member) in candidate.executionMembers.enumerated() {
            if cancellation.isCancelled {
                let remaining = candidate.executionMembers[offset...]; notRun = remaining.count
                remainingSizeKnown = remaining.allSatisfy { $0.bytes != nil }; remainingBytes = remaining.compactMap(\.bytes).reduce(0, &+); break
            }
            if validateTrashMember(path: member.path, expected: member.identity) != nil {
                failed += 1; invalidated = true; remainingSizeKnown = remainingSizeKnown && member.bytes != nil; remainingBytes &+= member.bytes ?? 0; continue
            }
            do { try trasher.trash(URL(fileURLWithPath: member.path)); succeeded += 1 }
            catch { failed += 1; remainingSizeKnown = remainingSizeKnown && member.bytes != nil; remainingBytes &+= member.bytes ?? 0 }
        }
        let kind: OutcomeKind
        if succeeded == 0 && failed == 0 { kind = .notRun }
        else if invalidated { kind = .invalidated }
        else if failed > 0 { kind = .commandFailed }
        else { kind = .trashed }
        let rootName = candidate.name == "Downloads" ? "Downloads folder" : "DerivedData folder"
        let detail = "\(candidate.name) aggregate: \(succeeded) item(s) moved separately to Trash, \(failed) failed, \(notRun) not run; the \(rootName) was not moved"
        let afterBytes: UInt64? = failed + notRun > 0 && remainingSizeKnown ? remainingBytes : nil
        return ItemOutcome(candidateID: candidate.id, kind: kind, exitCode: nil, beforeEstimateBytes: candidate.trashMoveBytes, afterEstimateBytes: afterBytes, detail: detail, succeededItemCount: succeeded, failedItemCount: failed, notRunItemCount: notRun)
    }
}

private func isEligibleDownloadName(_ name: String) -> Bool {
    let lower = name.lowercased()
    let suffixes = [".dmg", ".pkg", ".xip", ".iso", ".zip", ".tar", ".tgz", ".tar.gz", ".tar.bz2", ".tar.xz", ".7z", ".rar"]
    return !name.hasPrefix(".") && !lower.hasSuffix(".download") && !lower.hasSuffix(".crdownload") && !lower.hasSuffix(".part") && suffixes.contains(where: { lower.hasSuffix($0) })
}
