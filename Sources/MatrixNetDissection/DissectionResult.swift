import MatrixNetModel

/// The link-layer framing of a captured buffer, which determines how the first
/// bytes are interpreted.
public enum LinkLayerType: Sendable, Equatable {
    /// Ethernet II framing (DLT_EN10MB).
    case ethernet
    /// BSD loopback framing (DLT_NULL): a 4-byte host-order address family.
    case nullLoopback
    /// Raw IP with no link header (DLT_RAW): the buffer starts at the IP header.
    case rawIP
}

/// A single named field within a dissected protocol layer, with the byte range
/// it occupies in the original packet (for hex-view highlighting).
public struct DissectionField: Sendable, Equatable {
    public let name: String
    public let value: String
    public let byteRange: Range<Int>?

    public init(name: String, value: String, byteRange: Range<Int>? = nil) {
        self.name = name
        self.value = value
        self.byteRange = byteRange
    }
}

/// One protocol layer in the dissection tree (e.g. Ethernet, IPv4, TCP, DNS).
public struct DissectionNode: Sendable {
    /// Full human-readable layer name, e.g. "Internet Protocol Version 4".
    public let label: String
    /// Short protocol tag, e.g. "IPv4".
    public let shortName: String
    public let fields: [DissectionField]
    public let children: [DissectionNode]
    /// The byte range this layer occupies in the original packet.
    public let byteRange: Range<Int>

    public init(
        label: String,
        shortName: String,
        fields: [DissectionField],
        children: [DissectionNode] = [],
        byteRange: Range<Int>
    ) {
        self.label = label
        self.shortName = shortName
        self.fields = fields
        self.children = children
        self.byteRange = byteRange
    }
}

/// The result of dissecting one packet: an ordered list of protocol layers, the
/// correlatable five-tuple when present, and a one-line summary.
public struct DissectedPacket: Sendable {
    public let layers: [DissectionNode]
    public let fiveTuple: FiveTuple?
    public let summary: String

    public init(layers: [DissectionNode], fiveTuple: FiveTuple?, summary: String) {
        self.layers = layers
        self.fiveTuple = fiveTuple
        self.summary = summary
    }

    /// The chain of short protocol names, e.g. `["Ethernet", "IPv4", "TCP"]`.
    public var protocolPath: [String] {
        layers.map(\.shortName)
    }

    /// The most specific (deepest) protocol identified, used as the column label.
    public var highestProtocol: String {
        layers.last?.shortName ?? "Unknown"
    }
}
