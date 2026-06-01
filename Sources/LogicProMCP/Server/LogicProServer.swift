import Foundation
import MCP

/// Main MCP server for Logic Pro integration.
/// Exposes 8 dispatcher tools + 7 resources, routing through
/// the ChannelRouter to the appropriate macOS communication channel.
actor LogicProServer {
    private let server: Server
    private let router: ChannelRouter
    private let cache: StateCache
    private let poller: StatePoller

    /// Read-only accessor used by doctor / introspection.
    nonisolated var channelRouter: ChannelRouter { router }

    // Channel instances
    private let axChannel: AccessibilityChannel
    private let cgEventChannel: CGEventChannel
    private let appleScriptChannel: AppleScriptChannel
    private let coreMIDIChannel: CoreMIDIChannel
    private let oscChannel: OSCChannel

    init() {
        self.server = Server(
            name: ServerConfig.serverName,
            version: ServerConfig.serverVersion,
            capabilities: .init(
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: false)
            )
        )

        self.router = ChannelRouter()
        self.cache = StateCache()

        // Create channel instances
        let midiEngine = MIDIEngine()
        self.coreMIDIChannel = CoreMIDIChannel(engine: midiEngine)

        let oscClient = OSCClient()
        let oscServer = OSCServer()
        self.oscChannel = OSCChannel(client: oscClient, server: oscServer)

        self.axChannel = AccessibilityChannel()
        self.cgEventChannel = CGEventChannel()
        self.appleScriptChannel = AppleScriptChannel()

        self.poller = StatePoller(axChannel: axChannel, cache: cache)
    }

    // MARK: - Tool Registration (8 dispatchers)

    private func registerTools() async {
        let allTools: [Tool] = [
            TransportDispatcher.tool,
            TrackDispatcher.tool,
            MixerDispatcher.tool,
            MIDIDispatcher.tool,
            EditDispatcher.tool,
            NavigateDispatcher.tool,
            ProjectDispatcher.tool,
            SystemDispatcher.tool,
        ]

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: allTools)
        }

        // Capture for closures
        let router = self.router
        let cache = self.cache

        await server.withMethodHandler(CallTool.self) { params in
            let name = params.name
            let command = params.arguments?["command"]?.stringValue ?? ""
            let cmdParams: [String: Value] = params.arguments?["params"]?.objectValue ?? [:]

            await cache.recordToolAccess()

            switch name {
            case "logic_transport":
                return await TransportDispatcher.handle(
                    command: command, params: cmdParams, router: router, cache: cache
                )

            case "logic_tracks":
                return await TrackDispatcher.handle(
                    command: command, params: cmdParams, router: router, cache: cache
                )

            case "logic_mixer":
                return await MixerDispatcher.handle(
                    command: command, params: cmdParams, router: router, cache: cache
                )

            case "logic_midi":
                return await MIDIDispatcher.handle(
                    command: command, params: cmdParams, router: router, cache: cache
                )

            case "logic_edit":
                return await EditDispatcher.handle(
                    command: command, params: cmdParams, router: router, cache: cache
                )

            case "logic_navigate":
                return await NavigateDispatcher.handle(
                    command: command, params: cmdParams, router: router, cache: cache
                )

            case "logic_project":
                return await ProjectDispatcher.handle(
                    command: command, params: cmdParams, router: router, cache: cache
                )

            case "logic_system":
                return await SystemDispatcher.handle(
                    command: command, params: cmdParams, router: router, cache: cache
                )

            default:
                return CallTool.Result(
                    content: [.text("Unknown tool: \(name). Available: logic_transport, logic_tracks, logic_mixer, logic_midi, logic_edit, logic_navigate, logic_project, logic_system")],
                    isError: true
                )
            }
        }
    }

    // MARK: - Resource Registration (7 resources)

    private func registerResources() async {
        let router = self.router
        let cache = self.cache

        await server.withMethodHandler(ListResources.self) { _ in
            ListResources.Result(resources: ResourceProvider.resources, nextCursor: nil)
        }

        await server.withMethodHandler(ReadResource.self) { params in
            try await ResourceHandlers.read(
                uri: params.uri,
                cache: cache,
                router: router
            )
        }

        await server.withMethodHandler(ListResourceTemplates.self) { _ in
            ListResourceTemplates.Result(templates: ResourceProvider.templates)
        }
    }

    // MARK: - Server Lifecycle

    /// Register channels with the router and start them. Used by both
    /// the full server lifecycle and the `doctor` subcommand.
    func setupChannels() async {
        await router.register(coreMIDIChannel)
        await router.register(oscChannel)
        await router.register(axChannel)
        await router.register(cgEventChannel)
        await router.register(appleScriptChannel)

        await router.startAll()
    }

    /// Start the server: register channels, start poller, begin MCP transport.
    func start() async throws {
        await setupChannels()

        // Start the state poller
        await poller.start()

        // Register tool handlers and resources
        await registerTools()
        await registerResources()

        Log.info(
            "Starting \(ServerConfig.serverName) v\(ServerConfig.serverVersion) — 8 tools, 7 resources",
            subsystem: "server"
        )

        // Start MCP server with stdio transport
        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()

        // Cleanup
        await poller.stop()
        await router.stopAll()
    }

    /// Tear down channels and the poller. Used by `doctor` and any caller
    /// that drove `setupChannels()` directly without entering the MCP loop.
    func stop() async {
        await poller.stop()
        await router.stopAll()
    }
}
