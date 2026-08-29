import Darwin
import Foundation

public struct ToolDefinition: Sendable {
    public let name: String; public let executableNames: [String]; public let versionArguments: [String]; public let helpArguments: [String]
    public let helpToken: String; public let acceptedVersion: @Sendable (String) -> Bool; public let cleanupArguments: [String]; public let cachePaths: [String]; public let estimate: ToolEstimate
}

public enum ToolEstimate: Sendable { case fullScope(String), homebrewDryRun, unavailable(String) }

public let allowedTools: [ToolDefinition] = [
    .init(name: "Homebrew", executableNames: ["brew"], versionArguments: ["--version"], helpArguments: ["cleanup", "--help"], helpToken: "prune", acceptedVersion: { $0.contains("Homebrew") }, cleanupArguments: ["cleanup", "--prune=120"], cachePaths: ["Library/Caches/Homebrew"], estimate: .homebrewDryRun),
    .init(name: "npm", executableNames: ["npm"], versionArguments: ["--version"], helpArguments: ["cache", "--help"], helpToken: "clean", acceptedVersion: { Int($0.split(separator: ".").first ?? "") != nil }, cleanupArguments: ["cache", "clean", "--force"], cachePaths: [".npm"], estimate: .fullScope("command clears the discovered npm cache scope")),
    .init(name: "pnpm", executableNames: ["pnpm"], versionArguments: ["--version"], helpArguments: ["store", "--help"], helpToken: "prune", acceptedVersion: { Int($0.split(separator: ".").first ?? "") != nil }, cleanupArguments: ["store", "prune"], cachePaths: ["Library/pnpm/store", ".local/share/pnpm/store"], estimate: .unavailable("pnpm store prune removes only unreferenced packages; no reliable byte estimate is available")),
    .init(name: "Yarn Classic", executableNames: ["yarn"], versionArguments: ["--version"], helpArguments: ["cache", "--help"], helpToken: "clean", acceptedVersion: { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("1.") }, cleanupArguments: ["cache", "clean"], cachePaths: ["Library/Caches/Yarn"], estimate: .fullScope("command clears the discovered Yarn Classic cache scope")),
    .init(name: "Bun", executableNames: ["bun"], versionArguments: ["--version"], helpArguments: ["pm", "--help"], helpToken: "cache", acceptedVersion: { Int($0.split(separator: ".").first ?? "") != nil }, cleanupArguments: ["pm", "cache", "rm"], cachePaths: [".bun/install/cache"], estimate: .fullScope("command removes the discovered Bun package cache scope")),
    .init(name: "SwiftPM", executableNames: ["swift"], versionArguments: ["--version"], helpArguments: ["package", "help", "purge-cache"], helpToken: "purge-cache", acceptedVersion: { $0.contains("Swift version") }, cleanupArguments: ["package", "purge-cache"], cachePaths: ["Library/Caches/org.swift.swiftpm"], estimate: .fullScope("command purges the discovered SwiftPM global cache scope")),
    .init(name: "CocoaPods", executableNames: ["pod"], versionArguments: ["--version"], helpArguments: ["cache", "--help"], helpToken: "clean", acceptedVersion: { Int($0.split(separator: ".").first ?? "") != nil }, cleanupArguments: ["cache", "clean", "--all"], cachePaths: ["Library/Caches/CocoaPods"], estimate: .fullScope("command clears all pods in the discovered CocoaPods cache scope")),
]

public func installationLayoutAllowed(name: String, launcher: String, resolved: String, home: URL) -> Bool {
    let prefixLauncher = launcher.hasPrefix("/opt/homebrew/bin/") || launcher.hasPrefix("/usr/local/bin/")
    if name == "Homebrew", ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].contains(launcher) { return resolved == launcher || resolved.contains("/Homebrew/") }
    if prefixLauncher && (resolved.hasPrefix("/opt/homebrew/Cellar/") || resolved.hasPrefix("/usr/local/Cellar/") || resolved.hasPrefix("/opt/homebrew/lib/node_modules/") || resolved.hasPrefix("/usr/local/lib/node_modules/")) { return true }
    if name == "SwiftPM", resolved.contains("/Contents/Developer/Toolchains/") || resolved.hasPrefix("/Library/Developer/CommandLineTools/usr/bin/") { return true }
    if name == "pnpm" {
        let allowed = [home.appendingPathComponent(".local/share/pnpm/").path, home.appendingPathComponent("Library/pnpm/").path, home.appendingPathComponent(".asdf/shims/").path, home.appendingPathComponent(".local/share/mise/shims/").path]
        return allowed.contains { launcher.hasPrefix($0) && resolved.hasPrefix($0) }
    }
    return false
}

private func secureInstallationPath(_ path: String, ownerID: UInt32) -> Bool {
    var current = URL(fileURLWithPath: path).standardizedFileURL; var isFinalComponent = true
    while current.path != "/" {
        var info = stat()
        guard current.path.withCString({ lstat($0, &info) }) == 0, info.st_uid == 0 || info.st_uid == ownerID else { return false }
        let isFinalSymlink = isFinalComponent && (info.st_mode & S_IFMT) == S_IFLNK
        guard isFinalSymlink || info.st_mode & 0o002 == 0 else { return false }
        current.deleteLastPathComponent(); isFinalComponent = false
    }
    return true
}

public struct Discoverer {
    public let home: URL; public let runner: any ProcessRunning; public let ownerID: UInt32; public let now: Date; public let calendar: Calendar
    private let executableOverrides: [String: [String]]?
    public init(home: URL, runner: any ProcessRunning = DirectProcessRunner(), ownerID: UInt32 = geteuid(), now: Date = Date(), calendar: Calendar = .current, executableOverrides: [String: [String]]? = nil) {
        self.home = home.standardizedFileURL; self.runner = runner; self.ownerID = ownerID; self.now = now; self.calendar = calendar; self.executableOverrides = executableOverrides
    }

    public func discover(version: String) -> DiscoveryReport {
        var candidates: [CleanupCandidate] = []; var notices: [String] = []; var nextID = 1
        for definition in allowedTools {
            let result = discoverTool(definition, id: nextID)
            if let candidate = result.0 { candidates.append(candidate); nextID += 1 }
            if let notice = result.1 { notices.append(notice) }
        }
        discoverDerivedData(startingID: &nextID, candidates: &candidates, notices: &notices)
        discoverDownloads(startingID: &nextID, candidates: &candidates, notices: &notices)
        return DiscoveryReport(version: version, dryRun: true, mutationPerformed: false, candidates: candidates, notices: notices)
    }

    private func launcherPaths(named name: String) -> [String] {
        if let override = executableOverrides?[name] { return override }
        if name == "swift" {
            let result = runner.run(executable: "/usr/bin/xcrun", arguments: ["--find", "swift"], environment: probeEnvironment(home: home.path), cwd: "/")
            let found = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.status == 0, found.hasPrefix("/") { return [found] }
        }
        var paths = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/\(name)"]
        if name == "pnpm" { paths += [home.appendingPathComponent(".local/share/pnpm/pnpm").path, home.appendingPathComponent("Library/pnpm/pnpm").path, home.appendingPathComponent(".asdf/shims/pnpm").path, home.appendingPathComponent(".local/share/mise/shims/pnpm").path] }
        return paths
    }

    private func discoverTool(_ definition: ToolDefinition, id: Int) -> (CleanupCandidate?, String?) {
        guard let launcher = launcherPaths(named: definition.executableNames[0]).first(where: FileManager.default.isExecutableFile) else { return (nil, "\(definition.name): cleanup disabled — executable not found in supported locations; no cleanup command will run") }
        let resolved = URL(fileURLWithPath: launcher).resolvingSymlinksInPath().standardizedFileURL.path
        guard installationLayoutAllowed(name: definition.name, launcher: launcher, resolved: resolved, home: home), secureInstallationPath(launcher, ownerID: ownerID), secureInstallationPath(resolved, ownerID: ownerID), let file = try? identity(at: URL(fileURLWithPath: resolved), followSymlink: true), file.ownerID == 0 || file.ownerID == ownerID else { return (nil, "\(definition.name): cleanup disabled — installation layout is not supported (\(resolved)); no cleanup command will run") }
        let environment = probeEnvironment(home: home.path, executable: launcher, brew: definition.name == "Homebrew")
        let versionResult = runner.run(executable: launcher, arguments: definition.versionArguments, environment: environment, cwd: "/")
        let version = versionResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard versionResult.status == 0 else { let detail = boundedDiagnostic(versionResult.stderr); return (nil, "\(definition.name): cleanup disabled — version probe exited \(versionResult.status)\(detail.isEmpty ? "" : ": \(detail)"); no cleanup command will run") }
        guard !version.isEmpty, definition.acceptedVersion(version) else { return (nil, "\(definition.name): cleanup disabled — version output was not recognized\(version.isEmpty ? " (empty output)" : ": \(boundedDiagnostic(version))"); no cleanup command will run") }
        let helpResult = runner.run(executable: launcher, arguments: definition.helpArguments, environment: environment, cwd: "/")
        guard helpResult.status == 0, (helpResult.stdout + helpResult.stderr).localizedCaseInsensitiveContains(definition.helpToken) else { return (nil, "\(definition.name): cleanup disabled — required cleanup command is unavailable in current help; no cleanup command will run") }
        guard let homeIdentity = try? identity(at: home) else { return (nil, "\(definition.name): cleanup disabled — effective home is unavailable; no cleanup command will run") }
        var size: UInt64 = 0; var scopes: [String] = []; var scopeIdentities: [CacheScopeIdentity] = []
        for relative in definition.cachePaths {
            let cache = home.appendingPathComponent(relative).standardizedFileURL
            guard cache.path.hasPrefix(home.path + "/"), let cacheIdentity = try? identity(at: cache), cacheIdentity.ownerID == ownerID, cacheIdentity.device == homeIdentity.device, !isSymlink(cacheIdentity, at: cache), let cacheSize = directorySize(cache, ownerID: ownerID) else { continue }
            size &+= cacheSize; scopes.append(cache.path); scopeIdentities.append(CacheScopeIdentity(path: cache.path, identity: cacheIdentity))
        }
        guard !scopes.isEmpty else { return (nil, "\(definition.name): nothing eligible found — no current-user-owned in-home cache scope; no cleanup command will run") }
        let commandIdentity = CommandIdentity(path: resolved, device: file.device, inode: file.inode, size: file.size, modified: file.modified, ownerID: file.ownerID, version: version)
        let estimate: UInt64?; let basis: String
        switch definition.estimate {
        case let .fullScope(description): estimate = size; basis = description
        case let .unavailable(description): estimate = nil; basis = description
        case .homebrewDryRun:
            let dryRun = runner.run(executable: launcher, arguments: definition.cleanupArguments + ["--dry-run"], environment: environment, cwd: "/")
            estimate = dryRun.status == 0 ? parseHomebrewReclaimBytes(dryRun.stdout + "\n" + dryRun.stderr) : nil
            basis = estimate == nil ? "Homebrew dry-run did not provide a reliable reclaim total; excluded from the numeric total" : "reported by brew cleanup --prune=120 --dry-run"
        }
        return (CleanupCandidate(id: id, name: definition.name, mechanism: .permanentCommand, currentScopeBytes: size, estimatedReclaimBytes: estimate, trashMoveBytes: nil, estimateBasis: basis, scope: scopes.joined(separator: ", "), status: .ready, reason: nil, command: commandIdentity, argv: [resolved] + definition.cleanupArguments, cacheScopes: scopeIdentities, filePath: nil, fileIdentity: nil), nil)
    }

    private func discoverDerivedData(startingID: inout Int, candidates: inout [CleanupCandidate], notices: inout [String]) {
        let parent = home.appendingPathComponent("Library/Developer/Xcode/DerivedData").standardizedFileURL
        guard let children = try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles]) else { notices.append("DerivedData: unavailable or empty"); return }
        let parentIdentity = try? identity(at: parent); let homeIdentity = try? identity(at: home)
        let cutoff = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        let sorted = children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }); var members: [TrashMember] = []; var recent = 0; var unsafe = 0
        for child in sorted {
            guard child.deletingLastPathComponent().standardizedFileURL == parent, let item = try? identity(at: child), item.ownerID == ownerID, item.device == parentIdentity?.device, parentIdentity?.device == homeIdentity?.device, !isSymlink(item, at: child), (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { unsafe += 1; continue }
            guard item.modified < cutoff else { recent += 1; continue }
            guard members.count < 100 else { continue }
            let size = directorySize(child, ownerID: ownerID)
            members.append(TrashMember(path: child.path, identity: item, bytes: size))
        }
        if !members.isEmpty {
            let knownBytes = members.compactMap(\.bytes).reduce(0, &+)
            let aggregateBytes: UInt64? = members.allSatisfy { $0.bytes != nil } ? knownBytes : nil
            candidates.append(CleanupCandidate(id: startingID, name: "Xcode DerivedData", mechanism: .moveToTrash, currentScopeBytes: aggregateBytes, estimatedReclaimBytes: nil, trashMoveBytes: aggregateBytes, estimateBasis: "\(members.count) eligible top-level item(s); each item moves separately to Trash", scope: parent.path, status: .ready, reason: nil, command: nil, argv: nil, filePath: nil, fileIdentity: nil, eligibleItemCount: members.count, eligibleItemBytes: aggregateBytes, executionMembers: members)); startingID += 1
        }
        if recent > 0 { notices.append("DerivedData: \(recent) top-level item(s) modified today or yesterday excluded") }
        let boundedOut = max(0, sorted.count - members.count - recent - unsafe)
        if boundedOut > 0 { notices.append("DerivedData: \(boundedOut) additional eligible top-level entries omitted by the 100-item safety/output bound; refine manually and rescan") }
    }

    private func discoverDownloads(startingID: inout Int, candidates: inout [CleanupCandidate], notices: inout [String]) {
        let parent = home.appendingPathComponent("Downloads").standardizedFileURL
        guard let children = try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isRegularFileKey, .isPackageKey, .isAliasFileKey], options: []) else { notices.append("Downloads: unavailable or blocked by macOS privacy controls; skipped without requesting Full Disk Access or sudo") ; return }
        let parentIdentity = try? identity(at: parent); let homeIdentity = try? identity(at: home); let cutoff = now.addingTimeInterval(-30 * 86_400)
        var eligible: [TrashMember] = []
        let suffixes = [".dmg", ".pkg", ".xip", ".iso", ".zip", ".tar", ".tgz", ".tar.gz", ".tar.bz2", ".tar.xz", ".7z", ".rar"]
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let item = try? identity(at: child), item.ownerID == ownerID, item.device == parentIdentity?.device, parentIdentity?.device == homeIdentity?.device, !isSymlink(item, at: child) else { continue }
            let values = try? child.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey, .isAliasFileKey])
            guard values?.isRegularFile == true, values?.isPackage != true, values?.isAliasFile != true else { continue }
            let name = child.lastPathComponent; let lower = name.lowercased()
            guard !name.hasPrefix("."), !lower.hasSuffix(".download"), !lower.hasSuffix(".crdownload"), !lower.hasSuffix(".part"), item.modified <= cutoff, suffixes.contains(where: { lower.hasSuffix($0) }) else { continue }
            eligible.append(TrashMember(path: child.path, identity: item, bytes: item.size))
        }
        guard !eligible.isEmpty else { notices.append("Downloads: no eligible old top-level installer or archive files found"); return }
        let eligibleBytes = eligible.compactMap(\.bytes).reduce(0, &+)
        candidates.append(CleanupCandidate(id: startingID, name: "Downloads", mechanism: .moveToTrash, currentScopeBytes: eligibleBytes, estimatedReclaimBytes: nil, trashMoveBytes: eligibleBytes, estimateBasis: "\(eligible.count) eligible old top-level installer/archive file(s); each file moves separately to Trash", scope: parent.path, status: .ready, reason: nil, command: nil, argv: nil, filePath: nil, fileIdentity: nil, eligibleItemCount: eligible.count, eligibleItemBytes: eligibleBytes, executionMembers: eligible)); startingID += 1
    }
}

public func parseHomebrewReclaimBytes(_ output: String) -> UInt64? {
    let pattern = #"(?i)would free(?: approximately)?(?::|\s)+([0-9]+(?:\.[0-9]+)?)\s*(bytes?|kb|mb|gb|tb)\b"#
    guard let expression = try? NSRegularExpression(pattern: pattern), let match = expression.matches(in: output, range: NSRange(output.startIndex..., in: output)).last,
          let valueRange = Range(match.range(at: 1), in: output), let unitRange = Range(match.range(at: 2), in: output), let value = Double(output[valueRange]) else { return nil }
    let multiplier: Double
    switch output[unitRange].lowercased() { case "kb": multiplier = 1_000; case "mb": multiplier = 1_000_000; case "gb": multiplier = 1_000_000_000; case "tb": multiplier = 1_000_000_000_000; default: multiplier = 1 }
    let bytes = value * multiplier
    guard bytes.isFinite, bytes >= 0, bytes <= Double(UInt64.max) else { return nil }
    return UInt64(bytes.rounded())
}
