# Logic Pro MCP Server

[![Swift 6.0+](https://img.shields.io/badge/Swift-6.0+-F05138.svg)](https://swift.org)
[![macOS 14+](https://img.shields.io/badge/macOS-14+-000000.svg?logo=apple)](https://developer.apple.com/macos/)
[![MCP SDK 0.12](https://img.shields.io/badge/MCP_SDK-0.12-blue.svg)](https://github.com/modelcontextprotocol/swift-sdk)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Bidirectional, stateful control of Logic Pro from AI assistants. Combines **5 native macOS control channels** (CoreMIDI, Accessibility, CGEvent, AppleScript, OSC) into a single MCP server with smart routing, fallback chains, and sub-millisecond transport latency.

**8 tools, 7 resources, ~3k context tokens.** Not 100+ individual tools.

## How It Works

```
Claude ──── 8 dispatcher tools ──── logic_transport("play", {})
         │                           logic_tracks("mute", {track: 3})
         │  7 MCP resources ──────── logic://transport/state
         │  (zero tool cost)         logic://tracks
         ▼
   ┌─── LogicProMCP ──────────────────────────────┐
   │  Command Dispatcher → Channel Router          │
   │     │       │       │       │       │         │
   │  CoreMIDI   AX    CGEvent  AS     OSC        │
   │   <1ms    ~15ms    <2ms   ~200ms  <1ms       │
   └───────────────────────────────────────────────┘
```

Each command routes through the fastest available channel, with automatic fallback if the primary fails.

## Tools & Resources

### Tools (8 dispatchers — all actions)

| Tool | Commands | Examples |
|------|----------|----------|
| `logic_transport` | play, stop, record, set_tempo, goto_position... | `logic_transport("set_tempo", {tempo: 140})` |
| `logic_tracks` | select, create_audio, mute, solo, arm, rename... | `logic_tracks("mute", {index: 2, enabled: true})` |
| `logic_mixer` | set_volume, set_pan, insert_plugin, bypass_plugin... | `logic_mixer("set_volume", {track: 0, value: 0.8})` |
| `logic_midi` | send_note, send_cc, send_chord, mmc_play... | `logic_midi("send_note", {note: 60, velocity: 100, channel: 1, duration_ms: 500})` |
| `logic_edit` | undo, redo, cut, copy, paste, quantize, split... | `logic_edit("quantize", {value: "1/16"})` |
| `logic_navigate` | goto_bar, create_marker, toggle_view, set_zoom... | `logic_navigate("toggle_view", {view: "mixer"})` |
| `logic_project` | new, open, save, bounce, launch, quit | `logic_project("open", {path: "/path/to/song.logicx"})` |
| `logic_system` | health, permissions, refresh_cache, help | `logic_system("help", {category: "transport"})` |

### Resources (7 URIs — zero context cost)

| URI | Description | Refresh |
|-----|-------------|---------|
| `logic://transport/state` | Playing/recording/tempo/position/cycle | 500ms |
| `logic://tracks` | All tracks with mute/solo/arm states | 2s |
| `logic://tracks/{index}` | Single track detail | 2s |
| `logic://mixer` | All channel strips: volume, pan, plugins | 2s |
| `logic://project/info` | Project name, sample rate, time sig | 5s |
| `logic://midi/ports` | Available MIDI ports | 10s |
| `logic://system/health` | Channel status, cache, permissions | on-demand |

## Installation

### Quick Install (Script)

```bash
curl -fsSL https://raw.githubusercontent.com/koltyj/logic-pro-mcp/main/Scripts/install.sh | bash
```

### Download Binary

Grab the latest universal macOS binary from [GitHub Releases](https://github.com/koltyj/logic-pro-mcp/releases), then:

```bash
chmod +x LogicProMCP
sudo mv LogicProMCP /usr/local/bin/
```

### Build from Source

Requires Swift 6.0+ and macOS 14+.

```bash
git clone https://github.com/koltyj/logic-pro-mcp.git
cd logic-pro-mcp
swift build -c release
# Binary at .build/release/LogicProMCP
```

### Register with Claude Code

```bash
claude mcp add --scope user logic-pro -- LogicProMCP
```

### Claude Desktop (Manual Config)

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "logic-pro": {
      "command": "/usr/local/bin/LogicProMCP",
      "args": []
    }
  }
}
```

## Permissions

The server requires two macOS permissions:

1. **Accessibility** — System Settings > Privacy & Security > Accessibility > add your terminal app
2. **Automation** — System Settings > Privacy & Security > Automation > allow control of Logic Pro

Check permission status:

```bash
LogicProMCP --check-permissions
```

## Usage

Once registered, ask your AI assistant naturally:

- *"What tracks do I have?"* — reads `logic://tracks` resource
- *"Mute track 3"* — `logic_tracks("mute", {index: 3, enabled: true})`
- *"Set tempo to 128"* — `logic_transport("set_tempo", {tempo: 128})`
- *"Play a C major chord"* — `logic_midi("send_chord", {notes: [60,64,67], ...})`
- *"Show me the mixer"* — `logic_navigate("toggle_view", {view: "mixer"})`

For full command reference: `logic_system("help", {category: "all"})`

## Architecture

### Channel Routing

| Channel | Latency | Used For |
|---------|---------|----------|
| **CoreMIDI** | <1ms | Transport (MMC), note/CC/sysex sending |
| **Accessibility** | ~15ms | State reading, UI button clicks, slider values |
| **CGEvent** | <2ms | Keyboard shortcuts (postToPid, no focus needed) |
| **AppleScript** | ~200ms | App lifecycle only (launch, quit, open file) |
| **OSC** | <1ms | Mixer control (requires Logic Pro OSC setup) |

### State Cache

Background Accessibility polling with adaptive intervals:

- **Active** (tool used <5s ago): 500ms transport, 2s tracks/mixer
- **Light** (5-30s idle): 2s all
- **Idle** (>30s): 5s all, near-zero CPU

### Context Efficiency

| Approach | Tools | Resources | Context Cost |
|----------|-------|-----------|-------------|
| Typical MCP server | 100+ tools | 0 | ~40k tokens |
| **This server** | **8 tools** | **7 resources** | **~3k tokens** |

Same 100+ operations. 90% less context.

## Limitations

Logic Pro does not expose a programmatic API. This server works within macOS platform constraints:

- UI element paths may change between Logic Pro versions
- Some deep state (automation curves, region MIDI data) is not exposed via Accessibility
- AX element labels may be localized on non-English macOS
- Plugin parameter control is limited to what's visible in the UI
- OSC channel requires manual Logic Pro Control Surface setup

This is the ceiling for Logic Pro automation given Apple's constraints.

## Development

```bash
# Build debug
swift build

# Build release
swift build -c release

# Run tests
swift test

# Check permissions without starting server
.build/debug/LogicProMCP --check-permissions
```

### Project Structure

```
Sources/LogicProMCP/
  main.swift                 # Entry point
  Server/                    # MCP server + config
  Dispatchers/               # 8 MCP tool dispatchers
  Resources/                 # 7 MCP resource handlers
  Channels/                  # 5 communication channels
  Accessibility/             # AX API wrappers
  MIDI/                      # CoreMIDI engine + MMC
  OSC/                       # UDP client/server
  State/                     # Cache + adaptive poller
  Utilities/                 # Logging, permissions, process utils
```

## License

MIT
