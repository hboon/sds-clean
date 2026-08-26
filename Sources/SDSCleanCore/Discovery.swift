import Darwin
import Foundation

public struct ToolDefinition: Sendable {
    public let name: String; public let executableNames: [String]; public let versionArguments: [String]; public let helpArguments: [String]
    public let helpToken: String; public let acceptedVersion: @Sendable (String) -> Bool; public let cleanupArguments: [String]; public let cachePaths: [String]
}

public let allowedTools: [ToolDefinition] = [
    .init(name: "Homebrew", executableNames: ["brew"], versionArguments: ["--version"], helpArguments: ["cleanup", "--help"], helpToken: "prune", acceptedVersion: { $0.contains("Homebrew") }, cleanupArguments: ["cleanup", "--prune=120"], cachePaths: ["Library/Caches/Homebrew"]),
    .init(name: "npm", executableNames: ["npm"], versionArguments: ["--version"], helpArguments: ["cache", "--help"], helpToken: "clean", acceptedVersion: { Int($0.split(separator: ".").first ?? "") != nil }, cleanupArguments: ["cache", "clean", "--force"], cachePaths: [".npm"]),
    .init(name: "pnpm", executableNames: ["pnpm"], versionArguments: ["--version"], helpArguments: ["store", "--help"], helpToken: "prune", acceptedVersion: { Int($0.split(separator: ".").first ?? "") != nil }, cleanupArguments: ["store", "prune"], cachePaths: ["Library/pnpm/store"]),
    .init(name: "Yarn Classic", executableNames: ["yarn"], versionArguments: ["--version"], helpArguments: ["cache", "--help"], helpToken: "clean", acceptedVersion: { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("1.") }, cleanupArguments: ["cache", "clean"], cachePaths: ["Library/Caches/Yarn"]),
    .init(name: "Bun", executableNames: ["bun"], versionArguments: ["--version"], helpArguments: ["pm", "--help"], helpToken: "cache", acceptedVersion: { Int($0.split(separator: ".").first ?? "") != nil }, cleanupArguments: ["pm", "cache", "rm"], cachePaths: [".bun/install/cache"]),
    .init(name: "SwiftPM", executableNames: ["swift"], versionArguments: ["--version"], helpArguments: ["package", "--help"], helpToken: "purge-cache", acceptedVersion: { $0.contains("Swift version") }, cleanupArguments: ["package", "purge-cache"], cachePaths: ["Library/Caches/org.swift.swiftpm"]),
    .init(name: "CocoaPods", executableNames: ["pod"], versionArguments: ["--version"], helpArguments: ["cache", "--help"], helpToken: "clean", acceptedVersion: { Int($0.split(separator: ".").first ?? "") != nil }, cleanupArguments: ["cache", "clean", "--all"], cachePaths: ["Library/Caches/CocoaPods"]),
]

public struct Discoverer {
    public let home: URL; public let runner: any ProcessRunning; public let ownerID: UInt32
    public init(home: URL, runner: any ProcessRunning = DirectProcessRunner(), ownerID: UInt32 = geteuid()) { self.home = home.standardizedFileURL; self.runner = runner; self.ownerID = ownerID }

    public func discover(version: String) -> DiscoveryReport {
        var candidates: [CleanupCandidate] = []; var notices: [String] = []; var nextID = 1
        for definition in allowedTools {
            let result = discoverTool(definition, id: nextID)
            if let candidate = result.0 { candidates.append(candidate); if candidate.status == .ready { nextID += 1 } }
            if let notice = result.1 { notices.append(notice) }
        }
        discoverDerivedData(startingID: &nextID, candidates: &candidates, notices: &notices)
        let downloadsTotal = discoverDownloads(startingID: &nextID, candidates: &candidates, notices: &notices)
        return DiscoveryReport(version: version, dryRun: true, mutationPerformed: false, downloadsTotalBytes: downloadsTotal, downloadsNote: "Downloads is mixed personal data and is never offered as one cleanup candidate.", candidates: candidates, notices: notices)
    }

    private func executablePath(named name: String) -> String? {
        if name == "swift" {
            let result = runner.run(executable: "/usr/bin/xcrun", arguments: ["--find", "swift"], environment: probeEnvironment(), cwd: "/")
            let found = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.status == 0, found.hasPrefix("/") { return found }
        }
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/\(name)"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func discoverTool(_ definition: ToolDefinition, id: Int) -> (CleanupCandidate?, String?) {
        guard let path = definition.executableNames.compactMap(executablePath).first else { return (nil, "\(definition.name): not installed") }
        let url = URL(fileURLWithPath: path); let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalPrefix = path.hasPrefix("/opt/homebrew/bin/") || path.hasPrefix("/usr/local/bin/")
        let trustedHomebrew = canonicalPrefix && (resolved.hasPrefix("/opt/homebrew/Cellar/") || resolved.hasPrefix("/usr/local/Cellar/") || (definition.name == "Homebrew" && (resolved.hasPrefix("/opt/homebrew/Library/Homebrew/") || resolved.hasPrefix("/usr/local/Homebrew/Library/Homebrew/"))) || (definition.name == "npm" && (resolved.hasPrefix("/opt/homebrew/lib/node_modules/npm/") || resolved.hasPrefix("/usr/local/lib/node_modules/npm/"))))
        let trustedToolchain = definition.name == "SwiftPM" && (resolved.contains("/Contents/Developer/Toolchains/") || resolved.hasPrefix("/Library/Developer/CommandLineTools/usr/bin/"))
        guard (trustedHomebrew || trustedToolchain), let file = try? identity(at: URL(fileURLWithPath: resolved), followSymlink: true), file.ownerID == 0 || file.ownerID == ownerID else { return (nil, "\(definition.name): report only — executable is not a trusted canonical Homebrew-prefix or active Xcode-toolchain binary (\(resolved))") }
        let environment = probeEnvironment(executable: resolved, brew: definition.name == "Homebrew")
        let versionResult = runner.run(executable: resolved, arguments: definition.versionArguments, environment: environment, cwd: "/")
        let version = versionResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard versionResult.status == 0, definition.acceptedVersion(version) else { return (nil, "\(definition.name): report only — unsupported version at \(resolved): \(version.prefix(120))") }
        let helpResult = runner.run(executable: resolved, arguments: definition.helpArguments, environment: environment, cwd: "/")
        guard helpResult.status == 0, (helpResult.stdout + helpResult.stderr).localizedCaseInsensitiveContains(definition.helpToken) else { return (nil, "\(definition.name): report only — required command is not supported by current help") }
        guard let homeIdentity = try? identity(at: home) else { return (nil, "\(definition.name): effective home identity is unavailable") }
        var size: UInt64 = 0; var scopes: [String] = []; var scopeIdentities: [CacheScopeIdentity] = []
        for relative in definition.cachePaths {
            let cache = home.appendingPathComponent(relative).standardizedFileURL
            guard cache.path.hasPrefix(home.path + "/"), let cacheIdentity = try? identity(at: cache), cacheIdentity.ownerID == ownerID, cacheIdentity.device == homeIdentity.device, !isSymlink(cacheIdentity, at: cache), let cacheSize = directorySize(cache, ownerID: ownerID) else { continue }
            size &+= cacheSize; scopes.append(cache.path); scopeIdentities.append(CacheScopeIdentity(path: cache.path, identity: cacheIdentity))
        }
        guard !scopes.isEmpty else { return (nil, "\(definition.name): no current-user-owned in-home cache scope found") }
        let commandIdentity = CommandIdentity(path: resolved, device: file.device, inode: file.inode, size: file.size, modified: file.modified, ownerID: file.ownerID, version: version)
        return (CleanupCandidate(id: id, name: definition.name, mechanism: .permanentCommand, estimatedBytes: size, scope: scopes.joined(separator: ", "), status: .ready, reason: nil, command: commandIdentity, argv: [resolved] + definition.cleanupArguments, cacheScopes: scopeIdentities, filePath: nil, fileIdentity: nil), nil)
    }

    private func discoverDerivedData(startingID: inout Int, candidates: inout [CleanupCandidate], notices: inout [String]) {
        let parent = home.appendingPathComponent("Library/Developer/Xcode/DerivedData").standardizedFileURL
        guard let children = try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles]) else { notices.append("DerivedData: unavailable or empty"); return }
        let parentIdentity = try? identity(at: parent); let homeIdentity = try? identity(at: home)
        let sorted = children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        var accepted = 0
        for child in sorted {
            guard child.deletingLastPathComponent().standardizedFileURL == parent,
                  let item = try? identity(at: child), item.ownerID == ownerID, item.device == parentIdentity?.device, parentIdentity?.device == homeIdentity?.device,
                  !isSymlink(item, at: child), (try? child.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]).isDirectory) == true else { continue }
            let size = directorySize(child, ownerID: ownerID)
            candidates.append(CleanupCandidate(id: startingID, name: "DerivedData: \(child.lastPathComponent)", mechanism: .moveToTrash, estimatedBytes: size, scope: parent.path, status: .ready, reason: nil, command: nil, argv: nil, filePath: child.path, fileIdentity: item)); startingID += 1
            accepted += 1
            if accepted == 100 { break }
        }
        if sorted.count > accepted { notices.append("DerivedData: \(sorted.count - accepted) additional top-level entries omitted by the 100-item safety/output bound; refine manually and rescan") }
    }

    private func discoverDownloads(startingID: inout Int, candidates: inout [CleanupCandidate], notices: inout [String]) -> UInt64? {
        let parent = home.appendingPathComponent("Downloads").standardizedFileURL
        guard let children = try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isRegularFileKey, .isPackageKey, .isAliasFileKey], options: []) else { notices.append("Downloads: skipped (unavailable or permission denied; Full Disk Access and sudo are not requested)"); return nil }
        let parentIdentity = try? identity(at: parent); let homeIdentity = try? identity(at: home); let cutoff = Date().addingTimeInterval(-30 * 86_400)
        var total: UInt64 = 0; var eligible: [(URL, FileIdentity)] = []
        let suffixes = [".dmg", ".pkg", ".xip", ".iso", ".zip", ".tar", ".tgz", ".tar.gz", ".tar.bz2", ".tar.xz", ".7z", ".rar"]
        for child in children {
            guard let item = try? identity(at: child), item.ownerID == ownerID, item.device == parentIdentity?.device, parentIdentity?.device == homeIdentity?.device, !isSymlink(item, at: child) else { continue }
            let values = try? child.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey, .isAliasFileKey])
            guard values?.isRegularFile == true, values?.isPackage != true, values?.isAliasFile != true else { continue }
            total &+= item.size
            let name = child.lastPathComponent; let lower = name.lowercased()
            guard !name.hasPrefix("."), !lower.hasSuffix(".download"), !lower.hasSuffix(".crdownload"), !lower.hasSuffix(".part"), item.modified <= cutoff, suffixes.contains(where: { lower.hasSuffix($0) }) else { continue }
            eligible.append((child, item))
        }
        for (child, item) in eligible.sorted(by: { $0.1.size > $1.1.size }).prefix(20) {
            candidates.append(CleanupCandidate(id: startingID, name: "Download: \(child.lastPathComponent)", mechanism: .moveToTrash, estimatedBytes: item.size, scope: parent.path, status: .ready, reason: nil, command: nil, argv: nil, filePath: child.path, fileIdentity: item)); startingID += 1
        }
        return directorySize(parent, ownerID: ownerID) ?? total
    }
}
