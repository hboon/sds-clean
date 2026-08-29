import Darwin
import Foundation
import SDSCleanCore

let isTTY = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
let arguments = Array(CommandLine.arguments.dropFirst())
let help = """
Usage: sds-clean [--dry-run | --json] [--yes --select <numbers|all>]

Safely discover selected tool caches and an aggregate of Xcode DerivedData items
not modified today or yesterday. Downloads is shown once for information; this
CLI will not clean or move anything in Downloads. Nothing is selected by default.

  --dry-run             discover and print the full report; never mutate
  --json                stable JSON report; implies --dry-run
  --yes --select VALUE  execute a fully visible plan on a TTY (VALUE: numbers or all)
  --help                show this help
  --version             show version
"""

func finish(_ code: ExitCode) -> Never { fflush(stdout); fflush(stderr); exit(code.rawValue) }

do {
    let options = try parseArguments(arguments, isTTY: isTTY)
    if options.help { print(help); finish(.success) }
    if options.version { print(sdsCleanVersion); finish(.success) }
    if !options.dryRun && !isTTY { throw CLIError.usage("interactive cleanup requires a TTY; use --dry-run or --json") }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let report = Discoverer(home: home).discover(version: sdsCleanVersion)
    if options.json {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
        FileHandle.standardOutput.write(try encoder.encode(report)); print(); finish(.success)
    }
    print(renderReport(report, dryRun: options.dryRun))
    if options.dryRun { finish(.success) }
    let selectionText: String
    if options.yes { selectionText = options.selection! }
    else {
        print("\nSelect candidate numbers separated by commas, or all. Empty input cancels: ", terminator: ""); fflush(stdout)
        guard let input = readLine(), !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { print("Cancelled. Nothing changed."); finish(.success) }
        selectionText = input
    }
    let selected = try parseSelection(selectionText, candidates: report.candidates)
    let plan = ExecutionPlan(candidates: selected)
    print("\n\(renderPlan(plan))")
    if !options.yes {
        print("\nRun exactly the numbered plan above? Permanent commands cannot be undone; other items move to Trash. [y/N]: ", terminator: ""); fflush(stdout)
        guard isAffirmativeConfirmation(readLine()) else { print("Cancelled. Nothing changed."); finish(.success) }
    }
    let cancellation = CancellationState()
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    source.setEventHandler { cancellation.cancel() }; source.resume()
    let outcomes = Executor(home: home).execute(plan, cancellation: cancellation)
    var failures = 0; var cleaned = 0
    print("\nResults:")
    for outcome in outcomes {
        let estimates = "before \(byteString(outcome.beforeEstimateBytes)); after \(byteString(outcome.afterEstimateBytes))"
        let counts = outcome.succeededItemCount.map { " — \($0) succeeded, \(outcome.failedItemCount ?? 0) failed, \(outcome.notRunItemCount ?? 0) not run" } ?? ""
        print("- \(outcome.candidateID): \(outcome.kind.rawValue)\(counts) — \(estimates) — \(terminalSafe(outcome.detail))")
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
