import Foundation
import MatrixNetXPC

// Privileged helper entry point. Vends the capture XPC service on its Mach
// service and runs until the launchd daemon is stopped.
let delegate = HelperService()
let listener = NSXPCListener(machServiceName: CaptureXPC.machServiceName)
listener.delegate = delegate
listener.resume()
dispatchMain()
