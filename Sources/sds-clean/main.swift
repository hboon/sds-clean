import Darwin
import Foundation
import SDSCleanCore

let isTTY = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
let arguments = Array(CommandLine.arguments.dropFirst())
let help = """
Usage: sds-clean [--dry-run | --json | --delete]

Safely discover supported tool caches and an aggregate of Xcode DerivedData items
not modified today or yesterday. Downloads is one aggregate containing only
eligible old top-level installer/archive files.

  --dry-run             discover and print the full report; never mutate
  --json                stable JSON report; implies --dry-run
  --delete              show the complete plan, then confirm or cancel on a TTY
  --help                show this help
  --version             show version
"""

func finish(_ code: ExitCode) -> Never { fflush(stdout); fflush(stderr); exit(code.rawValue) }

do {
    let options = try parseArguments(arguments, isTTY: isTTY)
    if options.help { print(help); finish(.success) }
    if options.version { print(sdsCleanVersion); finish(.success) }
    if !options.dryRun && !options.delete { print(modeSummary); finish(.success) }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let report = Discoverer(home: home).discover(version: sdsCleanVersion)
    if options.json {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
        FileHandle.standardOutput.write(try encoder.encode(report)); print(); finish(.success)
    }
    print(renderReport(report, dryRun: options.dryRun))
    if !options.delete { finish(.success) }
    let plan = ExecutionPlan(candidates: report.candidates.filter { $0.status == .ready })
    guard !plan.candidates.isEmpty else { print("\nNothing eligible to clean."); finish(.success) }
    print("\nRun the complete plan above? Permanent commands cannot be undone; other items move to Trash. [y/N]: ", terminator: ""); fflush(stdout)
    guard isAffirmativeConfirmation(readLine()) else { print("Cancelled. Nothing changed."); finish(.success) }
    let cancellation = CancellationState()
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    source.setEventHandler { cancellation.cancel() }; source.resume()
    let outcomes = Executor(home: home).execute(plan, cancellation: cancellation)
    var failures = 0; var cleaned = 0
    print("\nResults:")
    for outcome in outcomes {
        let candidate = plan.candidates.first { $0.id == outcome.candidateID }
        let measurements: String
        if candidate?.mechanism == .moveToTrash, outcome.kind == .trashed {
            measurements = "planned Trash bytes \(byteString(outcome.beforeEstimateBytes)); moved to Trash"
        } else if candidate?.mechanism == .moveToTrash {
            measurements = "planned Trash bytes \(byteString(outcome.beforeEstimateBytes)); bytes not moved \(byteString(outcome.afterEstimateBytes))"
        } else {
            measurements = "measured cache before \(byteString(outcome.beforeEstimateBytes)); measured cache after \(byteString(outcome.afterEstimateBytes))"
        }
        let counts = outcome.succeededItemCount.map { " — \($0) succeeded, \(outcome.failedItemCount ?? 0) failed, \(outcome.notRunItemCount ?? 0) not run" } ?? ""
        let name = candidate?.name ?? "Cleanup item"
        print("- \(terminalSafe(name)): \(outcome.kind.rawValue)\(counts) — \(measurements) — \(terminalSafe(outcome.detail))")
        if outcome.kind == .commandSucceeded || outcome.kind == .trashed { cleaned += 1 }; if outcome.kind == .commandFailed || outcome.kind == .invalidated { failures += 1 }
    }
    if !outcomes.isEmpty { print("Inspect Trash before emptying it.") }
    if shouldShowPromo(isTTY: isTTY, environment: ProcessInfo.processInfo.environment, hadErrors: failures > 0, cleanedCount: cleaned, dryRun: false) {
        print("\nWant a visual review? The paid SimplyDiskSweeper Mac app lets you choose a folder and visually review large items: \(promoURL)")
    }
    if cancellation.isCancelled { finish(.cancelled) }
    if outcomes.contains(where: { $0.kind == .invalidated }) { finish(.invalidated) }
    finish(failures == 0 ? .success : .partial)
} catch let error as CLIError {
    fputs("sds-clean: \(error.description)\nTry 'sds-clean --help'.\n", stderr); finish(.usage)
} catch {
    fputs("sds-clean: \(error)\n", stderr); finish(.partial)
}
