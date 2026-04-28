# Logic Pro ProjectData: Binary Specification

This document provides a technical specification for the internal structure and data mapping of the proprietary ProjectData file found within Logic Pro project packages (.logicx).

## 1. File Structure Overview

The ProjectData file is a binary container consisting of a global header followed by a sequence of structured data chunks.

- Location: .logicx/Alternatives/[Index]/ProjectData
- Some tooling (including `logic_extractor.py`) can also operate on a raw ProjectData file path.
- Magic Bytes (Offsets 0x00-0x03): 23 47 C0 AB
- Versioning (Offsets 0x04-0x07): Varies by Logic Pro version (e.g., D0 09 03 00).
- Global Table Offset: The chunk sequence typically begins at offset 0x18.
- **Global Settings (Plist-derived)**:
  - Time Signatures: Extracted from `MetaData.plist` or `ProjectInformation.plist` (looking for `TimeSignature` keys). Defaults to 4/4 if missing.
  - Sample Rate, BPM, Key, Frame Rate.

---

## 2. Chunk Architecture (36-Byte Header)

Every data block is preceded by a standardized 36-byte header that defines the chunk type, identity, and size.

| Offset | Size | Field    | Description                                                                   |
| :----- | :--- | :------- | :---------------------------------------------------------------------------- |
| 0x00   | 4B   | ID       | 4-character identifier, stored in reverse byte order (e.g., "ivnE" for Envi). |
| 0x04   | 6B   | Metadata | Internal versioning and type flags.                                           |
| 0x0A   | 4B   | OID      | Object Identifier. Used for cross-referencing between chunks.                 |
| 0x0E   | 8B   | Padding  | Reserved or static binary structure.                                          |
| 0x16   | 6B   | Anchor   | Static signature. Typically 02 00 00 00 [01/02] 00.                           |
| 0x1C   | 8B   | Length   | 64-bit Little Endian integer representing the body size in bytes.             |

### Discovery Pattern

Chunks can be located within a file by scanning for the anchor signature (02 00 00 00 . 00). The 4-byte chunk ID is located exactly 22 bytes before the start of this signature. In practice, this signature can also occur inside payloads, so validate that:

1. The header is a full 36 bytes.
2. The length field fits inside the file bounds.
3. The anchor bytes at 0x16 match the detected signature.

---

## 3. Event Sequences (EvSq) and Tempo Encoding

EvSq chunks store the project timeline, including MIDI data, automation, and tempo events.

### Tempo Event Signature

Tempo changes follow a specific 20-byte pattern:
7F 00 00 01 [MM MM MM MM] [00 00 00 00] [PP PP PP PP PP PP PP PP]

- Millitempo (4B): The tempo value stored as an integer (BPM x 10,000). To calculate BPM, divide the Little Endian integer by 10,000.
- Tick Position (8B): The absolute timeline position in ticks.
- Resolution: Logic Pro standard resolution is 3840 ticks per bar in 4/4 time.
- Bar Calculation: (Ticks / 3840) + 1.

**Extractor Note:** `logic_extractor.py` now preserves the raw tick position in the JSON output (`tempo_map[].tick`) so downstream tooling can avoid rounding error when converting to seconds.

### MIDI Event Encoding

Events are stored in 12-byte structures interleaved with tempo events.

- **Structure**: `[Status Byte] [Data 1] [Data 2] [Reserved] [Position (8B)]`
- **Status Byte**:
  - High Nibble (Type): `0x9` (Note On), `0x8` (Note Off), `0xB` (Control Change), `0xC` (Program Change).
  - Low Nibble (Channel): `0x0`-`0xF` (Channels 1-16).
- **Position**: 8-byte Little Endian integer representing absolute tick position.

---

## 4. Sequence & Track Objects (MSeq / Trak)

### MSeq (Sequence Object)

MSeq entries appear to represent high-level sequence/track objects. In this file, the following layout was consistent:

- **Name Length**: 2-byte Little Endian at offset 0x10.
- **Name**: ASCII string starting at 0x12, `name_len` bytes.

Example names observed: `Click Track`, `Drums`, `NSP Quad Cortex`, `Track Alternatives`, `Global Harmonies`.

### Trak (Track Object)

Trak chunks are fixed-length (58 bytes) in this ProjectData. The body does **not** appear to contain a region list.

Observed fields:

- **MSeq Reference**: 4-byte Little Endian at offset 0x08 (references an MSeq OID).
- **UUID**: 16 bytes at offset 0x18 (format as standard UUID).
- **Flags**: 4 bytes at offset 0x28 (unknown / UI state).

Track names are commonly stored in TxSq/TxSt chunks (RTF text), cleaned and mapped by OID when MSeq references are absent.

---

## 5. Mixer and Track Parameters (AuCO / ivnE)

Mixer and channel strip data are primarily stored in Audio Channel Objects (AuCO).

### Volume Calculation

Volume levels are stored as 32-bit integers using a proprietary logarithmic scale.

- Unity Gain (0 dB) Reference: 1509949440 (00 80 00 5A)
- Decibel Formula: dB = 40 \* log10(Value / 1509949440)
- Note: A value of 0 indicates negative infinity dB.

### Panning

- Offset: 0x59 within the AuCO body.
- Range: 0 (Hard Left) to 127 (Hard Right).
- Center: 64.

### Channel Strip Name

- Offset: 0x3C within the AuCO body.
- Encoding: null-terminated ASCII.
- Example values: `Audio 1`, `Audio 2`, `Audio 3`.

### Output Routing Labels

- **Pattern Scan**: The extractor scans `AuCO` chunks for strings containing "Output", "Bus", or "Stereo Out".
- **Usage**: Identifies the physical output or bus assignment (e.g., `Output 1-2`) useful for grouping stems.

### Track Hierarchy and Routing

Additional chunks define track properties and routing:

- **AuCn**: Presence indicates active routing or auxiliary channel status.
- **AuCU**: Presence and count indicates automation lanes.
- **Trak**: Defines the arrangement track.
  - **Region Mapping**: The body contains 4-byte Little Endian OIDs. These match the OIDs of Audio Regions (AuRg), linking them to this specific track.

Extractor additions:

- `channel_strip.config_records`: Summary of AuCO record lengths and byte-offset value counts. For length 241 records, the extractor reports byte values at offsets `0x50` and `0x51` (decimal 80/81) as `length_details["241"].offset_80_counts` and `offset_81_counts`, plus pair counts. In a send on/off toggle test, these bytes shifted (e.g., `0x08 -> 0x00` at 0x50 and `0x0A -> 0x08` at 0x51) indicating a likely send enable/bus slot flag.
- `channel_strip.routing_records`: Summary of AuCn record lengths and u32 head samples.
- `channel_strip.automation_records`: Summary of AuCU record lengths and decoded plist root keys (when present). For 76-byte AuCU records:
  - `len76_field_counts` reports u16 values at offsets `0x10` and `0x12` (decimal 16/18) plus u32 values at offsets `0x10` and `0x18` (decimal 16/24).
  - `len76_records` is a per‑record list with decoded fields including `send_level_db` (derived from `u32_offset_24` using the standard `raw_to_db` scale), a stable `index`, and `send_enabled_guess` (true when `u16_offset_18 == 0`, false when `u16_offset_18 == 0x0100`, otherwise null).
  
In send on/off tests:
  - `u16_offset_18` flipped from `0x0000` (send on) to `0x0100` (send off).
  - `u32_offset_24` matched the standard volume scale (e.g., `0x5A000000` = unity/0 dB). Sending level to `-inf` set this field to `0x00000000`, which converts to about `-144 dB` via the existing `raw_to_db` formula.
  - Additional validation: `-6 dB` produced `u32_offset_24 = 0x3FE00000` (≈ -5.95 dB) and `+6 dB` produced `u32_offset_24 = 0x7F000000` (≈ +5.98 dB), confirming the same scale with quantization.

---

## 6. Assets and Regions (AuFl / AuRg)

Logic Pro separates the definition of audio files from their placement on the timeline.

### Audio File References (AuFl)

- Content: Original file paths or aliases.
- Encoding: UTF-16LE.
- Payload Offset: Typically begins at offset 0x0A relative to the chunk body start.

### Audio Regions (AuRg)

- **Linkage**: The OID in the AuRg chunk header corresponds to an AuFl OID. In this file, AuRg OIDs are **not unique** (they map to audio assets), so regions must be uniquely identified by a composite key (e.g., OID + start ticks + name).
- **Timeline Placement**:
  - Legacy mode: Start Position is an 8-byte Little Endian tick value at body offset `0x30`; duration can appear at `0x38`/`0x40`.
  - Bar-field mode (newly observed): Start/length are encoded as bar values across `0x10..0x1F`:
    - start bar = `u32@0x10 + (u32@0x14 >> 16)/65536`
    - length bars = `u32@0x18 + (u32@0x1C >> 16)/65536`
    - ticks are derived with `3840 ticks/bar`.
  - **Important**: `u32@0x48` may alias `name_len << 16` (because `name_len` lives at `0x4A`), so it is now treated as a low-confidence legacy fallback.

### Region Name

- Name Length: 2-byte Little Endian at offset 0x4A.
- Name: ASCII string at 0x4C, length `name_len`.
- Example values: `Rec#03.31`, `Click Track.10`, `The Last Light.4`.

### Region → Track Association (Heuristic)

Track association does **not** appear directly in Trak. Instead, AuRg bodies contain track references at **variable offsets depending on AuRg length**. The extractor uses a heuristic:

1. Group AuRg bodies by length.
2. For each length, scan offsets to find positions that frequently contain Trak OIDs.
3. Use the most frequent offsets for that length as candidate track refs.

Additional signal (best-effort):

- **Song / USEl (Explicit Tables)**: These chunks contain explicit `[TrackOID, Count, RegionOID...]` mapping tables. The extractor now prioritizes these tables over heuristics when present.
- **Co-occurrence**: Proximity-based heuristic (nearest Trak OID within a short window) used as a fallback.
- **Confidence Scoring**: The extractor assigns a confidence score (0.0 - 1.0) and source label (e.g., `song_usel_table`, `aurg_offset`, `name_prefix`) to every link.
- **Song / USEl Tables**: Some sections appear to encode explicit `[track_oid, count, region_oid * count]` tables. The extractor now detects these tables and prefers them as a high-confidence source when the best match is dominant.

This heuristic is documented in code (`logic_extractor.py`) and should be treated as “best-effort” until a definitive mapping is known.

**Extractor Output:** When a region is mapped to a track, `logic_extractor.py` records:

- `regions[].track_oid`, `regions[].track_confidence`, `regions[].track_source`
- `regions[].timing_source`: Which timing decoder was used (`legacy:*` or `bar_fields_0x10_0x1C`).
- `regions[].track_sources` (optional): List of contributing sources when multiple signals agree (e.g., `["aurg_offset", "name_tokens"]`).
- `tracks[].regions[]` entries as objects: `{ oid, confidence, source }`
- `tracks[].region_mapping_stats`: `{ total, by_source: { <source>: count } }`
- `tracks[].track_id`: Stable identifier for cross‑project matching. Prefers `uuid`, otherwise falls back to `mseq_oid`, then normalized name, then OID.
- `tracks[].name_norm`: Normalized track name tokens (lowercased, stopwords removed) when a name is present.
- `tracks[].display_name`: Best-effort human-friendly name used by render planning; falls back to `Track <oid>` when only placeholder names are available.
- `tracks[].name_raw` / `tracks[].name_is_generic`: Preserve the original extracted name and flag generic placeholders (e.g. `*Automation`).
- `tracks[].track_stack` / `tracks[].is_summing_track_stack`: Best-effort stack classification metadata (`type`, `source`, `confidence`) and boolean summing flag.
- `tracks[].parent_track_oid`, `tracks[].stack_root_track_oid`, `tracks[].stack_depth`, `tracks[].stack_child_oids`: Best-effort hierarchy fields inferred from MSeq linkage.
- `tracks[].top_level_stack_name`: Best-effort canonical stack grouping label (`Midi Triggers`, `Click Track`, `Backing Track`, `Release Track`) from environment labels + track/region keywords.
- `tracks[].synthetic` / `tracks[].synthetic_source` (optional): Synthetic catalog tracks created from unmapped environment labels when a concrete Trak mapping is unavailable. These carry names/stack hints but no regions.
- `summary.track_hierarchy[]`: Flattened inferred parent/child edges with source and confidence.
- `summary.top_level_stacks[]`: Group summary with stack name, member track OIDs/names, and aggregate region counts.
- `summary.region_timing_mode` / `summary.timeline_tick_offset`: Decoder mode and optional global tick offset normalization applied when tempo/region data are stored in absolute timeline space.
- `summary.environment_name_catalog[]`: Unmapped environment labels promoted into the synthetic track catalog (`oid`, `name`, `stack_hint`).
- `summary.region_oid_reuse`: AuRg OID reuse diagnostics (`total_regions`, `unique_region_oids`, `max_region_oid_reuse`) and whether Song/USEl table mapping was enabled.
- `summary.region_alias_refinement`: Post-processing diagnostics for alias-based region remapping (`retargeted_count`, `assigned_count`) and optional pass-level details when multi-pass refinement is used.
- `summary.region_orphan_rec_assignment`: Diagnostics for generic orphan `Rec#..` region assignment pass (`assigned_count`) when unresolved regions are mapped via prefix-to-track fallback.

---

## 7. Plugin Data

Plugin usage is recorded in specific chunks identified by a null ID.

- **ID**: `00 00 00 00` (Null Bytes)
- **Identification**: These chunks are detected by the standard header structure but with a zeroed ID.
- **Content**: The body typically contains ASCII signatures of the plugin names (e.g., "Serum", "Valhalla", "Compressor", "Kontakt").

---

## 8. Text and Metadata (TxSt / TxSq)

Text-based data, including track names and markers, is frequently stored in Rich Text Format (RTF).

- Identifiers: TxSt (Text String) or TxSq (Text Sequence) chunks.
- Format: RTF data starts with the standard {\rtf1 header.
- Parsing: Extract payload text after the \fs24 (font size) or similar formatting tags.
- **Arrangement Markers**: `TxSq` chunks often contain global arrangement markers (Verse, Chorus) distinguished from track names by context or specific text patterns.

---

## 9. Auxiliary Metadata Chunks (Observed)

These chunk types appear in this ProjectData and contain useful metadata, but are not fully decoded:

- **SngO**: NSKeyedArchiver plist. Contains keys like `arrangementMarkerTitleList`.
- **GenM**: JSON and/or NSKeyedArchiver plist. Includes Drummer model state and arrangement metadata.
- **CorM**: MIDI port names (e.g., `IAC Driver`, `Logic Pro Virtual In`).
- **Hypr**: Automation parameter list (e.g., `Volume`, `Modulation`, `Pitch Bend`).
- **Layr**: Environment layer names (e.g., `All Objects`, `Mixer`).
- **ScSt**: Score/notation instrument set names (e.g., `Guitar`, `Bass 4`).
- **InSt**: Score set root (e.g., `Score Set`).
- **Trns**: Transition metadata (no obvious strings).
- **Envi**: Environment objects. The extractor parses a best‑effort object record (name + column `x` coordinate + class id) and emits `summary.environment_objects`.
- **USEl**: Large string-heavy chunk; likely selection/state data.

These are currently extracted only as raw strings (see `logic_extractor.py`).

---

## 10. Non-ASCII Chunk Families (Decoded)

Several chunk IDs are non-ASCII and encode embedded plists or fixed tables. The extractor now decodes these **best-effort** and records a summary in `summary.non_ascii_chunks`.

Observed families:

- **0x00000002** (len ~675,000; 3 copies): Mixed payload. Contains many **NSKeyedArchiver** segments plus length‑prefixed ASCII take names (e.g., `Drums_bip.18`). Dominant plist roots include `{"Shared": {"LoopFamily": {"LoopName": <name>, "LoopId": <int>}}}` (loop entries), `{"Cb": {"LoopFamilyName": <name>, "IsFamilyLoop": <bool>}}}` (loop families), and a small `contentTagLayoutName` plist (e.g., `Automatic`).
- **0x000000E0** (len ~167,936): Similar **NSKeyedArchiver** segments (arrangement marker type map, loop families, edit metadata) plus many port/bus/track strings.
- **0x0000004C / 0x000000A8** (len ~133,888): **NSKeyedArchiver** plists with `Cb` keys like `lastEditedDate` (NS.time seconds since 2001‑01‑01), `persistentAGCPreparedFlag`, and `nameUserModified`.
- **0x00000004 / 0xFFFFFFFF**: **NSKeyedArchiver** plist containing `Shared.arrangementMarkerTitleList`, a map of slot → `{type: n}` (no titles).
- **0x00000040** (len ~338,944): Dense **string table** with environment labels and GM instrument names.
- **0x00000400** (len 136; ~224 copies): Fixed record layout (34 x `u32`). Indices `12/13` and `32/33` behave like UI coordinates when scaled by `/256`. Extractor emits `layout_tables` with `x1/y1/x2/y2`.
- **0xFFFF0001**: Short ASCII payload (e.g., `Delete Tracks`).

Extractor output shape:

- `summary.non_ascii_chunks.string_tables[]`: `{ id, count, length, string_count, strings_sample[] }`
- `summary.non_ascii_chunks.numeric_tables[]`: `{ id, count, length, track_oid_hits, region_oid_hits, top_pairs[] }` (heuristic; track/region OIDs are small, so expect false positives)
- `summary.non_ascii_chunks.plists[]`: `{ id, count, length, keys[], root_keys[], strings_sample[] }`
- `summary.non_ascii_chunks.layout_tables[]`: `{ id, count, scale, fields, records[] }` where each record includes `x1/y1/x2/y2` plus `source_env`/`target_env` when an `Envi` object matches the x‑column.
- `summary.non_ascii_chunks.decoded.loop_entries[]`: `{ loop_name, loop_id, source }`
- `summary.non_ascii_chunks.decoded.loop_families[]`: `{ family_name, is_family_loop, source }`
- `summary.non_ascii_chunks.decoded.edit_metadata[]`: `{ last_edited_ns_time, last_edited_iso, name_user_modified, persistent_agc_prepared_flag, source }`
- `summary.non_ascii_chunks.decoded.content_tag_layouts[]`: `{ layout_name, source }`
- `summary.non_ascii_chunks.decoded.arrangement_marker_types[]`: `{ slot, type, source }`
- `summary.non_ascii_chunks.misc[]`: `{ id, count, length }`

Environment object extraction:

- `summary.environment_objects[]`: `{ oid, name, x, class_id, length, name_offset, name_len, name_prefix_u16[], header_u32{}, y_positions[], y_decode_candidates[] }`.
  - `x` is the environment column coordinate from the `Envi` chunk.
  - `name_offset/name_len` are derived by scanning for the first length‑prefixed ASCII name.
  - `name_prefix_u16` are the three u16 values immediately before the name length (useful for reverse‑engineering).
  - `header_u32` captures u32 fields at offsets `0x00..0x1C` (raw header values).
  - `y_positions` are derived from layout tables (no stable y‑coordinate observed inside `Envi`).
  - `y_decode_candidates` is present only if a direct encoding match is detected (none observed for this file).
- `summary.environment_layout_map`: `{ x -> { name?, y_positions[], track_oid? } }` compact index for column‑level lookup (JSON keys are strings).
- `summary.environment_y_decode_report`: `{ top_encodings[], object_samples[], objects_scanned }` best‑effort report of near‑miss y‑decode patterns.

---

## 11. Global String Discovery and Heuristics

Beyond structured chunks, significant metadata is recovered by scanning the entire binary for string patterns.

### String Scanner

The extractor scans for contiguous printable ASCII sequences (len > 6) and categorizes them:

- **Performance Metadata**: Keywords like `vocal`, `stem`, `bpm`, `verse`, `chorus`.
- **Project Notes**: Longer text blocks (>10 chars) often containing user notes or RTF fragments.
- **System Noise**: Paths (`/usr/lib`, `/System/`), copyright strings, and library references are filtered out.

---

## 12. Implementation Notes for Parsing

1. Endianness: All multi-byte integers (Length, OID, Ticks, Millitempo) are Little Endian.
2. Chunk IDs: IDs are 4-byte characters. They must be byte-reversed for human-readable labels (e.g., binary 45 6E 76 69 is read as ivnE but represents the Envi chunk).
3. Non-Contiguity: While chunks are often sequential, some files may contain padding between blocks. The anchor-based discovery method is more reliable than purely sequential parsing.

---

## 13. Arrangement Markers, Time Signature, Routing (Extractor State)

### Arrangement Markers

- The extractor uses TxSq RTF strings as arrangement marker names and records them in `summary.arrangement_markers`.
- Primary decode path uses an explicit marker sequence table found in a small `EvSq` chunk (`EvSq(oid=0)` in this file):
  - 16-byte triplet groups:
    - head: `[18, start_tick, 0, ...]`
    - marker row: `[marker_oid, 0x88000000, marker_type, duration_ticks]`
    - tail: `[0, 0x88000000, 0, 0]`
  - marker row `marker_oid` is joined to TxSq marker `oid`
  - decoded rows are exposed in `summary.arrangement_marker_sequence_decode.events[]`
  - marker placement source: `evsq_type18_sequence_unique` (single start per marker) or `evsq_type18_sequence_first`
  - when available, `position_duration_ticks` and `position_end_tick` are emitted per marker
- Secondary decode path (fallback) uses marker-linked `EvSq(oid=4)` 80-byte records:
  - row type `u32[0] == 36`
  - marker/object reference `u32[11]` (joined to TxSq marker `oid`)
  - timeline tick `u32[1]`
  - sequence index `u32[10]`
  - lane id `u32[4]`
  - decoded rows are exposed in `summary.arrangement_marker_decode.events[]`
  - marker placement source: `evsq_type36_index0` or `evsq_type36_single_tick`
- Each marker includes `oid` and `position_candidates[]` (decoded candidates with tick and source-specific fields).
- `summary.arrangement_marker_position_stats` now reports decode details:
  - `decoded_sequence_events`
  - `decoded_sequence_ambiguous`
  - `decoded_events`
  - `decoded_ambiguous`
  - `heuristics_used`
- Legacy lexical/track heuristics remain available only when `summary.arrangement_marker_allow_heuristics` is set truthy.

### Time Signature

- `summary.time_signature_map` is populated from MetaData.plist / ProjectInformation.plist if available.
- If no explicit time signature is found, the extractor defaults to **4/4 at bar 1** with source `assumed_default`.

### Bar-Number Mapping (Current Decode)

- The extractor emits `summary.bar_number_mapping_decode` and `summary.bar_number_mapping_stats`.
- Primary decoded source is an `EvSq` type-96 tempo bridge (small `len=432` chunks in this file):
  - row A: `[96, sequence_tick, 0, 0x0100007F|0x8100007F]`
  - row B: `[tempo_raw, 0x88400000, tempo_tick_abs, 0]`
  - `tempo_raw` is decoded as `BPM * 10000`
  - normalized `tempo_tick` subtracts `summary.timeline_tick_offset` when present
  - decoded rows are emitted as `bar_number_mapping_decode.anchors[]`
  - adjacent anchor deltas are emitted as `bar_number_mapping_decode.segments[]`
- Candidate bridge chunks and alignment scores are emitted in `bar_number_mapping_decode.bridge_candidates[]` (top-ranked entries only).
- A secondary explicit bar-anchor decode is emitted from type-48 triplets:
  - head: `[48, tick, 0x02000000, ...]`
  - row: `[48, 0x88000000, bar_raw, tick]`
  - tail: `[0, 0x88000000, 0, 0]`
  - decoded rows are emitted in `bar_number_mapping_decode.explicit_bar_anchor_decode.events[]`
  - both `bar_raw` and signed interpretation `bar_signed` are preserved
  - cross-checks against the tempo bridge interpolation are emitted in `bar_number_mapping_decode.explicit_bar_anchor_decode.cross_check_vs_tempo_bridge[]`
- A Song-table companion decode is emitted when `Song` bodies contain 24-byte node tables:
  - candidate records are parsed as `u32x6` at best alignment
  - type-20 nodes expose dense bar-domain values (`bar_nodes_head` / `bar_nodes_tail`)
  - type-14 nodes expose marker-domain values (observed marker OID set: `0,4,8,...,36`)
  - arrangement-marker-specific node hits are exposed as `arrangement_marker_nodes[]`
  - linked-node hints are emitted in `bar_number_mapping_decode.song_bar_node_decode.bar_edge_sample[]` and `marker_edge_sample[]`
  - same payload is mirrored at `summary.bar_number_mapping_song_decode` for convenience
  - summary count is emitted as `summary.bar_number_mapping_stats.song_bar_node_count`
- Marker projections through the tempo bridge are emitted in `bar_number_mapping_decode.marker_projection[]` and summarized in `summary.bar_number_mapping_stats.marker_projection_count`.

### Routing

- `AuCn` presence flags routing/aux status.
- `AuCO` may contain output labels (e.g., `Output 1`, `Bus 1`, `Stereo Out`); these are extracted into `channel_strip.output` when present.
- `channel_strip.config_records` provides per‑strip summaries of AuCO record lengths and byte-offset stats (currently offsets 0x50/0x51 for length‑241 records).
- `channel_strip.routing_records` and `channel_strip.automation_records` provide per‑strip summaries of AuCn/AuCU record lengths and decoded plist root keys.

### AuCn Routing Table

Every Logic project binary contains exactly **13 `AuCn` chunks** that together
describe a fixed-size routing table. They split cleanly into two categories:

#### Small routing entries (12 of 13)

- Body length is exactly **132 bytes**.
- Constants within the body:
  - `u32 @ 0x00 = 0x000000B0` (176) — secondary body length.
  - `u32 @ 0x04 = 0x000000C0` (192) — header constant.
  - `u16 @ 0x0A = 0x1235` (4661) — type signature.
  - `u32 @ 0x10 = 0x000000B0` (176).
- `u32 @ 0x14` encodes the **stable routing index** as `(index << 16) | 0x03`.
  Across the 13 entries the raw values observed are
  `0x03, 0x10003, 0x20003, …, 0xC0003`, giving routing indices `0..12`.
- Because the big enable table (below) consumes routing index `1`, the 12
  small entries expose the indices `{0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}`.

#### Big enable table (1 of 13)

- Always present at routing index `1` (typically `oid == 36`).
- Body length is project-dependent. Confirmed samples:
  - `logic-project-1`: **1384 bytes**
  - `logic-project-2`: **1420 bytes**
  - `logic-project-3`: **1412 bytes**
- Reuses the same 0x80-byte header region as the small entries.
- Beyond body offset `0x80` the body is a flat array of `u32` entries, each
  observed to be `0` or `1`. This is the **per-strip enable-flag table**; the
  entry count is approximately (but not always exactly) equal to the project's
  `AuCO` channel-strip count. For `logic-project-1` the table contains 313
  `u32` entries against 326 `AuCO` chunks.
- Flag count computed as `(bodyLength - 0x80) / 4`.

#### Decoder

`Sources/LogicProMCP/Binary/Decoders/AuCnDecoder.swift` provides an isolated
decoder that returns `(entries: [AuCnRoutingEntry], enableTable:
AuCnEnableTable?)` for a ProjectData blob. The decoder copies the chunk
scanner so it can be used independently of `ProjectDataParser`.
