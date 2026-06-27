import MatrixNetGeoIP
import MatrixNetModel
import SwiftUI

/// The map legend overlay (destination / threat / this Mac).
struct GlobeLegend: View {
    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 14) {
                legendDot(Color(red: 0.32, green: 0.82, blue: 0.58), "Destination")
                legendDot(Color(red: 0.94, green: 0.46, blue: 0.42), "Threat")
                legendDot(.white, "This Mac")
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(Color.white.opacity(0.6))
            .padding(12)
        }
    }

    private func legendDot(_ color: Color, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
        }
    }
}

/// Hover tooltip naming the destination under the pointer.
struct GlobeTooltip: View {
    let destination: GlobeDestination
    let isHistory: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(verbatim: GeoIPDatabase.flag(for: destination.country) ?? "🏳️")
                Text(verbatim: destination.name).font(.caption.weight(.semibold))
            }
            if isHistory {
                Text("\(destination.connections) records").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("\(destination.connections) active").font(.caption2).foregroundStyle(.secondary)
            }
            if destination.isThreat {
                Label("Threat", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(Theme.danger)
            }
        }
        .padding(7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.1)))
    }
}

/// The country list in the side panel; tapping a country drills into its detail.
struct GlobeDestinationsList: View {
    let destinations: [GlobeDestination]
    let isHistory: Bool
    let onSelect: (GlobeDestination) -> Void

    private var maxConnections: Int {
        max(1, destinations.map(\.connections).max() ?? 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isHistory ? "History destinations" : "Active destinations")
                .font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
            if destinations.isEmpty {
                Text("No located connections.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(destinations) { destination in
                            Button { onSelect(destination) } label: { row(destination) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row(_ destination: GlobeDestination) -> some View {
        HStack(spacing: 9) {
            Text(verbatim: GeoIPDatabase.flag(for: destination.country) ?? "🏳️")
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(verbatim: destination.name).font(.callout).lineLimit(1)
                    if destination.isThreat {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2).foregroundStyle(Theme.danger)
                    }
                    Spacer()
                    Text(verbatim: "\(destination.connections)")
                        .font(Theme.mono(11)).foregroundStyle(.secondary)
                }
                bar(for: destination)
            }
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            destination.isThreat ? Theme.danger.opacity(0.1) : Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private func bar(for destination: GlobeDestination) -> some View {
        let tint = destination.isThreat ? Theme.danger : Theme.accent
        let fraction = max(0.04, Double(destination.connections) / Double(maxConnections))
        return GeometryReader { geometry in
            Capsule().fill(tint.opacity(0.16))
                .overlay(alignment: .leading) {
                    Capsule().fill(tint).frame(width: geometry.size.width * fraction)
                }
        }
        .frame(height: 4)
    }
}

/// The per-country detail in the side panel: each individual connection (live) or
/// history record reaching the selected country.
struct CountryDetailPanel: View {
    let country: String
    let isHistory: Bool
    let rows: [CountryConnectionRow]
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                Text(verbatim: GeoIPDatabase.flag(for: country) ?? "🏳️")
                Text(verbatim: Locale.current.localizedString(forRegionCode: country) ?? country)
                    .font(.headline).lineLimit(1)
                Spacer()
                Text(isHistory ? "\(rows.count) records" : "\(rows.count) active")
                    .font(Theme.mono(11)).foregroundStyle(.secondary)
            }

            if rows.isEmpty {
                Text("No connections.").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(rows) { row in
                            connectionRow(row)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func connectionRow(_ row: CountryConnectionRow) -> some View {
        HStack(spacing: 8) {
            Group {
                if let app = row.app, let icon = AppIconResolver.shared.cachedIcon(for: app) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(verbatim: row.appName).font(.caption.weight(.medium)).lineLimit(1)
                    if row.isThreat {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8)).foregroundStyle(Theme.danger)
                    }
                }
                Text(verbatim: row.endpoint)
                    .font(Theme.mono(10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 5) {
                    Text(verbatim: row.proto).font(.system(size: 9)).foregroundStyle(.secondary)
                    if let role = row.role, role != .unknown {
                        Text(LocalizedStringKey(role.label))
                            .font(.system(size: 9))
                            .foregroundStyle(role == .server ? Theme.inbound : Theme.accent)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            row.isThreat ? Theme.danger.opacity(0.1) : Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }
}
