import Foundation
import MCP

/// Handles MCP resource read requests for logic:// URIs.
struct ResourceHandlers {

    /// Handle a ReadResource request by URI.
    static func read(
        uri: String,
        cache: StateCache,
        router: ChannelRouter
    ) async throws -> ReadResource.Result {
        await cache.recordToolAccess()

        // Handle parameterized URIs like logic://tracks/{index}
        if uri.hasPrefix("logic://tracks/") {
            let indexStr = String(uri.dropFirst("logic://tracks/".count))
            if let index = Int(indexStr) {
                return try await readTrack(at: index, cache: cache, uri: uri)
            }
        }

        switch uri {
        case "logic://transport/state":
            return try await readTransportState(cache: cache, uri: uri)

        case "logic://tracks":
            return try await readTracks(cache: cache, uri: uri)

        case "logic://mixer":
            return try await readMixer(cache: cache, uri: uri)

        case "logic://project/info":
            return try await readProjectInfo(cache: cache, uri: uri)

        case "logic://midi/ports":
            return try await readMIDIPorts(router: router, uri: uri)

        case "logic://system/health":
            return try await readSystemHealth(cache: cache, router: router, uri: uri)

        default:
            throw MCPError.invalidParams("Unknown resource URI: \(uri)")
        }
    }

    // MARK: - Individual resource handlers

    private static func readTransportState(cache: StateCache, uri: String) async throws -> ReadResource.Result {
        let state = await cache.getTransport()
        let json = encodeJSON(state)
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }

    private static func readTracks(cache: StateCache, uri: String) async throws -> ReadResource.Result {
        let tracks = await cache.getTracks()
        let json = encodeJSON(tracks)
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }

    private static func readTrack(at index: Int, cache: StateCache, uri: String) async throws -> ReadResource.Result {
        if let track = await cache.getTrack(at: index) {
            let json = encodeJSON(track)
            return ReadResource.Result(
                contents: [.text(json, uri: uri, mimeType: "application/json")]
            )
        }
        throw MCPError.invalidParams("No track at index \(index)")
    }

    private static func readMixer(cache: StateCache, uri: String) async throws -> ReadResource.Result {
        let strips = await cache.getChannelStrips()
        let json = encodeJSON(strips)
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }

    private static func readProjectInfo(cache: StateCache, uri: String) async throws -> ReadResource.Result {
        let info = await cache.getProject()
        let json = encodeJSON(info)
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }

    private static func readMIDIPorts(router: ChannelRouter, uri: String) async throws -> ReadResource.Result {
        let result = await router.route(operation: "midi.list_ports")
        return ReadResource.Result(
            contents: [.text(result.message, uri: uri, mimeType: "application/json")]
        )
    }

    private static func readSystemHealth(
        cache: StateCache,
        router: ChannelRouter,
        uri: String
    ) async throws -> ReadResource.Result {
        let report = await router.healthReport()
        var channels: [[String: String]] = []
        for (id, health) in report.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            channels.append([
                "channel": id.rawValue,
                "available": String(health.available),
                "latency_ms": health.latencyMs.map { String(format: "%.1f", $0) } ?? "N/A",
                "detail": health.detail,
            ])
        }
        let snap = await cache.snapshot()
        let permissions = PermissionChecker.check()
        let channelsJSON = encodeJSON(channels)
        let json = """
            {
              "logic_pro_running": \(ProcessUtils.isLogicProRunning),
              "channels": \(channelsJSON),
              "cache": {
                "poll_mode": "\(snap.pollMode)",
                "transport_age_sec": \(String(format: "%.1f", snap.transportAge)),
                "track_count": \(snap.trackCount),
                "project": "\(snap.projectName)"
              },
              "permissions": {
                "accessibility": \(permissions.accessibility),
                "automation": \(permissions.automationLogicPro),
                "automation_detail": "\(permissions.automation.describedStatus)"
              }
            }
            """
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }
}
