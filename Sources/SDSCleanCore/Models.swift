import Foundation

public enum Mechanism: String, Codable, Sendable { case permanentCommand, moveToTrash, reportOnly }
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

public struct TrashMember: Equatable, Sendable {
    public let path: String
    public let identity: FileIdentity
    public let bytes: UInt64?
    public init(path: String, identity: FileIdentity, bytes: UInt64?) {
        self.path = path; self.identity = identity; self.bytes = bytes
    }
}

public struct CleanupCandidate: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let mechanism: Mechanism
    public let currentScopeBytes: UInt64?
    public let estimatedReclaimBytes: UInt64?
    public let trashMoveBytes: UInt64?
    public let estimateBasis: String
    public let scope: String
    public let status: CandidateStatus
    public let reason: String?
    public let command: CommandIdentity?
    public let argv: [String]?
    public let cacheScopes: [CacheScopeIdentity]?
    public let filePath: String?
    public let fileIdentity: FileIdentity?
    public let eligibleItemCount: Int?
    public let eligibleItemBytes: UInt64?
    public private(set) var executionMembers: [TrashMember] = []
    public init(id: Int, name: String, mechanism: Mechanism, currentScopeBytes: UInt64?, estimatedReclaimBytes: UInt64?, trashMoveBytes: UInt64?, estimateBasis: String, scope: String, status: CandidateStatus, reason: String?, command: CommandIdentity?, argv: [String]?, cacheScopes: [CacheScopeIdentity]? = nil, filePath: String?, fileIdentity: FileIdentity?, eligibleItemCount: Int? = nil, eligibleItemBytes: UInt64? = nil, executionMembers: [TrashMember] = []) {
        self.id = id; self.name = name; self.mechanism = mechanism; self.currentScopeBytes = currentScopeBytes; self.estimatedReclaimBytes = estimatedReclaimBytes; self.trashMoveBytes = trashMoveBytes; self.estimateBasis = estimateBasis; self.scope = scope; self.status = status; self.reason = reason; self.command = command; self.argv = argv; self.cacheScopes = cacheScopes; self.filePath = filePath; self.fileIdentity = fileIdentity; self.eligibleItemCount = eligibleItemCount; self.eligibleItemBytes = eligibleItemBytes; self.executionMembers = executionMembers
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, mechanism, currentScopeBytes, estimatedReclaimBytes, trashMoveBytes, estimateBasis, scope, status, reason, command, argv, cacheScopes, filePath, fileIdentity, eligibleItemCount, eligibleItemBytes
    }
}

public struct DiscoveryReport: Codable, Sendable {
    public let schemaVersion: Int
    public let version: String
    public let dryRun: Bool
    public let mutationPerformed: Bool
    public let estimatedPermanentReclaimBytes: UInt64
    public let unestimatedPermanentCandidateCount: Int
    public let bytesMovedToTrash: UInt64
    public let unestimatedTrashCandidateCount: Int
    public let candidates: [CleanupCandidate]
    public let notices: [String]
    public init(schemaVersion: Int = 3, version: String, dryRun: Bool, mutationPerformed: Bool, candidates: [CleanupCandidate], notices: [String]) {
        self.schemaVersion = schemaVersion; self.version = version; self.dryRun = dryRun; self.mutationPerformed = mutationPerformed
        let ready = candidates.filter { $0.status == .ready }
        self.estimatedPermanentReclaimBytes = ready.compactMap { $0.mechanism == .permanentCommand ? $0.estimatedReclaimBytes : nil }.reduce(0, &+)
        self.unestimatedPermanentCandidateCount = ready.filter { $0.mechanism == .permanentCommand && $0.estimatedReclaimBytes == nil }.count
        self.bytesMovedToTrash = ready.compactMap { $0.mechanism == .moveToTrash ? $0.trashMoveBytes : nil }.reduce(0, &+)
        self.unestimatedTrashCandidateCount = ready.filter { $0.mechanism == .moveToTrash && $0.trashMoveBytes == nil }.count
        self.candidates = candidates; self.notices = notices
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
    public let succeededItemCount: Int?
    public let failedItemCount: Int?
    public let notRunItemCount: Int?
    public init(candidateID: Int, kind: OutcomeKind, exitCode: Int32?, beforeEstimateBytes: UInt64? = nil, afterEstimateBytes: UInt64? = nil, detail: String, succeededItemCount: Int? = nil, failedItemCount: Int? = nil, notRunItemCount: Int? = nil) {
        self.candidateID = candidateID; self.kind = kind; self.exitCode = exitCode; self.beforeEstimateBytes = beforeEstimateBytes; self.afterEstimateBytes = afterEstimateBytes; self.detail = detail; self.succeededItemCount = succeededItemCount; self.failedItemCount = failedItemCount; self.notRunItemCount = notRunItemCount
    }
}

public enum ExitCode: Int32 { case success = 0, usage = 2, partial = 3, invalidated = 4, cancelled = 130 }

public struct CLIOptions: Equatable {
    public var dryRun = false
    public var json = false
    public var delete = false
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
    var result = CLIOptions(); var index = 0; var modes = Set<String>()
    while index < arguments.count {
        switch arguments[index] {
        case "--dry-run": result.dryRun = true; modes.insert("dry-run")
        case "--json": result.json = true; result.dryRun = true; modes.insert("json")
        case "--delete": result.delete = true; modes.insert("delete")
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
    if result.help || result.version {
        guard arguments.count == 1 else { throw CLIError.usage("--help and --version must be used on their own") }
        return result
    }
    guard modes.count <= 1 else { throw CLIError.usage("choose exactly one mode: --dry-run, --json, or --delete") }
    if result.yes && result.selection == nil { throw CLIError.usage("--yes requires --select <numbers|all>") }
    if result.selection != nil && !result.yes { throw CLIError.usage("--select is only valid with --yes") }
    if (result.yes || result.selection != nil) && !result.delete { throw CLIError.usage("--yes and --select require --delete") }
    if result.yes && !isTTY { throw CLIError.usage("--yes cleanup requires an interactive TTY") }
    if result.delete && !isTTY { throw CLIError.usage("--delete requires an interactive TTY") }
    return result
}

public func parseSelection(_ text: String, candidates: [CleanupCandidate]) throws -> [CleanupCandidate] {
    let ready = candidates.filter { $0.status == .ready }
    if text.lowercased() == "all" {
        guard !ready.isEmpty else { throw CLIError.usage("selection is empty") }
        return ready
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
