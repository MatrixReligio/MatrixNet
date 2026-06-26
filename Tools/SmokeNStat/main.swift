// Smoke test for the real MatrixNetCapture vertical slice (non-root):
// NetworkStatisticsMonitor -> ConnectionAggregator -> live connection snapshot.
// Run: swift run matrixnet-smoke
import Foundation
import MatrixNetCapture
import MatrixNetModel

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? String(text.prefix(width)) : text + String(repeating: " ", count: width - text.count)
}

guard let monitor = NetworkStatisticsMonitor() else {
    print("NetworkStatisticsMonitor unavailable (symbols missing?)")
    exit(1)
}

let aggregator = ConnectionAggregator()
let stream = monitor.start()
let pump = Task { await aggregator.consume(stream) }

print("uid=\(getuid()) — collecting live connections via MatrixNetCapture for 3s...\n")
try await Task.sleep(for: .seconds(3))
monitor.stop()
pump.cancel()

let snapshot = await aggregator.snapshot().sorted { $0.totalBytes > $1.totalBytes }
print("captured \(snapshot.count) connections; top 15 by bytes:\n")
print(pad("APP", 26) + pad("PROTO", 6) + pad("REMOTE", 26) + pad("RX", 11) + "TX")
for connection in snapshot.prefix(15) {
    let remote = "\(connection.fiveTuple.destination.address):\(connection.fiveTuple.destination.port)"
    print(
        pad(connection.app.displayName, 26)
            + pad(connection.fiveTuple.proto.displayName, 6)
            + pad(remote, 26)
            + pad("\(connection.bytesIn)", 11)
            + "\(connection.bytesOut)"
    )
}
print(snapshot.isEmpty ? "\nRESULT: no connections ❌" : "\nRESULT: live per-app capture works ✅")
