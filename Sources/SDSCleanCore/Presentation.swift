import Foundation

public let sdsCleanVersion = "0.1.0"
public let promoURL = "https://motionobj.com/simplydisksweeper/?utm_source=sds-clean&utm_medium=cli&utm_campaign=cleanup-success"

public let modeSummary = """
sds-clean chooses a mode explicitly.
  sds-clean --dry-run  Report what is eligible without changes.
  sds-clean --delete   Review the complete plan, then confirm or cancel.
"""

public func byteString(_ bytes: UInt64?) -> String { guard let bytes else { return "unknown" }; return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file) }

public func renderReport(_ report: DiscoveryReport, dryRun: Bool = true) -> String {
    var lines = ["sds-clean \(report.version) — Cleanup plan", "", "Plan totals:", "  Permanent tool cleanup estimate: \(byteString(report.estimatedPermanentReclaimBytes))"]
    if report.unestimatedPermanentCandidateCount > 0 { lines.append("  Plus \(report.unestimatedPermanentCandidateCount) permanent command(s) with no reliable reclaim estimate (excluded from total)") }
    lines.append("  Move to Trash: \(byteString(report.plannedTrashBytes)) (recoverable; not freed until Trash is emptied)")
    if report.unestimatedTrashSelectionCount > 0 { lines.append("  Plus \(report.unestimatedTrashSelectionCount) Trash item(s) with unknown size (excluded from subtotal)") }
    lines += ["", "Permanent tool cleanup (files are removed permanently):"]
    let permanent = report.candidates.filter { $0.mechanism == .permanentCommand }
    if permanent.isEmpty { lines.append("  (none)") }
    for candidate in permanent {
        let measuredLabel = candidate.name == "Homebrew" ? "measured Homebrew cache" : "measured cache"
        let estimateLabel = candidate.name == "Homebrew" ? "Homebrew cleanup estimate" : "cleanup estimate"
        lines.append("- \(terminalSafe(candidate.name)) | \(measuredLabel) \(byteString(candidate.currentScopeBytes)) | \(estimateLabel) \(byteString(candidate.estimatedReclaimBytes))")
        lines.append("   measured path: \(terminalSafe(candidate.scope))")
        lines.append("   estimate basis: \(terminalSafe(candidate.estimateBasis))")
        if candidate.name == "Homebrew" { lines.append("   note: Homebrew's estimate can include old formula versions and other stale data outside the measured cache.") }
        if let command = candidate.command { lines.append("   executable: \(terminalSafe(command.path)) (\(terminalSafe(command.version).prefix(160)))") }
        if let argv = candidate.argv { lines.append("   argv: \(argv.map(shellDisplay).joined(separator: " "))") }
    }
    lines += ["", "Move to Trash (recoverable and still occupies disk):"]
    let trash = report.candidates.filter { $0.mechanism == .moveToTrash }
    if trash.isEmpty { lines.append("  (none)") }
    for candidate in trash {
        let count = candidate.eligibleItemCount.map { " | \($0) eligible item(s)" } ?? ""
        lines.append("- \(terminalSafe(candidate.name))\(count) | bytes moving to Trash \(byteString(candidate.trashMoveBytes))")
        if let path = candidate.filePath { lines.append("   item: \(terminalSafe(path))") }
        else { lines.append("   eligible items under: \(terminalSafe(candidate.scope))") }
    }
    if !report.notices.isEmpty { lines.append(""); lines.append("Notices:"); lines += report.notices.prefix(80).map { "- \(terminalSafe($0))" } }
    if dryRun { lines.append(""); lines.append("This is a dry run; no files will be deleted.") }
    return lines.joined(separator: "\n")
}

public func renderPlan(_ plan: ExecutionPlan) -> String {
    let permanentEstimate = plan.candidates.compactMap { $0.mechanism == .permanentCommand ? $0.estimatedReclaimBytes : nil }.reduce(0, &+)
    let unknown = plan.candidates.filter { $0.mechanism == .permanentCommand && $0.estimatedReclaimBytes == nil }.count
    let trashBytes = plan.candidates.compactMap { $0.mechanism == .moveToTrash ? $0.trashMoveBytes : nil }.reduce(0, &+)
    let unknownTrash = plan.candidates.filter { $0.mechanism == .moveToTrash && $0.trashMoveBytes == nil }.count
    var lines = ["Cleanup plan", "Permanent tool cleanup estimate: \(byteString(permanentEstimate))\(unknown > 0 ? " plus \(unknown) unestimated command(s)" : "")", "Move to Trash: \(byteString(trashBytes))\(unknownTrash > 0 ? " plus \(unknownTrash) item(s) with unknown size" : "") (not freed until Trash is emptied)", "Permanent commands:"]
    let commands = plan.candidates.filter { $0.mechanism == .permanentCommand }
    lines += commands.isEmpty ? ["  (none)"] : commands.map { "  - \(($0.argv ?? []).map(shellDisplay).joined(separator: " ")) | identity \($0.command?.device ?? 0):\($0.command?.inode ?? 0) | cleanup estimate \(byteString($0.estimatedReclaimBytes))" }
    lines.append("Move to Trash:")
    let files = plan.candidates.filter { $0.mechanism == .moveToTrash }
    lines += files.isEmpty ? ["  (none)"] : files.map {
        let count = $0.eligibleItemCount.map { " | \($0) eligible item(s)" } ?? ""
        return "  - \(terminalSafe($0.name))\(count) | move \(byteString($0.trashMoveBytes)) to Trash"
    }
    return lines.joined(separator: "\n")
}

private func shellDisplay(_ argument: String) -> String {
    if argument.allSatisfy({ $0.isLetter || $0.isNumber || "-_=./".contains($0) }) { return argument }
    return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
