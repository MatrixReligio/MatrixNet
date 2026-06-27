import MatrixNetStore
import SwiftUI

/// Persisted connection history: which apps reached which hosts over time, with
/// cumulative bytes and sighting counts. Refreshes periodically while visible.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var records: [ConnectionHistoryRecord] = []
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\ConnectionHistoryRecord.lastSeen, order: .reverse)]
    @State private var columns = TableColumnCustomization<ConnectionHistoryRecord>()

    private var filtered: [ConnectionHistoryRecord] {
        let base: [ConnectionHistoryRecord]
        if search.isEmpty {
            base = records
        } else {
            let needle = search.lowercased()
            base = records.filter {
                $0.appName.lowercased().contains(needle) || $0.remoteHost.lowercased().contains(needle)
            }
        }
        return base.sorted(using: sortOrder)
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
                Table(filtered, sortOrder: $sortOrder, columnCustomization: $columns) {
                    TableColumn("Application", value: \.appName) { Text($0.appName).lineLimit(1) }
                        .width(min: 120, ideal: 180)
                        .customizationID("application")
                    TableColumn("Remote", value: \.remoteHost) { Text($0.remoteHost).font(Theme.mono(11)).lineLimit(1) }
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
                        Text(verbatim: "\($0.sightings)×").font(Theme.mono(11)).foregroundStyle(.secondary)
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
        }
        .navigationTitle("History")
        .searchable(text: $search, placement: .toolbar, prompt: "Filter history")
        .task {
            while !Task.isCancelled {
                records = model.recentHistory()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}
