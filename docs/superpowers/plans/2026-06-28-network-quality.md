# Per-App Network Quality Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Passively compute per-connection / per-app TCP network quality (handshake RTT, retransmits, connection-setup time) from captured packets, and surface it in the connection inspector so a user can tell whether an app is slow because of the local network or the far server.

**Architecture:** A pure value core in `MatrixNetModel` (`TCPSegment`/`TCPFlags`/`FlowQuality`/`FlowQualityTracker`) holds the entire quality algorithm and is fully unit-tested against synthetic packet sequences with no app or capture dependency (Phase 0 spike). The dissector is extended to emit a structured `TCPSegment` on `DissectedPacket`; `ConnectionAggregator` feeds those segments (with PKTAP microsecond timestamps + direction) into one `FlowQualityTracker` per flow and exposes a per-app snapshot; the app threads it into a new "Quality" inspector section. Sequence-number comparisons reuse the wraparound technique already proven in `StreamReassembler` (`Int32(bitPattern: a &- b)`).

**Tech Stack:** Swift 6 (strict concurrency), Swift Testing, SwiftUI, SwiftPM. macOS 26 (Tahoe). No new dependencies.

## Global Constraints

- **Spike-first:** Phase 0 (Task 0) is a pure-core spike — `swift test` only, no app changes, no version bump. It MUST be green and pass review before any integration task starts.
- **TDD:** No production code without a failing test first (Swift Testing `@Test`/`@Suite`, `#expect`/`#require`). Watch every test fail before implementing.
- **capture-only:** Quality requires PKTAP per-packet timestamps and sequence numbers. NStat has neither → there is no passive fallback; when capture is off there is simply no quality data (empty state).
- **Scope this version:** TCP only — handshake RTT (SYN→SYN-ACK), retransmits, out-of-order count, connection-setup time (SYN→first outbound payload). UDP/QUIC RTT and TTFB server-think-time are explicitly out of scope (future).
- **Passive only:** never send a packet; derive everything from observed traffic.
- **Zero conflict** with proxy/filter software (no network claims, no system config changes).
- **Zero warnings:** `swiftlint --strict` and `swiftformat --lint` must be clean.
- **Localization:** every new user-facing string added to `App/Resources/Localizable.xcstrings` in all 8 languages (en source + de/es/fr/ja/ko/zh-Hans/zh-Hant).
- **Open-source English:** all public code, doc comments, DocC, README, CHANGELOG in English. Internal specs/plans (this file) and user communication in Chinese.
- **Version:** target **1.4.0 (CFBundleVersion 34)**. MINOR bump = new feature. Version source = `project.yml` (`settings.base.MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` + both `info.properties` blocks `CFBundleShortVersionString`/`CFBundleVersion`).
- **Commits:** identity `Jim Ho <jim.ho@matrixreligio.com>`; NO Claude/Claude Code authorship or co-author trailer on git commits.
- **CI is canonical:** the notarized build + appcast (`sparkle:version=34`) is produced by CI on tag push; verify the appcast after release and confirm a local Developer-ID install.

---

## File Structure

**Pure core (new, MatrixNetModel — no dependencies, fully unit-testable):**
- `Sources/MatrixNetModel/TCPSegment.swift` — `TCPFlags` (OptionSet) + `TCPSegment` value type.
- `Sources/MatrixNetModel/FlowQuality.swift` — `FlowQuality` result value + `FlowQualityTracker` state machine.

**Dissection (modified, MatrixNetDissection):**
- `Sources/MatrixNetDissection/DissectionSupport.swift` — `NetworkLayerResult.payloadEnd`; `TransportLayerResult.tcpSegment`.
- `Sources/MatrixNetDissection/IPv4Dissector.swift` / `IPv6Dissector.swift` — populate `payloadEnd`.
- `Sources/MatrixNetDissection/TransportDissectors.swift` — `TCPDissector` builds a `TCPSegment`; signature gains `segmentEnd:`.
- `Sources/MatrixNetDissection/PacketDissector.swift` — thread `payloadEnd` → TCP → `DissectedPacket.tcpSegment`.
- `Sources/MatrixNetDissection/DissectionResult.swift` — `DissectedPacket.tcpSegment: TCPSegment?`.

**Capture (modified, MatrixNetCapture):**
- `Sources/MatrixNetCapture/ConnectionAggregator.swift` — `recordTCP(...)`, `qualityByFlow`, `qualitySnapshot()`, `AppFlowQuality`, reset.

**App (modified):**
- `App/Sources/PacketCaptureModel.swift` — record TCP segments into the aggregator.
- `App/Sources/AppModel.swift` — refresh a live per-(app,address) quality map; `quality(for:)`.
- `App/Sources/ConnectionInspector.swift` — "Quality" section.
- `App/Resources/Localizable.xcstrings` — new strings ×8 languages.

**Tests (new):**
- `Tests/MatrixNetModelTests/FlowQualityTrackerTests.swift`
- `Tests/MatrixNetDissectionTests/TCPSegmentTests.swift`
- `Tests/MatrixNetCaptureTests/AggregatorQualityTests.swift`

**Docs (modified):** `CHANGELOG.md`, `README.md` + 7 translations, `project.yml`.

---

## Task 0: Pure quality core (Phase 0 spike) — `TCPSegment`, `TCPFlags`, `FlowQuality`, `FlowQualityTracker`

> This is the spike gate. `swift test` only. No app changes, no version bump. Must be green and reviewed before Task 1.

**Files:**
- Create: `Sources/MatrixNetModel/TCPSegment.swift`
- Create: `Sources/MatrixNetModel/FlowQuality.swift`
- Test: `Tests/MatrixNetModelTests/FlowQualityTrackerTests.swift`

**Interfaces:**
- Produces (used by Tasks 1–3):
  - `public struct TCPFlags: OptionSet, Sendable, Equatable { public let rawValue: UInt16; public init(rawValue: UInt16); static let fin/syn/rst/psh/ack/urg }`
  - `public struct TCPSegment: Sendable, Equatable { public let flags: TCPFlags; public let sequence: UInt32; public let acknowledgement: UInt32; public let payloadLength: Int; public init(flags:sequence:acknowledgement:payloadLength:) }`
  - `public struct FlowQuality: Sendable, Equatable { public let handshakeRTTms: Double?; public let retransmits: Int; public let outOfOrder: Int; public let setupMs: Double? }`
  - `public struct FlowQualityTracker: Sendable { public init(); public mutating func ingest(timestampMicros: UInt64, inbound: Bool, segment: TCPSegment); public var quality: FlowQuality }`

### Definitions (exact algorithm)

`FlowQualityTracker` keeps:
- `synTs: UInt64?` — timestamp of the first segment with `.syn` set and `.ack` clear (the connection opener).
- `synAckTs: UInt64?` — timestamp of the first segment with both `.syn` and `.ack` set.
- `firstOutboundDataTs: UInt64?` — timestamp of the first `inbound == false` segment carrying payload (`payloadLength > 0`).
- `maxSeqEnd: [Bool: UInt32]` — per-direction (keyed by `inbound`) highest `sequence &+ payloadLength` seen so far.
- `retransmits: Int`, `outOfOrder: Int`.

On `ingest(timestampMicros:inbound:segment:)`:
1. If `segment.flags.contains(.syn)`: if `.ack` also set and `synAckTs == nil` → `synAckTs = ts`; else if `.ack` not set and `synTs == nil` → `synTs = ts`.
2. If `payloadLength > 0`:
   - If `inbound == false && firstOutboundDataTs == nil` → `firstOutboundDataTs = ts`.
   - Let `end = sequence &+ UInt32(payloadLength)`. If a prior `maxSeqEnd[inbound]` exists:
     - If `Int32(bitPattern: sequence &- prior) < 0` → **retransmit** (this data overlaps already-sent bytes): `retransmits += 1`.
     - Else if `Int32(bitPattern: sequence &- prior) > 0` → **out-of-order/gap** (data ahead of a hole): `outOfOrder += 1`.
     - (`sequence == prior` is normal in-order advance: neither.)
   - Update `maxSeqEnd[inbound] = end` only if it advances: when no prior, set it; else if `Int32(bitPattern: end &- prior) > 0` set it.

`quality`:
- `handshakeRTTms` = if both `synTs` and `synAckTs` set and `synAckTs >= synTs`: `Double(synAckTs - synTs) / 1000.0`; else `nil`.
- `setupMs` = if `synTs` and `firstOutboundDataTs` set and `firstOutboundDataTs >= synTs`: `Double(firstOutboundDataTs - synTs) / 1000.0`; else `nil`.
- `retransmits`, `outOfOrder` as accumulated.

- [ ] **Step 1: Write the failing test (file scaffold + flags/segment value types)**

Create `Tests/MatrixNetModelTests/FlowQualityTrackerTests.swift`:

```swift
import Testing
@testable import MatrixNetModel

@Suite("FlowQualityTracker")
struct FlowQualityTrackerTests {
    // SYN flag helpers
    private let syn = TCPSegment(flags: .syn, sequence: 100, acknowledgement: 0, payloadLength: 0)

    @Test("TCPFlags decompose a raw 16-bit field")
    func flags() {
        let f: TCPFlags = [.syn, .ack]
        #expect(f.contains(.syn))
        #expect(f.contains(.ack))
        #expect(!f.contains(.fin))
        #expect(f.rawValue == 0x012)
    }

    @Test("handshake RTT is the SYN to SYN-ACK gap in milliseconds")
    func handshakeRTT() {
        var tracker = FlowQualityTracker()
        tracker.ingest(timestampMicros: 1_000_000, inbound: false, segment: syn)
        let synAck = TCPSegment(flags: [.syn, .ack], sequence: 5000, acknowledgement: 101, payloadLength: 0)
        tracker.ingest(timestampMicros: 1_020_000, inbound: true, segment: synAck)
        #expect(tracker.quality.handshakeRTTms == 20.0)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter FlowQualityTracker`
Expected: FAIL — `TCPSegment`, `TCPFlags`, `FlowQualityTracker` not defined (compile error).

- [ ] **Step 3: Create `TCPSegment.swift`**

```swift
/// The structured TCP header fields needed for passive flow-quality analysis,
/// decoded once by the dissector so downstream consumers never re-parse bytes.
public struct TCPSegment: Sendable, Equatable {
    public let flags: TCPFlags
    public let sequence: UInt32
    public let acknowledgement: UInt32
    /// Number of application bytes carried by this segment (0 for a pure ACK).
    public let payloadLength: Int

    public init(flags: TCPFlags, sequence: UInt32, acknowledgement: UInt32, payloadLength: Int) {
        self.flags = flags
        self.sequence = sequence
        self.acknowledgement = acknowledgement
        self.payloadLength = payloadLength
    }
}

/// The TCP control bits (RFC 9293) as an option set.
public struct TCPFlags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let fin = TCPFlags(rawValue: 0x001)
    public static let syn = TCPFlags(rawValue: 0x002)
    public static let rst = TCPFlags(rawValue: 0x004)
    public static let psh = TCPFlags(rawValue: 0x008)
    public static let ack = TCPFlags(rawValue: 0x010)
    public static let urg = TCPFlags(rawValue: 0x020)
}
```

- [ ] **Step 4: Create `FlowQuality.swift`**

```swift
/// Passively measured quality of one TCP flow. All measurements are best-effort:
/// a value is `nil` when the packets needed to compute it were not observed (for
/// example, the connection was already open before capture started, so no SYN was
/// seen). Times are in milliseconds.
public struct FlowQuality: Sendable, Equatable {
    /// SYN → SYN-ACK round trip — at the client this is the full client↔server
    /// path RTT (Wireshark's iRTT). `nil` if the handshake was not captured.
    public let handshakeRTTms: Double?
    /// Count of outbound/inbound data segments that re-sent already-seen bytes —
    /// a sign of packet loss.
    public let retransmits: Int
    /// Count of data segments that arrived ahead of a sequence-number gap —
    /// reordering or loss-then-recovery (most meaningful on the inbound side).
    public let outOfOrder: Int
    /// SYN → first outbound payload byte — how long until the app sent its first
    /// request. `nil` if either was not captured.
    public let setupMs: Double?

    public init(handshakeRTTms: Double?, retransmits: Int, outOfOrder: Int, setupMs: Double?) {
        self.handshakeRTTms = handshakeRTTms
        self.retransmits = retransmits
        self.outOfOrder = outOfOrder
        self.setupMs = setupMs
    }
}

/// Accumulates per-segment observations for a single TCP flow into a `FlowQuality`.
/// Pure and incremental: feed every segment (either direction) with its capture
/// timestamp; read `quality` at any time. Sequence comparisons are 32-bit
/// wraparound-aware (`Int32(bitPattern:)`), matching `StreamReassembler`.
public struct FlowQualityTracker: Sendable {
    private var synTs: UInt64?
    private var synAckTs: UInt64?
    private var firstOutboundDataTs: UInt64?
    private var maxSeqEnd: [Bool: UInt32] = [:]
    private var retransmits = 0
    private var outOfOrder = 0

    public init() {}

    public mutating func ingest(timestampMicros: UInt64, inbound: Bool, segment: TCPSegment) {
        if segment.flags.contains(.syn) {
            if segment.flags.contains(.ack) {
                if synAckTs == nil { synAckTs = timestampMicros }
            } else if synTs == nil {
                synTs = timestampMicros
            }
        }

        guard segment.payloadLength > 0 else { return }
        if !inbound, firstOutboundDataTs == nil { firstOutboundDataTs = timestampMicros }

        let end = segment.sequence &+ UInt32(segment.payloadLength)
        if let prior = maxSeqEnd[inbound] {
            let delta = Int32(bitPattern: segment.sequence &- prior)
            if delta < 0 {
                retransmits += 1
            } else if delta > 0 {
                outOfOrder += 1
            }
            if Int32(bitPattern: end &- prior) > 0 { maxSeqEnd[inbound] = end }
        } else {
            maxSeqEnd[inbound] = end
        }
    }

    public var quality: FlowQuality {
        FlowQuality(
            handshakeRTTms: handshakeRTT,
            retransmits: retransmits,
            outOfOrder: outOfOrder,
            setupMs: setup
        )
    }

    private var handshakeRTT: Double? {
        guard let synTs, let synAckTs, synAckTs >= synTs else { return nil }
        return Double(synAckTs - synTs) / 1000.0
    }

    private var setup: Double? {
        guard let synTs, let firstOutboundDataTs, firstOutboundDataTs >= synTs else { return nil }
        return Double(firstOutboundDataTs - synTs) / 1000.0
    }
}
```

- [ ] **Step 5: Run the two tests to verify they pass**

Run: `swift test --filter FlowQualityTracker`
Expected: PASS (2 tests).

- [ ] **Step 6: Add the remaining behavior tests (retransmit, out-of-order, setup, no-SYN, wraparound)**

Append to `FlowQualityTrackerTests.swift`:

```swift
    @Test("a re-sent data segment counts as a retransmit")
    func retransmit() {
        var tracker = FlowQualityTracker()
        let first = TCPSegment(flags: [.ack, .psh], sequence: 1000, acknowledgement: 1, payloadLength: 100)
        tracker.ingest(timestampMicros: 0, inbound: false, segment: first)
        // Same bytes sent again (seq behind the high-water mark) → retransmit.
        tracker.ingest(timestampMicros: 1, inbound: false, segment: first)
        #expect(tracker.quality.retransmits == 1)
        #expect(tracker.quality.outOfOrder == 0)
    }

    @Test("a data segment ahead of a gap counts as out-of-order")
    func outOfOrder() {
        var tracker = FlowQualityTracker()
        let s1 = TCPSegment(flags: .ack, sequence: 1000, acknowledgement: 1, payloadLength: 100)
        let s3 = TCPSegment(flags: .ack, sequence: 1200, acknowledgement: 1, payloadLength: 100) // 1100..1200 missing
        tracker.ingest(timestampMicros: 0, inbound: true, segment: s1)
        tracker.ingest(timestampMicros: 1, inbound: true, segment: s3)
        #expect(tracker.quality.outOfOrder == 1)
        #expect(tracker.quality.retransmits == 0)
    }

    @Test("in-order advance is neither retransmit nor out-of-order")
    func inOrder() {
        var tracker = FlowQualityTracker()
        tracker.ingest(timestampMicros: 0, inbound: true,
                       segment: TCPSegment(flags: .ack, sequence: 1000, acknowledgement: 1, payloadLength: 100))
        tracker.ingest(timestampMicros: 1, inbound: true,
                       segment: TCPSegment(flags: .ack, sequence: 1100, acknowledgement: 1, payloadLength: 100))
        #expect(tracker.quality.retransmits == 0)
        #expect(tracker.quality.outOfOrder == 0)
    }

    @Test("setup time is SYN to first outbound payload")
    func setup() {
        var tracker = FlowQualityTracker()
        tracker.ingest(timestampMicros: 1_000_000, inbound: false,
                       segment: TCPSegment(flags: .syn, sequence: 100, acknowledgement: 0, payloadLength: 0))
        tracker.ingest(timestampMicros: 1_020_000, inbound: true,
                       segment: TCPSegment(flags: [.syn, .ack], sequence: 5000, acknowledgement: 101, payloadLength: 0))
        // Client sends its first request 5ms after the handshake completes.
        tracker.ingest(timestampMicros: 1_025_000, inbound: false,
                       segment: TCPSegment(flags: [.ack, .psh], sequence: 101, acknowledgement: 5001, payloadLength: 517))
        #expect(tracker.quality.setupMs == 25.0)
    }

    @Test("no SYN observed yields nil handshake/setup but still counts retransmits")
    func midStream() {
        var tracker = FlowQualityTracker()
        let seg = TCPSegment(flags: .ack, sequence: 9000, acknowledgement: 1, payloadLength: 50)
        tracker.ingest(timestampMicros: 0, inbound: true, segment: seg)
        tracker.ingest(timestampMicros: 1, inbound: true, segment: seg) // retransmit
        #expect(tracker.quality.handshakeRTTms == nil)
        #expect(tracker.quality.setupMs == nil)
        #expect(tracker.quality.retransmits == 1)
    }

    @Test("sequence comparison handles 32-bit wraparound")
    func wraparound() {
        var tracker = FlowQualityTracker()
        let near = TCPSegment(flags: .ack, sequence: 0xFFFF_FF00, acknowledgement: 1, payloadLength: 0x200)
        tracker.ingest(timestampMicros: 0, inbound: false, segment: near) // end wraps past 0
        // Next in-order segment starts at the wrapped end (0x100) — not a retransmit.
        let afterWrap = TCPSegment(flags: .ack, sequence: 0x0000_0100, acknowledgement: 1, payloadLength: 0x100)
        tracker.ingest(timestampMicros: 1, inbound: false, segment: afterWrap)
        #expect(tracker.quality.retransmits == 0)
        #expect(tracker.quality.outOfOrder == 0)
    }
```

- [ ] **Step 7: Run the full suite to verify it passes**

Run: `swift test --filter FlowQualityTracker`
Expected: PASS (8 tests).

- [ ] **Step 8: Lint**

Run: `swiftformat --lint Sources/MatrixNetModel/TCPSegment.swift Sources/MatrixNetModel/FlowQuality.swift Tests/MatrixNetModelTests/FlowQualityTrackerTests.swift && swiftlint --strict --quiet`
Expected: no output (clean).

- [ ] **Step 9: Commit**

```bash
git add Sources/MatrixNetModel/TCPSegment.swift Sources/MatrixNetModel/FlowQuality.swift Tests/MatrixNetModelTests/FlowQualityTrackerTests.swift
git commit -m "feat(model): FlowQualityTracker — passive TCP handshake RTT / retransmit / setup core"
```

- [ ] **Step 10: SPIKE GATE — review before integration**

Dispatch a code-reviewer subagent (or self-review) against the spec's algorithm section. Resolve every issue and confirm tests still green before starting Task 1. Do NOT proceed to Task 1 until this gate is green.

---

## Task 1: Structured TCP segment extraction in the dissector

**Files:**
- Modify: `Sources/MatrixNetDissection/DissectionSupport.swift` (add `payloadEnd`, `tcpSegment`)
- Modify: `Sources/MatrixNetDissection/IPv4Dissector.swift:66-72` / `IPv6Dissector.swift:48-54` (set `payloadEnd`)
- Modify: `Sources/MatrixNetDissection/TransportDissectors.swift:3-49` (TCPDissector builds `TCPSegment`)
- Modify: `Sources/MatrixNetDissection/PacketDissector.swift:24-58,147-157` (thread `payloadEnd` + `tcpSegment`)
- Modify: `Sources/MatrixNetDissection/DissectionResult.swift:69-89` (`DissectedPacket.tcpSegment`)
- Test: `Tests/MatrixNetDissectionTests/TCPSegmentTests.swift`

**Interfaces:**
- Consumes: `TCPSegment`, `TCPFlags` (Task 0).
- Produces: `DissectedPacket.tcpSegment: TCPSegment?` (used by Task 2/3).

- [ ] **Step 1: Write the failing test**

Create `Tests/MatrixNetDissectionTests/TCPSegmentTests.swift`:

```swift
import MatrixNetModel
import Testing
@testable import MatrixNetDissection

@Suite("TCP segment extraction")
struct TCPSegmentTests {
    /// IPv4 + TCP, SYN+ACK, 4 payload bytes. Built by hand so the structured
    /// fields are predictable. IHL=5 (20-byte IP header), data offset=5 (20-byte
    /// TCP header), totalLength=44 (20+20+4).
    private func synAckPacket() -> [UInt8] {
        var p: [UInt8] = [
            0x45, 0x00, 0x00, 0x2C,             // ver/IHL, DSCP, total length = 44
            0x00, 0x00, 0x40, 0x00,             // id, flags/frag (DF)
            0x40, 0x06, 0x00, 0x00,             // TTL, proto=6 (TCP), checksum
            0x0A, 0x00, 0x00, 0x01,             // src 10.0.0.1
            0x0A, 0x00, 0x00, 0x02              // dst 10.0.0.2
        ]
        p += [
            0x01, 0xBB, 0xC0, 0x00,             // src port 443, dst port 49152
            0x00, 0x00, 0x10, 0x00,             // sequence = 0x1000
            0x00, 0x00, 0x20, 0x00,             // ack = 0x2000
            0x50, 0x12, 0xFF, 0xFF,             // data offset 5, flags SYN+ACK (0x012), window
            0x00, 0x00, 0x00, 0x00              // checksum, urgent
        ]
        p += [0xDE, 0xAD, 0xBE, 0xEF]           // 4 payload bytes
        return p
    }

    @Test("dissecting an IPv4 TCP packet yields a structured TCP segment")
    func extractsSegment() throws {
        let packet = synAckPacket()
        let dissected = PacketDissector().dissect(packet, linkType: .rawIP)
        let segment = try #require(dissected.tcpSegment)
        #expect(segment.flags == [.syn, .ack])
        #expect(segment.sequence == 0x1000)
        #expect(segment.acknowledgement == 0x2000)
        #expect(segment.payloadLength == 4)
    }

    @Test("a UDP packet has no TCP segment")
    func udpHasNoSegment() {
        // Minimal IPv4+UDP: totalLength 28, proto 17.
        let packet: [UInt8] = [
            0x45, 0x00, 0x00, 0x1C, 0x00, 0x00, 0x00, 0x00,
            0x40, 0x11, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x01, 0x0A, 0x00, 0x00, 0x02,
            0x30, 0x39, 0x00, 0x35, 0x00, 0x08, 0x00, 0x00
        ]
        #expect(PacketDissector().dissect(packet, linkType: .rawIP).tcpSegment == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter "TCP segment extraction"`
Expected: FAIL — `dissected.tcpSegment` not a member of `DissectedPacket`.

- [ ] **Step 3: Add `payloadEnd` to `NetworkLayerResult` and `tcpSegment` to `TransportLayerResult`**

In `DissectionSupport.swift`, change `NetworkLayerResult` and `TransportLayerResult`:

```swift
/// Intermediate result of dissecting a network (IP) layer.
struct NetworkLayerResult {
    let node: DissectionNode
    /// IANA IP protocol number of the payload.
    let ipProtocol: UInt8
    /// Absolute offset where the transport layer begins.
    let payloadOffset: Int
    /// Absolute offset where the IP datagram's payload ends (from the IP length
    /// field), so a transport layer can size its payload without trusting the
    /// captured buffer length (which may include link-layer padding).
    let payloadEnd: Int
    let source: IPAddress
    let destination: IPAddress
}

/// Intermediate result of dissecting a transport layer.
struct TransportLayerResult {
    let node: DissectionNode
    let sourcePort: UInt16
    let destinationPort: UInt16
    /// Absolute offset where the application payload begins.
    let payloadOffset: Int
    /// The structured TCP fields, when the transport is TCP (nil for UDP).
    let tcpSegment: TCPSegment?
}
```

Add `import MatrixNetModel` at the top of `DissectionSupport.swift` if not already present (it imports `Foundation` and `MatrixNetModel` already — verify; `TCPSegment` lives in `MatrixNetModel`).

- [ ] **Step 4: Populate `payloadEnd` in the IP dissectors**

`IPv4Dissector.swift` — change the returned `NetworkLayerResult` (clamp to the buffer):

```swift
        return NetworkLayerResult(
            node: node,
            ipProtocol: ipProtocol,
            payloadOffset: start + headerLength,
            payloadEnd: min(start + Int(totalLength), bytes.count),
            source: source,
            destination: destination
        )
```

`IPv6Dissector.swift` — change the returned `NetworkLayerResult`:

```swift
        return NetworkLayerResult(
            node: node,
            ipProtocol: nextHeader,
            payloadOffset: start + headerLength,
            payloadEnd: min(start + headerLength + Int(payloadLength), bytes.count),
            source: source,
            destination: destination
        )
```

- [ ] **Step 5: Build the `TCPSegment` in `TCPDissector`**

`TransportDissectors.swift` — add `import MatrixNetModel` at the top of the file, then change `TCPDissector.dissect` to accept `segmentEnd:` and emit the segment. Replace the signature and the `return`:

```swift
import MatrixNetModel

/// Dissects a TCP header (RFC 9293), decoding the flag bits and honouring the
/// data-offset field for the payload boundary.
enum TCPDissector {
    static func dissect(_ bytes: [UInt8], at start: Int, segmentEnd: Int) throws -> TransportLayerResult {
        var reader = ByteReader(bytes, offset: start)
        let sourcePort = try reader.readUInt16()
        let destinationPort = try reader.readUInt16()
        let sequence = try reader.readUInt32()
        let acknowledgement = try reader.readUInt32()
        let offsetAndFlags = try reader.readUInt16()
        let dataOffsetWords = Int(offsetAndFlags >> 12)
        let flags = offsetAndFlags & 0x01FF
        let window = try reader.readUInt16()
        _ = try reader.readUInt16() // checksum (not validated)
        _ = try reader.readUInt16() // urgent pointer

        let headerLength = max(20, dataOffsetWords * 4)
        let payloadOffset = start + headerLength
        let payloadLength = max(0, segmentEnd - payloadOffset)

        let fields = [
            DissectionField(name: "Source Port", value: "\(sourcePort)", byteRange: start ..< start + 2),
            DissectionField(name: "Destination Port", value: "\(destinationPort)", byteRange: start + 2 ..< start + 4),
            DissectionField(name: "Sequence Number", value: "\(sequence)", byteRange: start + 4 ..< start + 8),
            DissectionField(name: "Acknowledgement", value: "\(acknowledgement)", byteRange: start + 8 ..< start + 12),
            DissectionField(name: "Flags", value: tcpFlagsDescription(flags), byteRange: start + 12 ..< start + 14),
            DissectionField(name: "Window", value: "\(window)", byteRange: start + 14 ..< start + 16)
        ]
        let node = DissectionNode(
            label: "Transmission Control Protocol",
            shortName: "TCP",
            fields: fields,
            byteRange: start ..< start + 20
        )
        return TransportLayerResult(
            node: node,
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            payloadOffset: payloadOffset,
            tcpSegment: TCPSegment(
                flags: TCPFlags(rawValue: flags),
                sequence: sequence,
                acknowledgement: acknowledgement,
                payloadLength: payloadLength
            )
        )
    }
```

Note: the existing `flags` mask is `& 0x01FF` (9 bits incl. NS). `TCPFlags` only defines FIN..URG (low 6 bits); `TCPFlags(rawValue: flags)` keeps the raw value but `.contains` only checks the defined bits — correct. `UDPDissector` must now set `tcpSegment: nil` in its `TransportLayerResult` return.

- [ ] **Step 6: Set `tcpSegment: nil` in `UDPDissector`**

`TransportDissectors.swift` — in `UDPDissector.dissect`, change the `return` to include `tcpSegment: nil`:

```swift
        return TransportLayerResult(
            node: node,
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            payloadOffset: start + headerLength,
            tcpSegment: nil
        )
```

- [ ] **Step 7: Thread `segmentEnd` and `tcpSegment` through `PacketDissector`**

`PacketDissector.swift` — `parseTransportLayer` gains `segmentEnd:` and forwards it to TCP:

```swift
    private func parseTransportLayer(
        _ bytes: [UInt8],
        proto: TransportProtocol,
        at offset: Int,
        segmentEnd: Int
    ) -> TransportLayerResult? {
        switch proto {
        case .tcp: try? TCPDissector.dissect(bytes, at: offset, segmentEnd: segmentEnd)
        case .udp: try? UDPDissector.dissect(bytes, at: offset)
        default: nil
        }
    }
```

Update the call site in `dissect(_:linkType:)`:

```swift
        let proto = TransportProtocol(ipProtocolNumber: network.ipProtocol)
        guard let transport = parseTransportLayer(
            bytes,
            proto: proto,
            at: network.payloadOffset,
            segmentEnd: network.payloadEnd
        ) else {
            return DissectedPacket(layers: layers, fiveTuple: nil, summary: summarize(layers, fiveTuple: nil))
        }
        layers.append(transport.node)
```

And include `tcpSegment` in the final `DissectedPacket(...)` return:

```swift
        return DissectedPacket(
            layers: layers,
            fiveTuple: fiveTuple,
            summary: summarize(layers, fiveTuple: fiveTuple),
            hostnames: hostnames,
            tlsClientFingerprint: tlsClientFingerprint,
            tcpSegment: transport.tcpSegment
        )
```

- [ ] **Step 8: Add `tcpSegment` to `DissectedPacket`**

`DissectionResult.swift` — add the stored property and init parameter:

```swift
    /// The JA4 TLS client fingerprint, when this packet is a TLS ClientHello.
    public let tlsClientFingerprint: String?
    /// The structured TCP header fields, when this packet is TCP (for quality).
    public let tcpSegment: TCPSegment?

    public init(
        layers: [DissectionNode],
        fiveTuple: FiveTuple?,
        summary: String,
        hostnames: [HostnameObservation] = [],
        tlsClientFingerprint: String? = nil,
        tcpSegment: TCPSegment? = nil
    ) {
        self.layers = layers
        self.fiveTuple = fiveTuple
        self.summary = summary
        self.hostnames = hostnames
        self.tlsClientFingerprint = tlsClientFingerprint
        self.tcpSegment = tcpSegment
    }
```

- [ ] **Step 9: Run the tests to verify they pass**

Run: `swift test --filter "TCP segment extraction"`
Expected: PASS (2 tests).

- [ ] **Step 10: Run the full dissection suite for regressions**

Run: `swift test --filter MatrixNetDissectionTests`
Expected: PASS (TLS/QUIC/HTTP/DNS unaffected — the new `payloadEnd`/`tcpSegment` are additive).

- [ ] **Step 11: Lint**

Run: `swiftformat --lint Sources/MatrixNetDissection && swiftlint --strict --quiet`
Expected: clean.

- [ ] **Step 12: Commit**

```bash
git add Sources/MatrixNetDissection Tests/MatrixNetDissectionTests/TCPSegmentTests.swift
git commit -m "feat(dissection): emit structured TCPSegment (flags/seq/ack/payloadLength) on DissectedPacket"
```

---

## Task 2: ConnectionAggregator quality attribution

**Files:**
- Modify: `Sources/MatrixNetCapture/ConnectionAggregator.swift`
- Test: `Tests/MatrixNetCaptureTests/AggregatorQualityTests.swift`

**Interfaces:**
- Consumes: `FlowQualityTracker`, `FlowQuality`, `TCPSegment` (Task 0); `FlowKey`, `Connection` (existing).
- Produces:
  - `public struct AppFlowQuality: Sendable, Equatable { public let app: String; public let address: IPAddress; public let quality: FlowQuality }`
  - `func recordTCP(_ segment: TCPSegment, timestampMicros: UInt64, inbound: Bool, flowKey: FlowKey, pid: Int32) async`
  - `func qualitySnapshot() -> [AppFlowQuality]`

- [ ] **Step 1: Write the failing test**

Create `Tests/MatrixNetCaptureTests/AggregatorQualityTests.swift`:

```swift
import Foundation
import MatrixNetModel
import Testing
@testable import MatrixNetCapture

@Suite("ConnectionAggregator quality")
struct AggregatorQualityTests {
    private func connection(_ port: UInt16, pid: Int32 = 501) throws -> Connection {
        let source = try Endpoint(address: #require(IPAddress("192.168.1.5")), port: port)
        let destination = try Endpoint(address: #require(IPAddress("1.1.1.1")), port: 443)
        return Connection(
            fiveTuple: FiveTuple(proto: .tcp, source: source, destination: destination),
            app: AppIdentity(pid: pid),
            startedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test("handshake segments produce a per-app quality snapshot")
    func handshake() async throws {
        let aggregator = ConnectionAggregator()
        let conn = try connection(50000)
        await aggregator.apply(.added(conn))
        let key = conn.fiveTuple.flowKey
        await aggregator.recordTCP(
            TCPSegment(flags: .syn, sequence: 100, acknowledgement: 0, payloadLength: 0),
            timestampMicros: 1_000_000, inbound: false, flowKey: key, pid: 501
        )
        await aggregator.recordTCP(
            TCPSegment(flags: [.syn, .ack], sequence: 5000, acknowledgement: 101, payloadLength: 0),
            timestampMicros: 1_030_000, inbound: true, flowKey: key, pid: 501
        )
        let snapshot = await aggregator.qualitySnapshot()
        #expect(snapshot.count == 1)
        #expect(snapshot.first?.app == conn.app.displayName)
        #expect(snapshot.first?.quality.handshakeRTTms == 30.0)
    }

    @Test("a segment for an unknown flow is dropped")
    func unknownFlow() async throws {
        let aggregator = ConnectionAggregator()
        let conn = try connection(50000)
        await aggregator.recordTCP(
            TCPSegment(flags: .syn, sequence: 1, acknowledgement: 0, payloadLength: 0),
            timestampMicros: 0, inbound: false, flowKey: conn.fiveTuple.flowKey, pid: 501
        )
        #expect(await aggregator.qualitySnapshot().isEmpty)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter "ConnectionAggregator quality"`
Expected: FAIL — `recordTCP`/`qualitySnapshot`/`AppFlowQuality` undefined.

- [ ] **Step 3: Add the quality state, `AppFlowQuality`, `recordTCP`, `qualitySnapshot` to the aggregator**

In `ConnectionAggregator.swift`, after the `fingerprintsByApp` declaration add:

```swift
    /// One `FlowQualityTracker` per live flow, fed segment-by-segment while
    /// capturing. Keyed by `FlowKey` (direction-insensitive) so both directions
    /// of a flow accumulate into the same tracker.
    private var qualityByFlow: [FlowKey: FlowQualityTracker] = [:]
    /// The app display name a flow's quality belongs to, captured at record time
    /// so the snapshot survives the connection's removal from the live set.
    private var qualityApp: [FlowKey: (app: String, address: IPAddress)] = [:]
```

Add the `AppFlowQuality` type near `UsageFlowTotal`:

```swift
    /// The passively measured quality of one app's flow to a destination.
    public struct AppFlowQuality: Sendable, Equatable {
        public let app: String
        public let address: IPAddress
        public let quality: FlowQuality
    }
```

Add the record + snapshot methods near `recordFingerprint`/`fingerprintSnapshot`:

```swift
    /// Feeds one observed TCP segment into the quality tracker for its flow.
    /// Dropped when the flow cannot be resolved to a tracked connection.
    public func recordTCP(
        _ segment: TCPSegment,
        timestampMicros: UInt64,
        inbound: Bool,
        flowKey: FlowKey,
        pid: Int32
    ) async {
        guard let id = await correlator.connectionID(forPacketFlow: flowKey, pid: pid),
              let connection = connections[id] else { return }
        qualityByFlow[flowKey, default: FlowQualityTracker()]
            .ingest(timestampMicros: timestampMicros, inbound: inbound, segment: segment)
        qualityApp[flowKey] = (connection.app.displayName, connection.fiveTuple.destination.address)
    }

    /// A snapshot of every tracked flow's quality, attributed to its app.
    public func qualitySnapshot() -> [AppFlowQuality] {
        qualityByFlow.compactMap { key, tracker in
            guard let owner = qualityApp[key] else { return nil }
            return AppFlowQuality(app: owner.app, address: owner.address, quality: tracker.quality)
        }
    }
```

Note: `qualityByFlow[flowKey, default:].ingest(...)` mutates in place because `FlowQualityTracker` is a struct stored in a dictionary — Swift's default-subscript-with-mutation works here. Verify the build; if the compiler rejects the in-place mutate on the default subscript, use the explicit form:
```swift
        var tracker = qualityByFlow[flowKey] ?? FlowQualityTracker()
        tracker.ingest(timestampMicros: timestampMicros, inbound: inbound, segment: segment)
        qualityByFlow[flowKey] = tracker
```

- [ ] **Step 4: Clear quality state in `reset()`**

Add to `reset()`:

```swift
        qualityByFlow.removeAll()
        qualityApp.removeAll()
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter "ConnectionAggregator quality"`
Expected: PASS (2 tests).

- [ ] **Step 6: Run the capture suite for regressions**

Run: `swift test --filter MatrixNetCaptureTests`
Expected: PASS.

- [ ] **Step 7: Lint**

Run: `swiftformat --lint Sources/MatrixNetCapture Tests/MatrixNetCaptureTests/AggregatorQualityTests.swift && swiftlint --strict --quiet`
Expected: clean.

- [ ] **Step 8: Commit**

```bash
git add Sources/MatrixNetCapture/ConnectionAggregator.swift Tests/MatrixNetCaptureTests/AggregatorQualityTests.swift
git commit -m "feat(capture): per-flow FlowQualityTracker attribution + qualitySnapshot"
```

---

## Task 3: App wiring + "Quality" inspector section + localization

**Files:**
- Modify: `App/Sources/PacketCaptureModel.swift` (record TCP segments)
- Modify: `App/Sources/AppModel.swift` (live quality map + `quality(for:)`)
- Modify: `App/Sources/ConnectionInspector.swift` (Quality section)
- Modify: `App/Resources/Localizable.xcstrings` (new strings ×8)

**Interfaces:**
- Consumes: `DissectedPacket.tcpSegment` (Task 1), `ConnectionAggregator.recordTCP`/`qualitySnapshot`/`AppFlowQuality` (Task 2).
- Produces: `AppModel.quality(for connection: Connection) -> FlowQuality?`.

> This task is verified by build + launch-smoke + a screenshot of the inspector (GUI navigation can't be driven in the sandbox; verify the view compiles, the app launches, and the section renders its empty state). No new unit test is required beyond the build, because the wiring is glue over already-tested cores.

- [ ] **Step 1: Record TCP segments in `PacketCaptureModel.attribute`**

In `App/Sources/PacketCaptureModel.swift`, add a captured-segment struct next to `CapturedFingerprint`:

```swift
    /// A captured TCP segment awaiting per-flow quality attribution.
    private struct CapturedSegment {
        let segment: TCPSegment
        let timestampMicros: UInt64
        let inbound: Bool
        let flowKey: FlowKey
        let pid: Int32
    }
```

In `attribute(_:)`, build the segment list alongside `fingerprints`:

```swift
        let segments = rows.compactMap { row -> CapturedSegment? in
            guard let tcp = row.dissected.tcpSegment, let tuple = row.dissected.fiveTuple else { return nil }
            return CapturedSegment(
                segment: tcp,
                timestampMicros: UInt64((row.packet.timestamp * 1_000_000).rounded()),
                inbound: row.packet.direction == 2,
                flowKey: tuple.flowKey,
                pid: row.packet.pid
            )
        }
```

Extend the early-out guard and the detached task:

```swift
        guard !attributions.isEmpty || !hostnames.isEmpty || !fingerprints.isEmpty || !segments.isEmpty else { return }
        Task.detached {
            await attribution.attributePackets(attributions)
            for observation in hostnames {
                await attribution.recordHostname(observation.name, for: observation.ip)
            }
            for fingerprint in fingerprints {
                await attribution.recordFingerprint(fingerprint.ja4, flowKey: fingerprint.flowKey, pid: fingerprint.pid)
            }
            for s in segments {
                await attribution.recordTCP(
                    s.segment, timestampMicros: s.timestampMicros, inbound: s.inbound, flowKey: s.flowKey, pid: s.pid
                )
            }
        }
```

`TCPSegment`/`FlowKey` come from `MatrixNetModel` — confirm `PacketCaptureModel.swift` imports it (it uses `FlowKey` for `CapturedFingerprint`, so it does).

- [ ] **Step 2: Maintain a live quality map in `AppModel`**

In `App/Sources/AppModel.swift`, add storage near `fingerprintsByApp`:

```swift
    /// Live per-(app, destination) quality, refreshed from the aggregator each
    /// poll while capturing. Keyed by "app\u{1F}address". Not persisted — quality
    /// is a live diagnostic, not history.
    private var qualityByKey: [String: FlowQuality] = [:]
```

In the periodic refresh loop (where `flushFingerprints` / `ProxyInfo.refresh()` are called), add a quality refresh. Add the method in the same extension as `flushFingerprints`:

```swift
    /// Refreshes the live quality map from the aggregator (cheap; no persistence).
    func refreshQuality() async {
        let snapshot = await aggregator.qualitySnapshot()
        var map: [String: FlowQuality] = [:]
        for item in snapshot {
            map["\(item.app)\u{1F}\(item.address.description)"] = item.quality
        }
        qualityByKey = map
    }

    /// The measured quality for a connection's (app, destination), if observed.
    public func quality(for connection: Connection) -> FlowQuality? {
        qualityByKey["\(connection.app.displayName)\u{1F}\(connection.fiveTuple.destination.address.description)"]
    }
```

Call `await self?.refreshQuality()` next to the existing `await self?.flushFingerprints(now: Date())` in the refresh loop.

- [ ] **Step 3: Add the "Quality" section to the inspector**

In `App/Sources/ConnectionInspector.swift`, add `qualitySection(for:)` to the `Form` after `fingerprintSection(for: connection)`:

```swift
                fingerprintSection(for: connection)
                qualitySection(for: connection)
```

Implement it (TCP-only; empty states mirror the fingerprint section):

```swift
    /// Passively measured network quality for this connection's flow — handshake
    /// RTT, retransmits, and setup time. Requires packet capture (per-packet
    /// timing); shows guidance otherwise.
    @ViewBuilder
    private func qualitySection(for connection: Connection) -> some View {
        Section("Network Quality") {
            if connection.fiveTuple.proto != .tcp {
                Text("Network quality is measured for TCP connections.")
                    .foregroundStyle(.secondary).font(.callout)
            } else if let quality = model.quality(for: connection) {
                if let rtt = quality.handshakeRTTms {
                    LabeledContent("Handshake RTT") { mono(String(format: "%.1f ms", rtt)) }
                }
                if let setup = quality.setupMs {
                    LabeledContent("Connection Setup") { mono(String(format: "%.1f ms", setup)) }
                }
                LabeledContent("Retransmits") { mono("\(quality.retransmits)") }
                LabeledContent("Out of Order") { mono("\(quality.outOfOrder)") }
                if quality.handshakeRTTms == nil {
                    Text("Handshake not captured (connection opened before capture).")
                        .foregroundStyle(.secondary).font(.caption)
                }
            } else {
                Text(capture.isCapturing
                    ? LocalizedStringKey("No quality data observed yet for this connection.")
                    : LocalizedStringKey("Enable packet capture in the Packets tab to measure network quality."))
                    .foregroundStyle(.secondary).font(.callout)
            }
        }
    }
```

- [ ] **Step 4: Add the new strings to `Localizable.xcstrings` (8 languages)**

New keys (English source → translations). Use the existing python helper pattern (as in prior releases) or edit the catalog directly. Keys and en values:

| Key | en |
|-----|-----|
| `Network Quality` | Network Quality |
| `Handshake RTT` | Handshake RTT |
| `Connection Setup` | Connection Setup |
| `Retransmits` | Retransmits |
| `Out of Order` | Out of Order |
| `Network quality is measured for TCP connections.` | Network quality is measured for TCP connections. |
| `Handshake not captured (connection opened before capture).` | Handshake not captured (connection opened before capture). |
| `No quality data observed yet for this connection.` | No quality data observed yet for this connection. |
| `Enable packet capture in the Packets tab to measure network quality.` | Enable packet capture in the Packets tab to measure network quality. |

Translations (de / es / fr / ja / ko / zh-Hans / zh-Hant):

- **Network Quality**: Netzwerkqualität / Calidad de red / Qualité du réseau / ネットワーク品質 / 네트워크 품질 / 网络质量 / 網路品質
- **Handshake RTT**: Handshake-RTT / RTT de handshake / RTT de handshake / ハンドシェイク RTT / 핸드셰이크 RTT / 握手 RTT / 交握 RTT
- **Connection Setup**: Verbindungsaufbau / Establecimiento de conexión / Établissement de connexion / 接続確立 / 연결 설정 / 连接建立 / 連線建立
- **Retransmits**: Übertragungswiederholungen / Retransmisiones / Retransmissions / 再送 / 재전송 / 重传 / 重傳
- **Out of Order**: Außerhalb der Reihenfolge / Fuera de orden / Hors séquence / 順序の乱れ / 순서 어긋남 / 乱序 / 亂序
- **Network quality is measured for TCP connections.**: Die Netzwerkqualität wird für TCP-Verbindungen gemessen. / La calidad de red se mide para conexiones TCP. / La qualité du réseau est mesurée pour les connexions TCP. / ネットワーク品質は TCP 接続で測定されます。 / 네트워크 품질은 TCP 연결에서 측정됩니다. / 网络质量针对 TCP 连接进行测量。 / 網路品質針對 TCP 連線進行測量。
- **Handshake not captured (connection opened before capture).**: Handshake nicht erfasst (Verbindung vor der Erfassung geöffnet). / Handshake no capturado (la conexión se abrió antes de la captura). / Handshake non capturé (connexion ouverte avant la capture). / ハンドシェイクは記録されていません(キャプチャ開始前に接続が確立)。 / 핸드셰이크가 캡처되지 않음(캡처 전에 연결이 열림). / 未捕获握手(连接在抓包前已建立)。 / 未擷取交握(連線在抓包前已建立)。
- **No quality data observed yet for this connection.**: Noch keine Qualitätsdaten für diese Verbindung beobachtet. / Aún no se han observado datos de calidad para esta conexión. / Aucune donnée de qualité observée pour cette connexion. / この接続の品質データはまだありません。 / 이 연결에 대한 품질 데이터가 아직 없습니다. / 尚未观测到此连接的质量数据。 / 尚未觀測到此連線的品質資料。
- **Enable packet capture in the Packets tab to measure network quality.**: Aktivieren Sie die Paketerfassung im Tab „Pakete", um die Netzwerkqualität zu messen. / Active la captura de paquetes en la pestaña Paquetes para medir la calidad de red. / Activez la capture de paquets dans l'onglet Paquets pour mesurer la qualité du réseau. / ネットワーク品質を測定するには、「パケット」タブでパケットキャプチャを有効にしてください。 / 네트워크 품질을 측정하려면 패킷 탭에서 패킷 캡처를 활성화하세요. / 在“数据包”标签页启用抓包以测量网络质量。 / 在「封包」標籤頁啟用抓包以測量網路品質。

- [ ] **Step 5: Build the app and run the full test suite**

Run: `swift build && swift test`
Expected: build succeeds; all tests pass.

- [ ] **Step 6: Lint everything**

Run: `swiftformat --lint Sources App && swiftlint --strict --quiet`
Expected: clean.

- [ ] **Step 7: Generate the Xcode project and build the app target**

Run: `xcodegen generate && xcodebuild -scheme MatrixNet -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet`
Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Launch-smoke + inspector screenshot**

Build a local app bundle, launch it, confirm the process stays alive, capture a screenshot, and confirm the inspector shows the new "Network Quality" section (empty state acceptable without capture). Verify the xcstrings catalog has no missing-translation warnings.

- [ ] **Step 9: Commit**

```bash
git add App/Sources/PacketCaptureModel.swift App/Sources/AppModel.swift App/Sources/ConnectionInspector.swift App/Resources/Localizable.xcstrings
git commit -m "feat(app): Network Quality inspector section (handshake RTT / retransmits / setup)"
```

---

## Task 4: Docs, version bump, and release 1.4.0 (build 34)

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `README.md` + `README.de.md` / `.es.md` / `.fr.md` / `.ja.md` / `.ko.md` / `.zh-Hans.md` / `.zh-Hant.md`
- Modify: `project.yml`

- [ ] **Step 1: Add the CHANGELOG entry**

Prepend a `## [1.4.0] - 2026-06-28` section describing per-app passive TCP network-quality diagnostics (handshake RTT, retransmits, out-of-order, connection-setup time) in the connection inspector; capture-only.

- [ ] **Step 2: Add a README feature bullet in all 8 languages**

Add a "per-app passive network quality diagnostics (handshake RTT / retransmits / setup time)" bullet, anchored consistently with the JA4/QUIC bullets (after the protocol-dissection bullet) in `README.md` and each translation, each in its own language.

- [ ] **Step 3: Bump the version to 1.4.0 / 34**

In `project.yml`: set `settings.base.MARKETING_VERSION = 1.4.0`, `CURRENT_PROJECT_VERSION = 34`, and update both `info.properties` blocks (`CFBundleShortVersionString = 1.4.0`, `CFBundleVersion = 34`).

- [ ] **Step 4: Verify the build with the new version**

Run: `xcodegen generate && swift build && swift test`
Expected: clean; tests pass.

- [ ] **Step 5: Commit and tag**

```bash
git add CHANGELOG.md README*.md project.yml
git commit -m "release: per-app network quality diagnostics (1.4.0)"
git tag v1.4.0
```

- [ ] **Step 6: Push and let CI build/notarize**

```bash
git push origin main --tags
```

- [ ] **Step 7: Verify the release**

After CI: confirm GitHub Release `v1.4.0`, the appcast advertises `sparkle:version=34`, the notarized DMG/zip is attached, and a local Developer-ID install of the new build launches and shows the Network Quality section. Do NOT mark the release done until the appcast verifies.

---

## Self-Review

**Spec coverage:** handshake RTT (Task 0 algorithm + Task 2/3 surfacing) ✓; retransmits ✓; connection-setup time (setupMs) ✓; out-of-order ✓; capture-only boundary + empty states (Task 3) ✓; per-app attribution (Task 2) ✓; inspector "Quality" section (Task 3) ✓; reuse of StreamReassembler wraparound technique (Task 0) ✓; version 1.4.0/34 + 8-lang docs + appcast (Task 4) ✓.

**Spec deviations (intentional, within technical discretion):** TTFB server-think-time breakdown is deferred (spec §2 already labels it best-effort/future); not in `FlowQuality` v1. UDP/QUIC RTT deferred (spec §2). `FlowQuality` field set is `handshakeRTTms / retransmits / outOfOrder / setupMs` — matches spec §3.1.

**Placeholder scan:** no TBD/TODO; every code step shows complete code.

**Type consistency:** `TCPSegment(flags:sequence:acknowledgement:payloadLength:)`, `TCPFlags` (`.syn/.ack/...`), `FlowQuality(handshakeRTTms:retransmits:outOfOrder:setupMs:)`, `FlowQualityTracker().ingest(timestampMicros:inbound:segment:)` / `.quality`, `AppFlowQuality(app:address:quality:)`, `recordTCP(_:timestampMicros:inbound:flowKey:pid:)`, `qualitySnapshot()`, `AppModel.quality(for:)` — names identical across all tasks.
