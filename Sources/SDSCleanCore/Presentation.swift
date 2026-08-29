import Foundation

public let sdsCleanVersion = "0.1.0"
public let promoURL = "https://motionobj.com/simplydisksweeper/?utm_source=sds-clean&utm_medium=cli&utm_campaign=cleanup-success"

public let modeSummary = """
sds-clean chooses a mode explicitly.
  sds-clean --dry-run  Report what is eligible without changes.
  sds-clean --delete   Review the complete plan, then confirm or cancel.
"""

public func byteString(_ bytes: UInt64?) -> String { guard let bytes else { return "unknown" }; if bytes == 0 { return "0 bytes" }; return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file) }
public func allocatedByteString(_ bytes: UInt64?) -> String { guard let bytes else { return "unknown" }; return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .binary) }

public func renderReport(_ report: DiscoveryReport, dryRun: Bool = true) -> String {
    var lines = compactPlanLines(candidates: report.candidates.filter { $0.status == .ready })
    if dryRun { lines.append(""); lines.append("This is a dry run; no files will be deleted.") }
    return lines.joined(separator: "\n")
}

public func renderPlan(_ plan: ExecutionPlan) -> String {
    compactPlanLines(candidates: plan.candidates).joined(separator: "\n")
}

private func compactPlanLines(candidates: [CleanupCandidate]) -> [String] {
    let permanent = candidates.filter { $0.mechanism == .permanentCommand }
    let trash = candidates.filter { $0.mechanism == .moveToTrash }
    let permanentBytes = permanent.compactMap(\.estimatedReclaimBytes).reduce(0, &+)
    let trashBytes = trash.compactMap(\.trashMoveBytes).reduce(0, &+)
    let hasUnavailableEstimate = permanent.contains { $0.estimatedReclaimBytes == nil } || trash.contains { $0.trashMoveBytes == nil }
    let totalQualifier = hasUnavailableEstimate ? " plus items with unavailable estimates" : ""
    var lines = [
        "Estimated disk cleanup: \(byteString(permanentBytes &+ trashBytes))\(totalQualifier)",
        "  Permanent: \(byteString(permanentBytes))",
        "  Move to Trash: \(byteString(trashBytes)) (you can undo by restoring from Trash)",
    ]
    if !permanent.isEmpty {
        lines += ["", "Permanent: \(byteString(permanentBytes))"]
        lines += permanent.map { "- \(terminalSafe($0.name)): \(estimateString($0.estimatedReclaimBytes))" }
    }
    if !trash.isEmpty {
        lines += ["", "Move to Trash: \(byteString(trashBytes))"]
        lines += trash.map { candidate in
            let estimate = estimateString(candidate.trashMoveBytes)
            guard candidate.name == "Downloads", let total = candidate.totalScopeBytes else { return "- \(terminalSafe(candidate.name)): \(estimate)" }
            return "- Downloads: \(estimate) eligible (\(allocatedByteString(total)) total)"
        }
    }
    return lines
}

private func estimateString(_ bytes: UInt64?) -> String {
    bytes.map { byteString($0) } ?? "estimate unavailable"
}

public func terminalSafe(_ text: String) -> String {
    text.unicodeScalars.map { scalar in
        if scalar.value < 32 || scalar.value == 127 { return "\\u{\(String(scalar.value, radix: 16))}" }
        return String(scalar)
    }.joined()
}

public func shouldShowPromo(isTTY: Bool, environment: [String: String], hadErrors: Bool, cleanedCount: Int, dryRun: Bool) -> Bool {
    isTTY && !dryRun && !hadErrors && cleanedCount > 0 && environment["CI"] == nil && environment["SDS_NO_PROMO"] != "1"
}
