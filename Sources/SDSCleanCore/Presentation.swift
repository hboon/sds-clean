import Foundation

public let sdsCleanVersion = "0.1.0"
public let promoURL = "https://motionobj.com/simplydisksweeper/?utm_source=sds-clean&utm_medium=cli&utm_campaign=cleanup-success"

public func byteString(_ bytes: UInt64?) -> String { guard let bytes else { return "unknown" }; return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file) }

public func renderReport(_ report: DiscoveryReport, dryRun: Bool = true) -> String {
    let status = dryRun ? "DRY RUN: no cleanup commands will run and nothing will move to Trash." : "Discovery complete: nothing has changed and nothing is preselected."
    var lines = ["sds-clean \(report.version) — \(status)", "", "Candidates:"]
    if report.candidates.isEmpty { lines.append("  (none)") }
    for candidate in report.candidates {
        let mechanism = candidate.mechanism == .permanentCommand ? "Permanent cleanup" : "Move to Trash"
        lines.append("\(candidate.id). \(terminalSafe(candidate.name)) | \(byteString(candidate.estimatedBytes)) | \(mechanism)")
        lines.append("   scope: \(terminalSafe(candidate.scope))")
        if let command = candidate.command { lines.append("   executable: \(terminalSafe(command.path)) (\(terminalSafe(command.version).prefix(160)))") }
        if let argv = candidate.argv { lines.append("   argv: \(argv.map(shellDisplay).joined(separator: " "))") }
        if let path = candidate.filePath { lines.append("   item: \(terminalSafe(path))") }
    }
    lines.append(""); lines.append("Downloads total: \(byteString(report.downloadsTotalBytes)) — \(report.downloadsNote)")
    if !report.notices.isEmpty { lines.append(""); lines.append("Notices:"); lines += report.notices.prefix(80).map { "- \(terminalSafe($0))" } }
    lines.append(""); lines.append(dryRun ? "No mutations performed." : "No mutations performed during discovery.")
    return lines.joined(separator: "\n")
}

public func renderPlan(_ plan: ExecutionPlan) -> String {
    var lines = ["Planned cleanup", "Permanent commands:"]
    let commands = plan.candidates.filter { $0.mechanism == .permanentCommand }
    lines += commands.isEmpty ? ["  (none)"] : commands.map { "  \($0.id). \(($0.argv ?? []).map(shellDisplay).joined(separator: " ")) | identity \($0.command?.device ?? 0):\($0.command?.inode ?? 0) | estimate \(byteString($0.estimatedBytes))" }
    lines.append("Move to Trash items:")
    let files = plan.candidates.filter { $0.mechanism == .moveToTrash }
    lines += files.isEmpty ? ["  (none)"] : files.map { "  \($0.id). \(terminalSafe($0.filePath ?? "")) | identity \($0.fileIdentity?.device ?? 0):\($0.fileIdentity?.inode ?? 0) | estimate \(byteString($0.estimatedBytes))" }
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
