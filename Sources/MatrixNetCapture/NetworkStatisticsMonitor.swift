import Darwin
import Foundation
import MatrixNetModel

/// Passive, zero-conflict connection monitor backed by the private
/// `NetworkStatistics` framework (the same mechanism `nettop` and Activity
/// Monitor use). Verified on macOS 26 to deliver per-connection PID, 5-tuple and
/// byte/packet counters as a non-root, non-sandboxed process — see
/// `docs/superpowers/notes/capture-spike.md`.
///
/// The framework is loaded via `dlopen`; `init?` fails (graceful degradation) if
/// the framework or required symbols are unavailable, so a future OS change can
/// never crash the app — the connection view simply stays empty.
///
/// All framework callbacks run on a private serial queue; mutable state is only
/// touched there (and via `queue.sync` in `stop()`), so the type is safe to share.
public final class NetworkStatisticsMonitor: ConnectionMonitoring, @unchecked Sendable {
    private typealias AddedBlock = @convention(block) (OpaquePointer?) -> Void
    private typealias DictBlock = @convention(block) (CFDictionary?) -> Void
    private typealias VoidBlock = @convention(block) () -> Void
    // Block parameters are `@escaping`: the framework copies and retains them.
    private typealias FnCreate = @convention(c) (CFAllocator?, OpaquePointer?, @escaping AddedBlock) -> OpaquePointer?
    private typealias FnAddAll = @convention(c) (OpaquePointer?) -> Int32
    private typealias FnSetDict = @convention(c) (OpaquePointer?, @escaping DictBlock) -> Void
    private typealias FnSetVoid = @convention(c) (OpaquePointer?, @escaping VoidBlock) -> Void
    private typealias FnQuery = @convention(c) (OpaquePointer?, @escaping VoidBlock) -> Void
    private typealias FnDestroy = @convention(c) (OpaquePointer?) -> Void

    private let handle: UnsafeMutableRawPointer
    private let create: FnCreate
    private let addAllTCP: FnAddAll
    private let addAllUDP: FnAddAll
    private let setDescription: FnSetDict
    private let setCounts: FnSetDict
    private let setRemoved: FnSetVoid
    private let queryAll: FnQuery
    private let destroy: FnDestroy

    private let queue = DispatchQueue(label: "com.matrixreligio.matrixnet.nstat")
    private var manager: OpaquePointer?
    private var continuation: AsyncStream<ConnectionEvent>.Continuation?
    private var idBySource: [UInt: UUID] = [:]
    private var startedAtBySource: [UInt: Date] = [:]
    private var queryTimer: DispatchSourceTimer?

    /// How often to re-enumerate current sources. NetworkStatistics only pushes
    /// state-change/teardown events on its own; an explicit periodic query is
    /// required to surface (and refresh) established connections.
    private let queryInterval: DispatchTimeInterval = .milliseconds(1500)

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics"

    public init?() {
        guard let handle = dlopen(Self.frameworkPath, RTLD_NOW) else { return nil }
        func bind<T>(_ name: String, _: T.Type) -> T? {
            guard let symbol = dlsym(handle, name) else { return nil }
            return unsafeBitCast(symbol, to: T.self)
        }
        guard let create = bind("NStatManagerCreate", FnCreate.self),
              let addAllTCP = bind("NStatManagerAddAllTCP", FnAddAll.self),
              let addAllUDP = bind("NStatManagerAddAllUDP", FnAddAll.self),
              let setDescription = bind("NStatSourceSetDescriptionBlock", FnSetDict.self),
              let setCounts = bind("NStatSourceSetCountsBlock", FnSetDict.self),
              let setRemoved = bind("NStatSourceSetRemovedBlock", FnSetVoid.self),
              let queryAll = bind("NStatManagerQueryAllSourcesDescriptions", FnQuery.self),
              let destroy = bind("NStatManagerDestroy", FnDestroy.self)
        else {
            dlclose(handle)
            return nil
        }
        self.handle = handle
        self.create = create
        self.addAllTCP = addAllTCP
        self.addAllUDP = addAllUDP
        self.setDescription = setDescription
        self.setCounts = setCounts
        self.setRemoved = setRemoved
        self.queryAll = queryAll
        self.destroy = destroy
    }

    public func start() -> AsyncStream<ConnectionEvent> {
        AsyncStream { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.finish()
                    return
                }
                self.continuation = continuation
                let queuePointer = OpaquePointer(Unmanaged.passUnretained(queue).toOpaque())
                let added: AddedBlock = { [weak self] source in
                    self?.handleAddedSource(source)
                }
                manager = create(kCFAllocatorDefault, queuePointer, added)
                _ = addAllTCP(manager)
                _ = addAllUDP(manager)
                startQueryTimer()
            }
        }
    }

    /// Periodically re-enumerates current sources so established connections
    /// surface and refresh (NStat only pushes teardown events unprompted).
    private func startQueryTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + queryInterval, repeating: queryInterval)
        timer.setEventHandler { [weak self] in
            guard let self, let manager else { return }
            queryAll(manager) {}
        }
        timer.resume()
        queryTimer = timer
        // Prime an immediate enumeration so the first snapshot is populated.
        if let manager {
            queryAll(manager) {}
        }
    }

    public func stop() {
        queue.sync {
            queryTimer?.cancel()
            queryTimer = nil
            if let manager {
                destroy(manager)
            }
            manager = nil
            idBySource.removeAll()
            startedAtBySource.removeAll()
            continuation?.finish()
            continuation = nil
        }
    }

    // MARK: - Callbacks (all on `queue`)

    private func handleAddedSource(_ source: OpaquePointer?) {
        guard let source else { return }
        let key = UInt(bitPattern: Int(bitPattern: source))

        setDescription(source) { [weak self] dict in
            self?.handleDescription(dict, key: key)
        }
        setCounts(source) { [weak self] dict in
            self?.handleCounts(dict, key: key)
        }
        setRemoved(source) { [weak self] in
            self?.handleRemoved(key: key)
        }
    }

    private func handleDescription(_ dict: CFDictionary?, key: UInt) {
        guard let description = dict as? [String: Any] else { return }
        // Re-emit `.added` on every description so the connection's live state
        // (e.g. Established -> Closed) stays current; the id and first-seen time
        // are preserved across refreshes. High-frequency byte updates still
        // arrive via the counts block.
        let id = idBySource[key] ?? UUID()
        let startedAt = startedAtBySource[key] ?? Date()
        guard let connection = NStatDescriptionParser.connection(from: description, id: id, startedAt: startedAt)
        else { return }
        idBySource[key] = id
        startedAtBySource[key] = startedAt
        continuation?.yield(.added(connection))
    }

    private func handleCounts(_ dict: CFDictionary?, key: UInt) {
        guard let id = idBySource[key], let counts = dict as? [String: Any] else { return }
        continuation?.yield(.counts(id: id, NStatDescriptionParser.counts(from: counts, at: Date())))
    }

    private func handleRemoved(key: UInt) {
        startedAtBySource[key] = nil
        guard let id = idBySource.removeValue(forKey: key) else { return }
        continuation?.yield(.removed(id))
    }

    deinit {
        if let manager {
            destroy(manager)
        }
        dlclose(handle)
    }
}
