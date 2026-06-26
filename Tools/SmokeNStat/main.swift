// Smoke test for the real MatrixNetCapture vertical slice (non-root):
// NetworkStatisticsMonitor -> ConnectionAggregator -> live connection snapshot.
// Run: swift run matrixnet-smoke
import Foundation
import MatrixNetCapture
import MatrixNetModel

actor Counter {
    var added = 0
    var removed = 0
    var counts = 0
    func record(_ event: ConnectionEvent) {
        switch event {
        case .added: added += 1
        case .removed: removed += 1
        case .counts: counts += 1
        }
    }
}

guard let monitor = NetworkStatisticsMonitor() else {
    print("NetworkStatisticsMonitor unavailable (symbols missing?)")
    exit(1)
}

let aggregator = ConnectionAggregator()
let counter = Counter()
let stream = monitor.start()
let pump = Task {
    for await event in stream {
        await counter.record(event)
        await aggregator.apply(event)
    }
}

print("uid=\(getuid()) — collecting live connections via MatrixNetCapture for 3s...\n")
try await Task.sleep(for: .seconds(3))

let snapshot = await aggregator.snapshot().sorted { $0.totalBytes > $1.totalBytes }
await print("events: added=\(counter.added) counts=\(counter.counts) removed=\(counter.removed)")
print("snapshot: \(snapshot.count) live connections\n")
for connection in snapshot.prefix(15) {
    let remote = "\(connection.fiveTuple.destination.address):\(connection.fiveTuple.destination.port)"
    let state = connection.state == .active ? "active" : "closed"
    print("  \(connection.app.displayName)  \(remote)  \(state)  in=\(connection.bytesIn) out=\(connection.bytesOut)")
}

monitor.stop()
pump.cancel()
