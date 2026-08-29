import Foundation

public let sdsCleanVersion = "0.1.0"
public let promoURL = "https://motionobj.com/simplydisksweeper/?utm_source=sds-clean&utm_medium=cli&utm_campaign=cleanup-success"

public let modeSummary = """
sds-clean chooses a mode explicitly.
  sds-clean --dry-run  Report what is eligible without changes.
  sds-clean --delete   Start interactive cleanup with selection and confirmation.
"""

public func byteString(_ bytes: UInt64?) -> String { guard let bytes else { return "unknown" }; return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file) }

public func renderReport(_ report: DiscoveryReport, dryRun: Bool = true) -> String {
    let status = dryRun ? "DRY RUN: no cleanup commands will run and nothing will move to Trash." : "Discovery complete: nothing has changed and nothing is preselected."
    var lines = ["sds-clean \(report.version) — \(status)", "", "Overall estimate for the displayed selectable items:", "  Permanent cleanup: \(byteString(report.estimatedPermanentReclaimBytes)) estimated reclaim"]
    if report.unestimatedPermanentCandidateCount > 0 { lines.append("  Plus \(report.unestimatedPermanentCandidateCount) permanent command(s) with no reliable reclaim estimate (excluded from total)") }
    lines.append("  Move to Trash: \(byteString(report.bytesMovedToTrash)) (recoverable; not freed until Trash is emptied)")
    if report.unestimatedTrashCandidateCount > 0 { lines.append("  Plus \(report.unestimatedTrashCandidateCount) Trash selection(s) with unknown size (excluded from subtotal)") }
    lines += ["", "Permanent tool cleanup (selectable; files are removed permanently):"]
    let permanent = report.candidates.filter { $0.mechanism == .permanentCommand }
    if permanent.isEmpty { lines.append("  (none)") }
    for candidate in permanent {
        lines.append("\(candidate.id). \(terminalSafe(candidate.name)) | current scope \(byteString(candidate.currentScopeBytes)) | estimated reclaim \(byteString(candidate.estimatedReclaimBytes))")
        lines.append("   scope: \(terminalSafe(candidate.scope))")
        lines.append("   estimate: \(terminalSafe(candidate.estimateBasis))")
        if let command = candidate.command { lines.append("   executable: \(terminalSafe(command.path)) (\(terminalSafe(command.version).prefix(160)))") }
        if let argv = candidate.argv { lines.append("   argv: \(argv.map(shellDisplay).joined(separator: " "))") }
    }
    lines += ["", "Move to Trash (selectable; recoverable and still occupies disk):"]
    let trash = report.candidates.filter { $0.mechanism == .moveToTrash }
    if trash.isEmpty { lines.append("  (none)") }
    for candidate in trash {
        let count = candidate.eligibleItemCount.map { " | \($0) eligible item(s)" } ?? ""
        lines.append("\(candidate.id). \(terminalSafe(candidate.name))\(count) | total size \(byteString(candidate.trashMoveBytes))")
        if let path = candidate.filePath { lines.append("   item: \(terminalSafe(path))") }
    }
    lines += ["", "Downloads information:"]
    let reports = report.candidates.filter { $0.mechanism == .reportOnly }
    if reports.isEmpty { lines.append("  (none)") }
    for candidate in reports {
        lines.append("- \(terminalSafe(candidate.name)) | current scope \(byteString(candidate.currentScopeBytes))")
        lines.append("  \(terminalSafe(candidate.estimateBasis))")
        if let reason = candidate.reason { lines.append("  \(terminalSafe(reason))") }
    }
    if !report.notices.isEmpty { lines.append(""); lines.append("Notices:"); lines += report.notices.prefix(80).map { "- \(terminalSafe($0))" } }
    lines.append(""); lines.append(dryRun ? "No mutations performed." : "No mutations performed during discovery.")
    return lines.joined(separator: "\n")
}

public func renderPlan(_ plan: ExecutionPlan) -> String {
    let permanentEstimate = plan.candidates.compactMap { $0.mechanism == .permanentCommand ? $0.estimatedReclaimBytes : nil }.reduce(0, &+)
    let unknown = plan.candidates.filter { $0.mechanism == .permanentCommand && $0.estimatedReclaimBytes == nil }.count
    let trashBytes = plan.candidates.compactMap { $0.mechanism == .moveToTrash ? $0.trashMoveBytes : nil }.reduce(0, &+)
    let unknownTrash = plan.candidates.filter { $0.mechanism == .moveToTrash && $0.trashMoveBytes == nil }.count
    var lines = ["Planned cleanup", "Estimated permanent reclaim: \(byteString(permanentEstimate))\(unknown > 0 ? " plus \(unknown) unestimated command(s)" : "")", "Move to Trash: \(byteString(trashBytes))\(unknownTrash > 0 ? " plus \(unknownTrash) selection(s) with unknown size" : "") (not freed until Trash is emptied)", "Permanent commands:"]
    let commands = plan.candidates.filter { $0.mechanism == .permanentCommand }
    lines += commands.isEmpty ? ["  (none)"] : commands.map { "  \($0.id). \(($0.argv ?? []).map(shellDisplay).joined(separator: " ")) | identity \($0.command?.device ?? 0):\($0.command?.inode ?? 0) | estimated reclaim \(byteString($0.estimatedReclaimBytes))" }
    lines.append("Move to Trash:")
    let files = plan.candidates.filter { $0.mechanism == .moveToTrash }
    lines += files.isEmpty ? ["  (none)"] : files.map {
        let count = $0.eligibleItemCount.map { " | \($0) eligible item(s)" } ?? ""
        return "  \($0.id). \(terminalSafe($0.name))\(count) | move \(byteString($0.trashMoveBytes)) to Trash"
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
