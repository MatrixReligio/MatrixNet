import MatrixNetDissection
import MatrixNetModel
import MatrixNetPcap
import SwiftUI
import UniformTypeIdentifiers

/// Wireshark-style deep packet analyzer: a live packet list, a protocol-detail
/// tree, and a hex view — fed by the privileged PKTAP helper. Opt-in: until the
/// helper is enabled, an explanatory call-to-action is shown instead.
struct PacketsView: View {
    @Environment(PacketCaptureModel.self) private var capture
    @Environment(AppModel.self) private var model
    @State private var selection: UInt64?
    /// A throttled, freeze-on-selection snapshot of the live list, so a fast
    /// capture stream doesn't shift rows out from under a click or drop the
    /// selection. Refreshed a few times per second while nothing is selected,
    /// and frozen while a packet is selected so it can be inspected.
    @State private var displayedPackets: [PacketRow] = []
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\PacketRow.timestamp, order: .forward)]
    @State private var columns = TableColumnCustomization<PacketRow>()
    @AppStorage(Preferences.Key.showDomains.rawValue, store: SharedMetricsStore.sharedDefaults)
    private var showDomains = true

    /// A packet summary with IPs swapped for domain names when the toggle is on.
    private func displaySummary(_ packet: PacketRow) -> String {
        showDomains ? AddressDisplay.rewriteSummary(packet.summary, names: model.resolvedHostnames) : packet.summary
    }

    private var selectedPacket: PacketRow? {
        displayedPackets.first { $0.id == selection } ?? capture.packets.first { $0.id == selection }
    }

    private var sortedPackets: [PacketRow] {
        let base = search.isEmpty ? capture.packets : capture.packets.filter { matches($0, search) }
        return base.sorted(using: sortOrder)
    }

    /// Matches a packet against the filter by process, protocol, or summary
    /// (which carries the addresses and ports).
    private func matches(_ packet: PacketRow, _ query: String) -> Bool {
        let needle = query.lowercased()
        if packet.processName.lowercased().contains(needle) { return true }
        if packet.highestProtocol.lowercased().contains(needle) { return true }
        if displaySummary(packet).lowercased().contains(needle) { return true }
        return false
    }

    var body: some View {
        Group {
            if capture.helperState != .enabled, !capture.isCapturing {
                enableState
            } else {
                analyzer
            }
        }
        .navigationTitle("Packets")
        .searchable(text: $search, placement: .toolbar, prompt: "Filter by process, protocol, or address")
        .toolbar { toolbarContent }
        .onAppear { capture.refreshState() }
        .task {
            // Throttle the displayed list; freeze it while a packet is selected so
            // a fast stream can't move rows under the cursor or clear the choice.
            while !Task.isCancelled {
                if selection == nil {
                    displayedPackets = sortedPackets
                }
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
        .onChange(of: search) { _, _ in displayedPackets = sortedPackets }
        .onChange(of: sortOrder) { _, _ in displayedPackets = sortedPackets }
    }

    private var analyzer: some View {
        HSplitView {
            VStack(spacing: 0) {
                if let error = capture.lastError {
                    captureBanner(error)
                }
                if selection != nil {
                    pausedBanner
                }
                if capture.packets.isEmpty {
                    waitingState
                } else {
                    packetList
                }
            }
            .frame(minWidth: 360)
            Group {
                if let packet = selectedPacket {
                    ScrollView { PacketDetail(packet: packet) }
                } else {
                    // Centered in the pane: a ContentUnavailableView only fills and
                    // centers when given the full frame — wrapping it in a
                    // ScrollView (unbounded height) would pin it to the top.
                    ContentUnavailableView("No Packet Selected", systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 280)
        }
    }

    /// Shown inside the analyzer while capturing but before any packet arrives,
    /// or when capture is idle — with a way to (re)install the helper.
    private var waitingDescription: LocalizedStringKey {
        capture.isCapturing
            ? "Capturing — packets will appear as your apps use the network."
            : "Press Start to capture. If nothing shows up, reinstall the helper below."
    }

    private var waitingState: some View {
        ContentUnavailableView {
            Label(capture.isCapturing ? "Waiting for Packets" : "Capture Stopped", systemImage: "scope")
        } description: {
            Text(waitingDescription)
        } actions: {
            if !capture.isCapturing {
                Button("Start") { capture.startCapture() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
            Button("Reinstall Helper") { capture.reinstallHelper() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pausedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle.fill").foregroundStyle(Theme.accent)
            Text("Live updates paused while a packet is selected.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Resume") { selection = nil }.font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.accent.opacity(0.10))
    }

    private func captureBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.advisory)
            Text(message).font(.caption).lineLimit(2)
            Spacer()
            Button("Reinstall Helper") { capture.reinstallHelper() }.font(.caption)
        }
        .padding(8)
        .background(Theme.advisory.opacity(0.12))
    }

    private var packetList: some View {
        Table(displayedPackets, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn("Time", value: \.timestamp) {
                Text(verbatim: Format.preciseTime($0.timestamp)).font(Theme.mono(11))
            }
            .width(min: 96, ideal: 112, max: 150)
            .customizationID("time")
            TableColumn("Process", value: \.processName) {
                Text($0.processName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help($0.processName)
            }
            .width(min: 140, ideal: 220)
            .customizationID("process")
            TableColumn("Proto", value: \.highestProtocol) {
                Text($0.highestProtocol).font(Theme.mono(11)).foregroundStyle(Theme.accent)
            }
            .width(min: 48, ideal: 56, max: 90)
            .customizationID("proto")
            TableColumn("Summary", value: \.summary) { packet in
                Text(verbatim: displaySummary(packet))
                    .font(Theme.mono(11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(displaySummary(packet))
            }
            .customizationID("summary")
        }
        .persistTableColumns($columns, key: "table.packets.v2")
    }

    private var enableState: some View {
        ContentUnavailableView {
            Label("Deep Packet Analysis", systemImage: "scope")
        } description: {
            Text(
                """
                Capture raw packets — each attributed to the app that sent it — and inspect them \
                down to the byte. This installs a small privileged helper you approve once in \
                System Settings.
                """
            )
        } actions: {
            Button("Enable Packet Capture") { capture.enableHelper() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            if capture.helperState == .requiresApproval {
                Text("Approve “MatrixNet” in System Settings → General → Login Items & Extensions, then press Start.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                capture.isCapturing ? capture.stopCapture() : capture.startCapture()
            } label: {
                Label(
                    capture.isCapturing ? "Stop" : "Start",
                    systemImage: capture.isCapturing ? "stop.fill" : "play.fill"
                )
            }
            .tint(Theme.accent)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showDomains.toggle() } label: {
                Label(
                    showDomains ? LocalizedStringKey("Domains") : LocalizedStringKey("IPs"),
                    systemImage: showDomains ? "globe" : "number"
                )
            }
            .help("Show domain names or IP addresses")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { capture.clear() } label: { Label("Clear", systemImage: "trash") }
                .disabled(capture.packets.isEmpty)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { exportPcap() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(capture.packets.isEmpty)
        }
    }

    private func exportPcap() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "capture.pcapng"
        panel.allowedContentTypes = [UTType(filenameExtension: "pcapng") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let writer = PcapNGWriter(linkType: PcapLinkType.ethernet)
        var data = Data(writer.header())
        for packet in capture.packets {
            let comment = packet.pid > 0
                ? "\(packet.processName) (pid \(packet.pid))"
                : (packet.processName.isEmpty ? nil : packet.processName)
            let record = CapturedRecord(
                timestampMicros: UInt64(packet.timestamp.timeIntervalSince1970 * 1_000_000),
                originalLength: packet.bytes.count,
                data: packet.bytes,
                comment: comment
            )
            data.append(contentsOf: writer.packet(record))
        }
        try? data.write(to: url)
    }
}

/// The protocol-detail tree and hex dump for one packet.
private struct PacketDetail: View {
    let packet: PacketRow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(packet.layers.enumerated()), id: \.offset) { _, layer in
                DisclosureGroup {
                    ForEach(Array(layer.fields.enumerated()), id: \.offset) { _, field in
                        HStack(alignment: .top) {
                            Text(field.name).foregroundStyle(.secondary)
                            Spacer()
                            Text(field.value).font(Theme.mono(11)).textSelection(.enabled)
                                .multilineTextAlignment(.trailing)
                        }
                        .font(.caption)
                    }
                } label: {
                    Text(layer.label).font(.callout.weight(.medium))
                }
            }

            Divider()
            Text("Hex").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(hexDump(packet.bytes))
                .font(Theme.mono(10))
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hexDump(_ bytes: [UInt8]) -> String {
        var lines = [String]()
        for offset in stride(from: 0, to: bytes.count, by: 16) {
            let chunk = bytes[offset ..< min(offset + 16, bytes.count)]
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = chunk.map { (0x20 ... 0x7E).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
            lines.append(String(format: "%04x  %-47@  %@", offset, hex as NSString, ascii as NSString))
        }
        return lines.joined(separator: "\n")
    }
}
