import MatrixNetGeoIP
import MatrixNetMap
import MatrixNetModel
import SwiftUI

/// Shared map projection for the Globe view: an equirectangular world cropped to
/// the populated latitudes so land fills the canvas (the empty polar oceans are
/// trimmed). Every layer projects through this so dots, arcs and nodes align.
enum MapProjection {
    static let latitudeTop = 74.0
    static let latitudeBottom = -56.0

    static func point(_ coordinate: MapCoordinate, in size: CGSize) -> CGPoint {
        EquirectangularProjection.point(
            coordinate, in: size, latitudeTop: latitudeTop, latitudeBottom: latitudeBottom
        )
    }

    static func point(longitude: Double, latitude: Double, in size: CGSize) -> CGPoint {
        EquirectangularProjection.point(
            longitude: longitude,
            latitude: latitude,
            in: size,
            latitudeTop: latitudeTop,
            latitudeBottom: latitudeBottom
        )
    }
}

/// The Map tab: an offline, real-world dotted globe with glowing arcs from this
/// machine to every country it is currently talking to. Node size grows with the
/// connection count; threat destinations pulse red. Selecting a country lists its
/// individual connections. Fully offline — drawn from a bundled Natural Earth
/// dataset, never map tiles.
struct GlobeView: View {
    @Environment(AppModel.self) private var model
    @State private var source: GlobeSource = .live
    @State private var threatsOnly = false
    @State private var hover: GlobeHover?
    @State private var selectedCountry: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            toolbar
            HStack(alignment: .top, spacing: 14) {
                mapCard
                sidePanel
                    .frame(width: 272)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Map")
        .background(.background)
        .onChange(of: source) { _, _ in selectedCountry = nil }
    }

    // MARK: Data

    private var destinations: [GlobeDestination] {
        guard let world = WorldMapStore.shared else { return [] }
        let rows: [CountryRow] = switch source {
        case .live:
            model.destinationCountries.map {
                CountryRow(
                    country: $0.country,
                    connections: $0.connections,
                    threat: model.threatCountries.contains($0.country)
                )
            }
        case .history:
            historyRows()
        }
        return rows.compactMap { row in
            guard let coordinate = world.centroid(for: row.country) else { return nil }
            if threatsOnly, !row.threat { return nil }
            return GlobeDestination(
                country: row.country,
                name: Locale.current.localizedString(forRegionCode: row.country) ?? row.country,
                coordinate: coordinate,
                connections: row.connections,
                isThreat: row.threat
            )
        }
    }

    private func historyRows() -> [CountryRow] {
        var counts: [String: Int] = [:]
        var threats: Set<String> = []
        for record in model.recentHistory(limit: 500) {
            guard let ip = IPAddress(record.remoteHost), ip.scope == .global,
                  let code = GeoIP.country(for: ip) else { continue }
            counts[code, default: 0] += 1
            if Threat.isThreat(ip) { threats.insert(code) }
        }
        return counts
            .map { CountryRow(country: $0.key, connections: $0.value, threat: threats.contains($0.key)) }
            .sorted { $0.connections > $1.connections }
    }

    private var locatedConnections: Int {
        destinations.reduce(0) { $0 + $1.connections }
    }

    /// The individual connections (live) or history records reaching a country.
    private func connections(for country: String) -> [CountryConnectionRow] {
        switch source {
        case .live:
            model.connections
                .filter { $0.state == .active && GeoIP.country(for: $0.fiveTuple.destination.address) == country }
                .map { connection in
                    let address = connection.fiveTuple.destination.address
                    let host = connection.remoteHostname ?? address.description
                    return CountryConnectionRow(
                        id: connection.id.uuidString,
                        app: connection.app,
                        appName: connection.app.displayName,
                        endpoint: "\(host):\(connection.fiveTuple.destination.port)",
                        proto: connection.fiveTuple.proto.displayName,
                        role: connection.fiveTuple.role,
                        isThreat: Threat.isThreat(address)
                    )
                }
                .sorted { $0.appName.localizedCompare($1.appName) == .orderedAscending }
        case .history:
            model.recentHistory(limit: 500)
                .filter { record in
                    guard let ip = IPAddress(record.remoteHost), ip.scope == .global else { return false }
                    return GeoIP.country(for: ip) == country
                }
                .map { record in
                    CountryConnectionRow(
                        id: record.appName + "\u{1F}" + record.remoteHost + "\u{1F}" + record.proto,
                        app: nil,
                        appName: record.appName,
                        endpoint: record.remoteHost,
                        proto: record.proto,
                        role: nil,
                        isThreat: IPAddress(record.remoteHost).map(Threat.isThreat) ?? false
                    )
                }
                .sorted { $0.appName.localizedCompare($1.appName) == .orderedAscending }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $source) {
                Text("Live").tag(GlobeSource.live)
                Text("History").tag(GlobeSource.history)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Toggle(isOn: $threatsOnly) {
                Label("Threats only", systemImage: "exclamationmark.triangle")
            }
            .toggleStyle(.button)
            .tint(Theme.danger)

            Spacer()

            if source == .live {
                Text(verbatim: "↓ \(Format.rate(model.throughputIn))   ↑ \(Format.rate(model.throughputOut))")
                    .font(Theme.mono(11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            chip("\(destinations.count)", "countries", Theme.accent)
            chip("\(locatedConnections)", source == .live ? "connections" : "records", Theme.inbound)
            chip("\(destinations.filter(\.isThreat).count)", "threats", Theme.danger)
        }
    }

    private func chip(_ value: String, _ label: LocalizedStringKey, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Text(verbatim: value).font(Theme.mono(12, weight: .medium)).foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.background.secondary, in: Capsule())
    }

    // MARK: Side panel (country list ⇆ country detail)

    @ViewBuilder private var sidePanel: some View {
        if let selectedCountry {
            CountryDetailPanel(
                country: selectedCountry,
                isHistory: source == .history,
                rows: connections(for: selectedCountry),
                onBack: { self.selectedCountry = nil }
            )
        } else {
            GlobeDestinationsList(
                destinations: destinations,
                isHistory: source == .history,
                onSelect: { selectedCountry = $0.country }
            )
        }
    }

    // MARK: Map

    private var mapCard: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                GlobeBaseLayer()
                GlobeArcsLayer(destinations: destinations, home: WorldMapStore.homeCoordinate)
                GlobeLegend()
                if let hover {
                    GlobeTooltip(destination: hover.destination, isHistory: source == .history)
                        .position(x: hover.point.x, y: max(34, hover.point.y - 30))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    hover = nearest(to: location, in: size)
                case .ended:
                    hover = nil
                }
            }
            .gesture(
                SpatialTapGesture().onEnded { value in
                    if let hit = nearest(to: value.location, in: size) {
                        selectedCountry = hit.destination.country
                    }
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RadialGradient(
                colors: [Color(red: 0.09, green: 0.14, blue: 0.24), Color(red: 0.04, green: 0.07, blue: 0.12)],
                center: .center,
                startRadius: 10,
                endRadius: 900
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(red: 0.11, green: 0.18, blue: 0.30))
        )
    }

    private func nearest(to location: CGPoint, in size: CGSize) -> GlobeHover? {
        var best: GlobeHover?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for destination in destinations {
            let point = MapProjection.point(destination.coordinate, in: size)
            let distance = hypot(point.x - location.x, point.y - location.y)
            if distance < 24, distance < bestDistance {
                bestDistance = distance
                best = GlobeHover(point: point, destination: destination)
            }
        }
        return best
    }
}

enum GlobeSource: Hashable { case live, history }

private struct CountryRow {
    let country: String
    let connections: Int
    let threat: Bool
}

struct GlobeDestination: Identifiable {
    let country: String
    let name: String
    let coordinate: MapCoordinate
    let connections: Int
    let isThreat: Bool

    var id: String {
        country
    }
}

private struct GlobeHover {
    let point: CGPoint
    let destination: GlobeDestination
}

struct CountryConnectionRow: Identifiable {
    let id: String
    let app: AppIdentity?
    let appName: String
    let endpoint: String
    let proto: String
    let role: ConnectionRole?
    let isThreat: Bool
}

// MARK: - Static dotted base

private struct GlobeBaseLayer: View {
    var body: some View {
        Canvas { context, size in
            drawGraticule(&context, size: size)
            guard let world = WorldMapStore.shared else { return }
            let color = GraphicsContext.Shading.color(Color(red: 0.22, green: 0.52, blue: 0.48))
            let radius: CGFloat = 1.15
            for cell in world.landCells {
                let lon = -180 + (Double(cell.col) + 0.5) * 360 / Double(world.gridWidth)
                let lat = 90 - (Double(cell.row) + 0.5) * 180 / Double(world.gridHeight)
                guard lat <= MapProjection.latitudeTop + 2, lat >= MapProjection.latitudeBottom - 2 else { continue }
                let point = MapProjection.point(longitude: lon, latitude: lat, in: size)
                let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: color)
            }
        }
    }

    private func drawGraticule(_ context: inout GraphicsContext, size: CGSize) {
        let line = GraphicsContext.Shading.color(Color.white.opacity(0.045))
        for lat in stride(from: -40.0, through: 60.0, by: 20.0) {
            let y = MapProjection.point(longitude: 0, latitude: lat, in: size).y
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: line, lineWidth: 0.5)
        }
        for lon in stride(from: -150.0, through: 150.0, by: 30.0) {
            let x = MapProjection.point(longitude: lon, latitude: 0, in: size).x
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: line, lineWidth: 0.5)
        }
    }
}

// MARK: - Animated arcs / nodes

private struct GlobeArcsLayer: View {
    let destinations: [GlobeDestination]
    let home: MapCoordinate?
    @Environment(\.scenePhase) private var scenePhase

    private let accent = Color(red: 0.32, green: 0.82, blue: 0.58)
    private let threat = Color(red: 0.94, green: 0.46, blue: 0.42)

    var body: some View {
        // Only burn 30 fps while the app is frontmost and there are arcs to
        // animate; pause entirely when backgrounded, and idle-breathe when the map
        // is empty. SwiftUI already stops a TimelineView whose window is occluded,
        // but not one that's merely not-key, so gate on scenePhase too.
        let schedule = GlobeAnimation.schedule(active: scenePhase == .active, destinationCount: destinations.count)
        TimelineView(.animation(minimumInterval: schedule.interval, paused: schedule.paused)) { timeline in
            Canvas { context, size in
                draw(&context, size: size, phase: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, phase: Double) {
        guard let home else { return }
        let homePoint = MapProjection.point(home, in: size)

        for (index, destination) in destinations.enumerated() {
            let destinationPoint = MapProjection.point(destination.coordinate, in: size)
            let points = GlobeGeometry.arcPoints(from: homePoint, to: destinationPoint, samples: 48)
            var path = Path()
            path.addLines(points)
            let color = destination.isThreat ? threat : accent

            context.stroke(path, with: .color(color.opacity(0.16)), lineWidth: 4)
            context.stroke(path, with: .color(color.opacity(0.85)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))

            let progress = (phase * 0.5 + Double(index) * 0.17).truncatingRemainder(dividingBy: 1)
            let cometIndex = min(points.count - 1, max(0, Int(progress * Double(points.count - 1))))
            let comet = points[cometIndex]
            let cometColor = destination.isThreat
                ? Color(red: 1, green: 0.82, blue: 0.80)
                : Color(red: 0.68, green: 0.96, blue: 0.84)
            context.fill(
                Path(ellipseIn: CGRect(x: comet.x - 2.4, y: comet.y - 2.4, width: 4.8, height: 4.8)),
                with: .color(cometColor)
            )

            let radius = min(11, 4 + CGFloat(Double(destination.connections).squareRoot()) * 1.4)
            let rect = CGRect(
                x: destinationPoint.x - radius,
                y: destinationPoint.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.fill(Path(ellipseIn: rect), with: .color(color))
            if destination.isThreat {
                pulse(&context, at: destinationPoint, phase: phase, color: threat)
            }
        }

        context.fill(
            Path(ellipseIn: CGRect(x: homePoint.x - 4, y: homePoint.y - 4, width: 8, height: 8)),
            with: .color(.white)
        )
        pulse(&context, at: homePoint, phase: phase, color: accent)
    }

    private func pulse(_ context: inout GraphicsContext, at point: CGPoint, phase: Double, color: Color) {
        let cycle = (phase.truncatingRemainder(dividingBy: 2.4)) / 2.4
        let radius = 5 + CGFloat(cycle) * 16
        let opacity = 0.6 * (1 - cycle)
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        context.stroke(Path(ellipseIn: rect), with: .color(color.opacity(opacity)), lineWidth: 1.5)
    }
}
