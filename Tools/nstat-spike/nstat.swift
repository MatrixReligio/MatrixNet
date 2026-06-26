// NStat live spike — verifies the architecture A′ foundation:
// can a NON-root, non-sandboxed process obtain per-connection PID + 5-tuple +
// byte counts via NetworkStatistics? Dumps the raw description dictionary keys
// so the real binding is written against observed facts, not guesses.
//
// Run (non-root): swift Tools/nstat-spike/nstat.swift
import Darwin
import Foundation

let path = "/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics"
guard let handle = dlopen(path, RTLD_NOW) else {
    print("dlopen FAILED"); exit(1)
}

func sym(_ name: String) -> UnsafeMutableRawPointer {
    guard let pointer = dlsym(handle, name) else {
        print("missing symbol \(name)"); exit(1)
    }
    return pointer
}

typealias AddedBlock = @convention(block) (OpaquePointer?) -> Void
typealias DictBlock = @convention(block) (CFDictionary?) -> Void

typealias FnCreate = @convention(c) (CFAllocator?, OpaquePointer?, AddedBlock) -> OpaquePointer?
typealias FnAddAll = @convention(c) (OpaquePointer?) -> Int32
typealias FnSetDesc = @convention(c) (OpaquePointer?, DictBlock) -> Void

let create = unsafeBitCast(sym("NStatManagerCreate"), to: FnCreate.self)
let addAllTCP = unsafeBitCast(sym("NStatManagerAddAllTCP"), to: FnAddAll.self)
let addAllUDP = unsafeBitCast(sym("NStatManagerAddAllUDP"), to: FnAddAll.self)
let setDesc = unsafeBitCast(sym("NStatSourceSetDescriptionBlock"), to: FnSetDesc.self)

let queue = DispatchQueue(label: "nstat.spike")
let queuePointer = OpaquePointer(Unmanaged.passUnretained(queue).toOpaque())

var dumped = 0
let lock = NSLock()

let added: AddedBlock = { source in
    let describe: DictBlock = { dict in
        guard let dict = dict as NSDictionary? else { return }
        lock.lock(); defer { lock.unlock() }
        if dumped >= 6 { return }
        dumped += 1
        print("\n--- source #\(dumped) description keys ---")
        for (key, value) in dict {
            let keyString = "\(key)"
            // Print sockaddr-bearing CFData specially so we can see addresses.
            if let data = value as? Data {
                print("  \(keyString): <\(data.count) bytes> \(data.map { String(format: "%02x", $0) }.joined())")
            } else {
                print("  \(keyString): \(value)")
            }
        }
    }
    setDesc(source, describe)
}

guard let manager = create(kCFAllocatorDefault, queuePointer, added) else {
    print("NStatManagerCreate returned nil"); exit(1)
}
_ = addAllTCP(manager)
_ = addAllUDP(manager)

print("uid=\(getuid()) — collecting NStat sources for 3s (non-root test)...")
Thread.sleep(forTimeInterval: 3.0)
lock.lock()
let total = dumped
lock.unlock()
print("\n=== dumped \(total) source descriptions; uid=\(getuid()) ===")
print(total > 0 ? "RESULT: NStat delivers per-connection data as non-root ✅" : "RESULT: no sources seen ❌")
