import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// `LogicProMCP doctor` — walks every channel, prints a pass/fail/timing table.
/// Use to diagnose breakage after Apple Logic updates.
enum DoctorCommand {
    struct Result {
        let channel: String
        let available: Bool
        let latencyMs: Double
        let detail: String
    }

    static func run() async -> Int {
        // Force line buffering on stdout so the table is visible even if
        // the MCP server actor's lingering continuation fires SIGTRAP on
        // process teardown (it never gets a real transport in doctor mode).
        setvbuf(stdout, nil, _IOLBF, 0)

        let logicRunning = ProcessUtils.isLogicProRunning
        print("=== LogicProMCP doctor ===")
        print("Logic Pro running:", logicRunning ? "yes (pid \(ProcessUtils.logicProPID() ?? -1))" : "NO")
        print("")

        var results: [Result] = []
        let server = LogicProServer()
        // setupChannels() registers + starts channels without entering the
        // blocking MCP stdio loop that server.start() would.
        await server.setupChannels()

        for channelID in ChannelID.allCases {
            guard let channel = await server.channelRouter.channel(for: channelID) else {
                results.append(Result(channel: channelID.rawValue, available: false, latencyMs: 0, detail: "not registered"))
                continue
            }
            let start = Date()
            let health = await channel.healthCheck()
            let elapsed = Date().timeIntervalSince(start) * 1000
            results.append(Result(channel: channelID.rawValue, available: health.available, latencyMs: elapsed, detail: health.detail))
        }

        // Print table BEFORE stopping channels — channel shutdown can SIGSEGV
        // on certain configurations (continuation misuse in MCP/Network
        // teardown). The report is the point of the command, so emit it first.
        let header = "Channel".padding(toLength: 16, withPad: " ", startingAt: 0)
            + "Status".padding(toLength: 8, withPad: " ", startingAt: 0)
            + "Latency".padding(toLength: 12, withPad: " ", startingAt: 0)
            + "Detail"
        print(header)
        print(String(repeating: "-", count: 72))
        var anyFail = false
        for r in results {
            let status = r.available ? "✓ OK" : "✗ FAIL"
            if !r.available { anyFail = true }
            let latency = String(format: "%.1f ms", r.latencyMs)
            let row = r.channel.padding(toLength: 16, withPad: " ", startingAt: 0)
                + status.padding(toLength: 8, withPad: " ", startingAt: 0)
                + latency.padding(toLength: 12, withPad: " ", startingAt: 0)
                + r.detail
            print(row)
        }
        print("")
        if anyFail {
            print("One or more channels unhealthy. See details above.")
        } else {
            print("All channels healthy.")
        }
        fflush(stdout)

        await server.stop()
        return anyFail ? 1 : 0
    }
}
