import ArgumentParser
import Foundation
import TouchBridgeCore

// MARK: - Logs

struct Logs: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "View recent authentication events from the audit log."
    )

    @Option(name: .long, help: "Number of recent entries to show (default: 20).")
    var count: Int = 20

    @Option(name: .long, help: "Filter by surface (e.g., pam_sudo, pam_screensaver).")
    var surface: String?

    @Option(name: .long, help: "Filter by result (e.g., VERIFIED, FAILED_TIMEOUT).")
    var result: String?

    @Flag(name: .long, help: "Show entries as raw JSON.")
    var json: Bool = false

    @Flag(name: .long, help: "Show only failures.")
    var failures: Bool = false

    @Flag(name: .long, help: "Show summary statistics.")
    var summary: Bool = false

    @Option(name: .long, help: "Export format: csv or json.")
    var export: String?

    func run() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let logDir = "\(home)/Library/Logs/TouchBridge"

        guard FileManager.default.fileExists(atPath: logDir) else {
            print("No log directory found at \(logDir)")
            return
        }

        let allEntries = try loadEntries(logDir: logDir)

        if allEntries.isEmpty {
            print("No matching log entries found.")
            return
        }

        if summary {
            printSummary(allEntries.map(\.1))
            return
        }

        if let export {
            switch export {
            case "csv": exportCSV(allEntries)
            case "json":
                for (raw, _) in allEntries.reversed() { print(raw) }
            default:
                print("Unknown export format: \(export). Use 'csv' or 'json'.")
            }
            return
        }

        if json {
            for (raw, _) in allEntries.prefix(count).reversed() { print(raw) }
            return
        }

        // Pretty print
        let showing = Array(allEntries.prefix(count))
        print("TouchBridge Audit Log (last \(showing.count) entries)")
        print(String(repeating: "─", count: 85))

        for (_, entry) in showing.reversed() {
            let icon: String
            switch entry.result {
            case "VERIFIED": icon = "✓"
            case "ISSUED": icon = "→"
            default: icon = "✗"
            }

            var line = "\(icon) \(entry.ts)  \(entry.surface.padding(toLength: 18, withPad: " ", startingAt: 0))"
            line += " \(entry.result.padding(toLength: 18, withPad: " ", startingAt: 0))"

            if !entry.companionDevice.isEmpty {
                line += " [\(entry.companionDevice)]"
            }

            if let latency = entry.latencyMs {
                line += " \(latency)ms"
            }

            print(line)
        }

        print(String(repeating: "─", count: 85))
        print("\(showing.count) entries shown. Logs at: \(logDir)")
        print("Tip: use --summary for stats, --failures for errors, --export csv for export")
    }

    private func loadEntries(logDir: String) throws -> [(String, AuditEntry)] {
        let files = try FileManager.default.contentsOfDirectory(atPath: logDir)
            .filter { $0.hasSuffix(".ndjson") }
            .sorted()
            .reversed()

        var entries: [(String, AuditEntry)] = []
        let decoder = JSONDecoder()
        let maxLoad = summary ? 10000 : count

        for file in files {
            let path = "\(logDir)/\(file)"
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }

            for line in content.split(separator: "\n").reversed() {
                guard let data = line.data(using: .utf8),
                      let entry = try? decoder.decode(AuditEntry.self, from: data) else { continue }

                if let surface, entry.surface != surface { continue }
                if let result, entry.result != result { continue }
                if failures && entry.result == "VERIFIED" { continue }

                entries.append((String(line), entry))
                if entries.count >= maxLoad { break }
            }
            if entries.count >= maxLoad { break }
        }

        return entries
    }

    private func printSummary(_ entries: [AuditEntry]) {
        let total = entries.count
        let verified = entries.filter { $0.result == "VERIFIED" }.count
        let failed = total - verified
        let successRate = total > 0 ? Double(verified) / Double(total) * 100 : 0

        let latencies = entries.compactMap(\.latencyMs)
        let avgLatency = latencies.isEmpty ? 0 : latencies.reduce(0, +) / latencies.count

        // Group by surface
        var bySurface: [String: (total: Int, verified: Int)] = [:]
        for entry in entries {
            var s = bySurface[entry.surface] ?? (0, 0)
            s.total += 1
            if entry.result == "VERIFIED" { s.verified += 1 }
            bySurface[entry.surface] = s
        }

        // Group by result
        var byResult: [String: Int] = [:]
        for entry in entries {
            byResult[entry.result, default: 0] += 1
        }

        // Group by device
        var byDevice: [String: Int] = [:]
        for entry in entries where !entry.companionDevice.isEmpty {
            byDevice[entry.companionDevice, default: 0] += 1
        }

        print("TouchBridge — Authentication Summary")
        print(String(repeating: "═", count: 50))
        print("")
        print("  Total events:    \(total)")
        print("  Successful:      \(verified) (\(String(format: "%.1f", successRate))%)")
        print("  Failed:          \(failed)")
        print("  Avg latency:     \(avgLatency)ms")
        print("")

        print("  By Result:")
        for (result, count) in byResult.sorted(by: { $0.value > $1.value }) {
            let icon = result == "VERIFIED" ? "✓" : "✗"
            print("    \(icon) \(result.padding(toLength: 22, withPad: " ", startingAt: 0)) \(count)")
        }
        print("")

        print("  By Surface:")
        for (surface, stats) in bySurface.sorted(by: { $0.value.total > $1.value.total }) {
            let rate = stats.total > 0 ? Double(stats.verified) / Double(stats.total) * 100 : 0
            print("    \(surface.padding(toLength: 22, withPad: " ", startingAt: 0)) \(stats.total) events (\(String(format: "%.0f", rate))% success)")
        }
        print("")

        if !byDevice.isEmpty {
            print("  By Device:")
            for (device, count) in byDevice.sorted(by: { $0.value > $1.value }) {
                print("    \(device.padding(toLength: 22, withPad: " ", startingAt: 0)) \(count) events")
            }
            print("")
        }

        print(String(repeating: "═", count: 50))
    }

    private func exportCSV(_ entries: [(String, AuditEntry)]) {
        print("timestamp,surface,result,device,auth_type,latency_ms")
        for (_, entry) in entries.reversed() {
            let latency = entry.latencyMs.map(String.init) ?? ""
            print("\(entry.ts),\(entry.surface),\(entry.result),\(entry.companionDevice),\(entry.authType),\(latency)")
        }
    }
}
