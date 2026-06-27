import MatrixNetStore
import SwiftData
import SwiftUI

/// Persisted connection history: which apps reached which hosts over time, with
/// cumulative bytes and sighting counts. Refreshes periodically while visible.
/// Rows are selectable (a detail inspector) and filterable by time window.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var records: [ConnectionHistoryRecord] = []
    @State private var search = ""
    @State private var range: HistoryRange = .all
    @State private var sortOrder = [KeyPathComparator(\ConnectionHistoryRecord.lastSeen, order: .reverse)]
    @State private var columns = TableColumnCustomization<ConnectionHistoryRecord>()
    @State private var selection: PersistentIdentifier?
    @State private var showInspector = true

    private var filtered: [ConnectionHistoryRecord] {
        let cutoff = range.cutoff
        let needle = search.lowercased()
        let base = records.filter { record in
            if let cutoff, record.lastSeen < cutoff { return false }
            guard !needle.isEmpty else { return true }
            return record.appName.lowercased().contains(needle) || record.remoteHost.lowercased().contains(needle)
        }
        return base.sorted(using: sortOrder)
    }

    private var selectedRecord: ConnectionHistoryRecord? {
        records.first { $0.persistentModelID == selection }
    }

    var body: some View {
        Group {
            if records.isEmpty {
                ContentUnavailableView(
                    "No History Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Connections you make while monitoring is on are recorded here.")
                )
            } else {
                table
            }
        }
        .navigationTitle("History")
        .searchable(text: $search, placement: .toolbar, prompt: "Filter history")
        .toolbar { toolbarContent }
        .inspector(isPresented: $showInspector) {
            HistoryDetail(record: selectedRecord)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 340)
        }
        .task {
            while !Task.isCancelled {
                records = model.recentHistory()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var table: some View {
        Table(filtered, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn("Application", value: \.appName) {
                Text($0.appName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help($0.appName)
            }
            .width(min: 120, ideal: 200)
            .customizationID("application")
            TableColumn("Remote", value: \.remoteHost) {
                Text($0.remoteHost).font(Theme.mono(11)).lineLimit(1).truncationMode(.middle).help($0.remoteHost)
            }
            .width(min: 140, ideal: 220)
            .customizationID("remote")
            TableColumn("Proto", value: \.proto) {
                Text($0.proto).font(Theme.mono(11)).foregroundStyle(.secondary)
            }
            .width(min: 44, ideal: 52, max: 90)
            .customizationID("proto")
            TableColumn("In", value: \.bytesIn) { Text(Format.bytes(UInt64($0.bytesIn))).font(Theme.mono(11)) }
                .width(min: 56, ideal: 76, max: 140)
                .customizationID("in")
            TableColumn("Out", value: \.bytesOut) {
                Text(Format.bytes(UInt64($0.bytesOut))).font(Theme.mono(11))
            }
            .width(min: 56, ideal: 76, max: 140)
            .customizationID("out")
            TableColumn("Seen", value: \.sightings) {
                Text(verbatim: "\($0.sightings)×")
                    .font(Theme.mono(11)).foregroundStyle(.secondary)
                    .help("Times this app↔host↔protocol entry was observed (sampled about every 5 seconds).")
            }
            .width(min: 48, ideal: 60, max: 90)
            .customizationID("seen")
            TableColumn("Last", value: \.lastSeen) {
                Text($0.lastSeen, format: .dateTime.month().day().hour().minute())
            }
            .width(min: 100, ideal: 120, max: 180)
            .customizationID("last")
        }
        .persistTableColumns($columns, key: "table.history")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Time Range", selection: $range) {
                ForEach(HistoryRange.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showInspector.toggle() } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
        }
    }
}

/// Time window the history list is filtered to.
private enum HistoryRange: String, CaseIterable, Identifiable {
    case all, hour, day, week

    var id: String {
        rawValue
    }

    var label: LocalizedStringKey {
        switch self {
        case .all: "All Time"
        case .hour: "Last Hour"
        case .day: "Last 24 Hours"
        case .week: "Last 7 Days"
        }
    }

    var cutoff: Date? {
        switch self {
        case .all: nil
        case .hour: Date(timeIntervalSinceNow: -3600)
        case .day: Date(timeIntervalSinceNow: -86400)
        case .week: Date(timeIntervalSinceNow: -604_800)
        }
    }
}

/// Detail inspector for one history entry.
private struct HistoryDetail: View {
    let record: ConnectionHistoryRecord?

    var body: some View {
        if let record {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(record.appName).font(.title3.weight(.semibold)).lineLimit(2)
                    row("Remote", record.remoteHost, mono: true)
                    row("Protocol", record.proto, mono: true)
                    Divider()
                    row("Inbound", Format.bytes(UInt64(record.bytesIn)), mono: true)
                    row("Outbound", Format.bytes(UInt64(record.bytesOut)), mono: true)
                    row("Sightings", "\(record.sightings)", mono: true)
                    Divider()
                    row("First Seen", record.firstSeen.formatted(date: .abbreviated, time: .standard))
                    row("Last Seen", record.lastSeen.formatted(date: .abbreviated, time: .standard))
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("No Entry Selected", systemImage: "clock.arrow.circlepath")
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).font(.callout)
            Spacer(minLength: 12)
            Text(value)
                .font(mono ? Theme.mono(12) : .callout)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }
}
