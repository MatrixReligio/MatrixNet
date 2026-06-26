import MatrixNetStore
import SwiftUI

/// Persisted connection history: which apps reached which hosts over time, with
/// cumulative bytes and sighting counts. Refreshes periodically while visible.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var records: [ConnectionHistoryRecord] = []
    @State private var search = ""

    private var filtered: [ConnectionHistoryRecord] {
        guard !search.isEmpty else { return records }
        let needle = search.lowercased()
        return records.filter {
            $0.appName.lowercased().contains(needle) || $0.remoteHost.lowercased().contains(needle)
        }
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
                Table(filtered) {
                    TableColumn("Application") { Text($0.appName).lineLimit(1) }.width(min: 140, ideal: 180)
                    TableColumn("Remote") { Text($0.remoteHost).font(Theme.mono(11)).lineLimit(1) }
                        .width(min: 160, ideal: 220)
                    TableColumn("Proto") { Text($0.proto).font(Theme.mono(11)).foregroundStyle(.secondary) }.width(52)
                    TableColumn("In") { Text(Format.bytes(UInt64($0.bytesIn))).font(Theme.mono(11)) }.width(72)
                    TableColumn("Out") { Text(Format.bytes(UInt64($0.bytesOut))).font(Theme.mono(11)) }.width(72)
                    TableColumn("Seen") {
                        Text(verbatim: "\($0.sightings)×").font(Theme.mono(11)).foregroundStyle(.secondary)
                    }
                    .width(56)
                    TableColumn("Last") { Text($0.lastSeen, format: .dateTime.month().day().hour().minute()) }
                        .width(120)
                }
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
