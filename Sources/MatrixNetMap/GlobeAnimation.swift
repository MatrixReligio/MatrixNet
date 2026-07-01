/// Decides how fast the Map's animated arcs/comets layer should redraw, so a
/// 30 fps `Canvas` isn't burned when nobody is watching or nothing is moving.
public enum GlobeAnimation {
    /// The cadence for the arcs/comets `TimelineView`.
    ///
    /// - Parameters:
    ///   - active: whether the app is frontmost. When it isn't, there is nobody
    ///     watching the map, so the timeline is paused (zero redraws).
    ///   - destinationCount: how many arcs are currently drawn. Comets and node
    ///     pulses only move when there is at least one destination; with none, the
    ///     only motion is the home-node breath, which does not need 30 fps.
    /// - Returns: the frame `interval` in seconds and whether the timeline should
    ///   be `paused`.
    public static func schedule(active: Bool, destinationCount: Int) -> (interval: Double, paused: Bool) {
        guard active else { return (interval: 1, paused: true) }
        let interval = destinationCount > 0 ? 1.0 / 30.0 : 1.0 / 6.0
        return (interval: interval, paused: false)
    }
}
