import Foundation

/// Adaptive background poller that reads Logic Pro state via the Accessibility channel
/// and updates the StateCache. Poll frequency adapts based on how recently tools were called.
actor StatePoller {
    private let axChannel: AccessibilityChannel
    private let cache: StateCache
    private var pollingTask: Task<Void, Never>?

    init(axChannel: AccessibilityChannel, cache: StateCache) {
        self.axChannel = axChannel
        self.cache = cache
    }

    /// Start the background polling loop.
    func start() {
        guard pollingTask == nil else {
            Log.warn("StatePoller already running", subsystem: "poller")
            return
        }
        pollingTask = Task { [axChannel, cache] in
            Log.info("StatePoller started", subsystem: "poller")
            await pollLoop(axChannel: axChannel, cache: cache)
        }
    }

    /// Stop the polling loop.
    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        Log.info("StatePoller stopped", subsystem: "poller")
    }

    /// Whether the poller is currently running.
    var isRunning: Bool {
        pollingTask != nil && pollingTask?.isCancelled == false
    }

    // MARK: - Poll loop

    private func pollLoop(axChannel: AccessibilityChannel, cache: StateCache) async {
        var transportCounter: UInt64 = 0

        while !Task.isCancelled {
            let idle = await cache.timeSinceLastToolAccess()
            let interval: PollInterval = Self.intervalForIdleTime(idle)

            // Always poll transport (it changes most frequently)
            await pollTransport(axChannel: axChannel, cache: cache)
            transportCounter += 1

            // Poll tracks/mixer less frequently.
            // In active mode, poll tracks every 4 transport cycles (~2s at 500ms).
            // In light/idle mode, poll every cycle since the interval is already longer.
            let shouldPollTracks: Bool
            switch interval.mode {
            case .active:
                shouldPollTracks = transportCounter % 4 == 0
            case .light, .idle:
                shouldPollTracks = true
            }

            if shouldPollTracks {
                await pollTracks(axChannel: axChannel, cache: cache)
                await pollMixer(axChannel: axChannel, cache: cache)
                // Poll the project last so it can fold in the track/transport
                // values refreshed above.
                await pollProject(axChannel: axChannel, cache: cache)
            }

            // Sleep until next poll
            do {
                try await Task.sleep(nanoseconds: interval.nanoseconds)
            } catch {
                // Task was cancelled during sleep
                break
            }
        }

        Log.info("StatePoller loop exited", subsystem: "poller")
    }

    // MARK: - Individual pollers

    private func pollTransport(axChannel: AccessibilityChannel, cache: StateCache) async {
        let result = await axChannel.execute(operation: "transport.get_state", params: [:])
        guard case .success(let json) = result else {
            Log.debug("Transport poll failed: \(result.message)", subsystem: "poller")
            return
        }
        guard let data = json.data(using: .utf8) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let state = try decoder.decode(TransportState.self, from: data)
            await cache.updateTransport(state)
        } catch {
            Log.debug("Transport decode failed: \(error)", subsystem: "poller")
        }
    }

    private func pollTracks(axChannel: AccessibilityChannel, cache: StateCache) async {
        let result = await axChannel.execute(operation: "track.get_tracks", params: [:])
        guard case .success(let json) = result else {
            Log.debug("Tracks poll failed: \(result.message)", subsystem: "poller")
            return
        }
        guard let data = json.data(using: .utf8) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let tracks = try decoder.decode([TrackState].self, from: data)
            await cache.updateTracks(tracks)
        } catch {
            Log.debug("Tracks decode failed: \(error)", subsystem: "poller")
        }
    }

    private func pollMixer(axChannel: AccessibilityChannel, cache: StateCache) async {
        let result = await axChannel.execute(operation: "mixer.get_state", params: [:])
        guard case .success(let json) = result else {
            // Expected whenever the Mixer pane is hidden — AX can only read visible UI.
            Log.debug("Mixer poll failed: \(result.message)", subsystem: "poller")
            return
        }
        guard let data = json.data(using: .utf8) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let strips = try decoder.decode([ChannelStripState].self, from: data)
            await cache.updateChannelStrips(strips)
        } catch {
            Log.debug("Mixer decode failed: \(error)", subsystem: "poller")
        }
    }

    private func pollProject(axChannel: AccessibilityChannel, cache: StateCache) async {
        let result = await axChannel.execute(operation: "project.get_info", params: [:])
        guard case .success(let json) = result else {
            Log.debug("Project poll failed: \(result.message)", subsystem: "poller")
            return
        }
        guard let data = json.data(using: .utf8) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var info = try decoder.decode(ProjectInfo.self, from: data)
            // project.get_info reads the window title only. Fill the remaining
            // fields from state the poller already refreshed, so the resource
            // reports a coherent snapshot instead of struct defaults.
            let transport = await cache.getTransport()
            info.trackCount = await cache.getTracks().count
            info.tempo = transport.tempo
            info.sampleRate = transport.sampleRate
            await cache.updateProject(info)
        } catch {
            Log.debug("Project decode failed: \(error)", subsystem: "poller")
        }
    }

    // MARK: - Adaptive interval

    private enum PollMode {
        case active  // <5s idle
        case light   // 5-30s idle
        case idle    // >30s idle
    }

    private struct PollInterval {
        let mode: PollMode
        let nanoseconds: UInt64
    }

    private static func intervalForIdleTime(_ idle: TimeInterval) -> PollInterval {
        if idle < ServerConfig.lightIdleThreshold {
            return PollInterval(
                mode: .active,
                nanoseconds: UInt64(ServerConfig.activeTransportPollInterval * 1_000_000_000)
            )
        } else if idle < ServerConfig.idleThreshold {
            return PollInterval(
                mode: .light,
                nanoseconds: UInt64(ServerConfig.lightPollInterval * 1_000_000_000)
            )
        } else {
            return PollInterval(
                mode: .idle,
                nanoseconds: UInt64(ServerConfig.idlePollInterval * 1_000_000_000)
            )
        }
    }
}
