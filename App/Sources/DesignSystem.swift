import SwiftUI

/// MatrixNet's design system: an instrument-grade, calm aesthetic that nods to
/// the classic network-monitor terminal with a refined phosphor-green accent on
/// warm-tinted neutral surfaces — never neon-on-black. Technical readouts use a
/// monospaced face for true tabular alignment.
enum Theme {
    /// Refined phosphor green — the brand accent, used sparingly for emphasis,
    /// live state, and selection. Adapts subtly across light/dark.
    static let accent = Color(
        light: Color(red: 0.06, green: 0.46, blue: 0.34),
        dark: Color(red: 0.32, green: 0.82, blue: 0.58)
    )

    /// Inbound traffic hue (cool) and outbound (warm), kept muted.
    static let inbound = Color(
        light: Color(red: 0.18, green: 0.42, blue: 0.60),
        dark: Color(red: 0.46, green: 0.70, blue: 0.92)
    )
    static let outbound = Color(
        light: Color(red: 0.72, green: 0.45, blue: 0.14),
        dark: Color(red: 0.94, green: 0.72, blue: 0.38)
    )

    /// Amber used for advisory/closed states.
    static let advisory = Color(
        light: Color(red: 0.70, green: 0.45, blue: 0.10),
        dark: Color(red: 0.92, green: 0.74, blue: 0.40)
    )

    /// Monospaced face for IPs, ports, and byte counts (tabular numerals).
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    /// Builds a color that resolves differently in light and dark appearance.
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
    }
}

/// Human-readable byte and rate formatting. Implemented as pure functions (no
/// shared formatter state) so they are trivially `Sendable` under Swift 6.
enum Format {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    static func bytes(_ value: UInt64) -> String {
        var scaled = Double(value)
        var unit = 0
        while scaled >= 1024, unit < units.count - 1 {
            scaled /= 1024
            unit += 1
        }
        return unit == 0 ? "\(value) B" : String(format: "%.1f %@", scaled, units[unit])
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond >= 1 else { return "—" }
        return "\(bytes(UInt64(bytesPerSecond)))/s"
    }

    nonisolated(unsafe) private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// Wall-clock time down to the microsecond (`HH:mm:ss.uuuuuu`), so packets
    /// captured within the same second are still distinguishable.
    static func preciseTime(_ date: Date) -> String {
        let interval = date.timeIntervalSince1970
        let whole = interval.rounded(.down)
        let micros = min(999_999, Int(((interval - whole) * 1_000_000).rounded()))
        return "\(clock.string(from: date)).\(String(format: "%06d", micros))"
    }
}
