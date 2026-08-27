import Foundation

public enum Mechanism: String, Codable, Sendable { case permanentCommand, moveToTrash }
public enum CandidateStatus: String, Codable, Sendable { case ready, reportOnly, skipped }

public struct FileIdentity: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: UInt64
    public let modified: Date
    public let ownerID: UInt32
    public init(device: UInt64, inode: UInt64, size: UInt64, modified: Date, ownerID: UInt32) {
        self.device = device; self.inode = inode; self.size = size; self.modified = modified; self.ownerID = ownerID
    }
}

public struct CommandIdentity: Codable, Equatable, Sendable {
    public let path: String
    public let device: UInt64
    public let inode: UInt64
    public let size: UInt64
    public let modified: Date
    public let ownerID: UInt32
    public let version: String
    public init(path: String, device: UInt64, inode: UInt64, size: UInt64, modified: Date, ownerID: UInt32, version: String) {
        self.path = path; self.device = device; self.inode = inode; self.size = size; self.modified = modified; self.ownerID = ownerID; self.version = version
    }
}

public struct CacheScopeIdentity: Codable, Equatable, Sendable {
    public let path: String
    public let identity: FileIdentity
    public init(path: String, identity: FileIdentity) { self.path = path; self.identity = identity }
}

public struct CleanupCandidate: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let mechanism: Mechanism
    public let estimatedBytes: UInt64?
    public let scope: String
    public let status: CandidateStatus
    public let reason: String?
    public let command: CommandIdentity?
    public let argv: [String]?
    public let cacheScopes: [CacheScopeIdentity]?
    public let filePath: String?
    public let fileIdentity: FileIdentity?
    public init(id: Int, name: String, mechanism: Mechanism, estimatedBytes: UInt64?, scope: String, status: CandidateStatus, reason: String?, command: CommandIdentity?, argv: [String]?, cacheScopes: [CacheScopeIdentity]? = nil, filePath: String?, fileIdentity: FileIdentity?) {
        self.id = id; self.name = name; self.mechanism = mechanism; self.estimatedBytes = estimatedBytes; self.scope = scope; self.status = status; self.reason = reason; self.command = command; self.argv = argv; self.cacheScopes = cacheScopes; self.filePath = filePath; self.fileIdentity = fileIdentity
    }
}

public struct DiscoveryReport: Codable, Sendable {
    public let schemaVersion: Int
    public let version: String
    public let dryRun: Bool
    public let mutationPerformed: Bool
    public let downloadsTotalBytes: UInt64?
    public let downloadsNote: String
    public let candidates: [CleanupCandidate]
    public let notices: [String]
    public init(schemaVersion: Int = 1, version: String, dryRun: Bool, mutationPerformed: Bool, downloadsTotalBytes: UInt64?, downloadsNote: String, candidates: [CleanupCandidate], notices: [String]) {
        self.schemaVersion = schemaVersion; self.version = version; self.dryRun = dryRun; self.mutationPerformed = mutationPerformed; self.downloadsTotalBytes = downloadsTotalBytes; self.downloadsNote = downloadsNote; self.candidates = candidates; self.notices = notices
    }
}

public struct ExecutionPlan: Codable, Equatable, Sendable {
    public let createdAt: Date
    public let candidates: [CleanupCandidate]
    public init(createdAt: Date = Date(), candidates: [CleanupCandidate]) { self.createdAt = createdAt; self.candidates = candidates }
}

public enum OutcomeKind: String, Codable, Sendable { case commandSucceeded, commandFailed, trashed, notRun, invalidated }
public struct ItemOutcome: Codable, Sendable {
    public let candidateID: Int
    public let kind: OutcomeKind
    public let exitCode: Int32?
    public let beforeEstimateBytes: UInt64?
    public let afterEstimateBytes: UInt64?
    public let detail: String
    public init(candidateID: Int, kind: OutcomeKind, exitCode: Int32?, beforeEstimateBytes: UInt64? = nil, afterEstimateBytes: UInt64? = nil, detail: String) {
        self.candidateID = candidateID; self.kind = kind; self.exitCode = exitCode; self.beforeEstimateBytes = beforeEstimateBytes; self.afterEstimateBytes = afterEstimateBytes; self.detail = detail
    }
}

public enum ExitCode: Int32 { case success = 0, usage = 2, partial = 3, invalidated = 4, cancelled = 130 }

public struct CLIOptions: Equatable {
    public var dryRun = false
    public var json = false
    public var yes = false
    public var selection: String?
    public var help = false
    public var version = false
    public init() {}
}

public enum CLIError: Error, Equatable, CustomStringConvertible {
    case usage(String)
    public var description: String { switch self { case let .usage(message): message } }
}

public func parseArguments(_ arguments: [String], isTTY: Bool) throws -> CLIOptions {
    var result = CLIOptions(); var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--dry-run": result.dryRun = true
        case "--json": result.json = true; result.dryRun = true
        case "--yes": result.yes = true
        case "--select":
            index += 1
            guard index < arguments.count, !arguments[index].hasPrefix("--") else { throw CLIError.usage("--select requires numbers or all") }
            result.selection = arguments[index]
        case "--help", "-h": result.help = true
        case "--version": result.version = true
        default: throw CLIError.usage("unknown option: \(arguments[index])")
        }
        index += 1
    }
    if result.yes && result.selection == nil { throw CLIError.usage("--yes requires --select <numbers|all>") }
    if result.selection != nil && !result.yes { throw CLIError.usage("--select is only valid with --yes") }
    if result.yes && !isTTY { throw CLIError.usage("--yes cleanup requires an interactive TTY") }
    if result.dryRun && (result.yes || result.selection != nil) { throw CLIError.usage("dry-run modes cannot execute a selection") }
    return result
}

public func parseSelection(_ text: String, candidates: [CleanupCandidate]) throws -> [CleanupCandidate] {
    let ready = candidates.filter { $0.status == .ready }
    if text.lowercased() == "all" {
        let nonDownloads = ready.filter { !$0.name.hasPrefix("Download:") }
        guard !nonDownloads.isEmpty else { throw CLIError.usage("selection is empty; 'all' excludes Downloads candidates") }
        return nonDownloads
    }
    var seen = Set<Int>(); var chosen: [CleanupCandidate] = []
    for part in text.split(separator: ",", omittingEmptySubsequences: false) {
        guard let number = Int(part.trimmingCharacters(in: .whitespaces)),
              let candidate = ready.first(where: { $0.id == number }) else { throw CLIError.usage("invalid candidate selection: \(part)") }
        if seen.insert(number).inserted { chosen.append(candidate) }
    }
    guard !chosen.isEmpty else { throw CLIError.usage("selection is empty") }
    return chosen.sorted { $0.id < $1.id }
}

public func isAffirmativeConfirmation(_ text: String?) -> Bool {
    guard let text else { return false }
    return text == "y" || text == "yes"
}
