// Logs NStat source lifecycle (added/described/removed) with TCP state, to
// understand when `removed` fires for established vs short-lived connections.
// Run (non-root): swift Tools/nstat-spike/lifecycle.swift
import Darwin
import Foundation

let path = "/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics"
let handle = dlopen(path, RTLD_NOW)!
func sym(_ n: String) -> UnsafeMutableRawPointer {
    dlsym(handle, n)!
}

typealias AddedBlock = @convention(block) (OpaquePointer?) -> Void
typealias DictBlock = @convention(block) (CFDictionary?) -> Void
typealias VoidBlock = @convention(block) () -> Void
typealias FnCreate = @convention(c) (CFAllocator?, OpaquePointer?, @escaping AddedBlock) -> OpaquePointer?
typealias FnAddAll = @convention(c) (OpaquePointer?) -> Int32
typealias FnSetDict = @convention(c) (OpaquePointer?, @escaping DictBlock) -> Void
typealias FnSetVoid = @convention(c) (OpaquePointer?, @escaping VoidBlock) -> Void

typealias FnQuery = @convention(c) (OpaquePointer?, @escaping VoidBlock) -> Void
typealias FnSetFlags = @convention(c) (OpaquePointer?, UInt32) -> Int32
let create = unsafeBitCast(sym("NStatManagerCreate"), to: FnCreate.self)
let addAllTCP = unsafeBitCast(sym("NStatManagerAddAllTCP"), to: FnAddAll.self)
let setDesc = unsafeBitCast(sym("NStatSourceSetDescriptionBlock"), to: FnSetDict.self)
let setRemoved = unsafeBitCast(sym("NStatSourceSetRemovedBlock"), to: FnSetVoid.self)
let queryAll = unsafeBitCast(sym("NStatManagerQueryAllSourcesDescriptions"), to: FnQuery.self)
let setFlags = unsafeBitCast(sym("NStatManagerSetFlags"), to: FnSetFlags.self)

let queue = DispatchQueue(label: "spike")
let queuePtr = OpaquePointer(Unmanaged.passUnretained(queue).toOpaque())
let lock = NSLock()
var labelByKey = [UInt: String]()

let added: AddedBlock = { source in
    guard let source else { return }
    let key = UInt(bitPattern: Int(bitPattern: source))
    setDesc(source) { dict in
        guard let d = dict as NSDictionary? else { return }
        let pname = d["processName"] as? String ?? "?"
        let state = d["TCPState"] as? String ?? "-"
        let provider = d["provider"] as? String ?? "?"
        lock.lock()
        let known = labelByKey[key] != nil
        labelByKey[key] = "\(pname)/\(provider)"
        lock.unlock()
        print("\(known ? "DESC " : "ADDED")  \(pname)/\(provider)  state=\(state)")
    }
    setRemoved(source) {
        lock.lock()
        let label = labelByKey[key] ?? "?"
        lock.unlock()
        print("REMOVED  \(label)")
    }
}

let manager = create(kCFAllocatorDefault, queuePtr, added)!
_ = setFlags(manager, 0x1000) // try a flags value
_ = addAllTCP(manager)
print("watching 5s with periodic QueryAllSourcesDescriptions (uid=\(getuid()))...")
for _ in 0 ..< 4 {
    Thread.sleep(forTimeInterval: 1.0)
    queue.async { queryAll(manager) {} }
}

print("done")
