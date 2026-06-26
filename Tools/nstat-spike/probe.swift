// NStat symbol probe — verifies which NetworkStatistics private symbols exist
// on this macOS, so the real binding is written against facts, not guesses.
// Run (non-root): swift Tools/nstat-spike/probe.swift
import Darwin

let path = "/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics"
guard let handle = dlopen(path, RTLD_NOW) else {
    print("dlopen FAILED: \(String(cString: dlerror()))")
    exit(1)
}
print("dlopen OK: \(path)\n")

let candidates = [
    "NStatManagerCreate",
    "NStatManagerDestroy",
    "NStatManagerAddAllTCP",
    "NStatManagerAddAllUDP",
    "NStatManagerAddAllTCPWithFilter",
    "NStatManagerAddAllUDPWithFilter",
    "NStatManagerSetFlags",
    "NStatManagerSetInterfaceTrafficDescriptionBlock",
    "NStatSourceSetDescriptionBlock",
    "NStatSourceSetCountsBlock",
    "NStatSourceSetRemovedBlock",
    "NStatSourceSetEventsBlock",
    "NStatManagerQueryAllSourcesDescriptions",
    "NStatSourceQueryDescription",
    "NStatManagerSetProviderStateChangeBlock",
    "NStatManagerSetInterfaceQueryBlock",
]

var found = [String]()
var missing = [String]()
for name in candidates {
    if dlsym(handle, name) != nil { found.append(name) } else { missing.append(name) }
}
print("FOUND (\(found.count)):")
found.forEach { print("  \($0)") }
print("\nMISSING (\(missing.count)):")
missing.forEach { print("  \($0)") }
