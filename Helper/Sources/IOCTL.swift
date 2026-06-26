import Darwin

/// BPF `ioctl` request codes. The `_IOC`/`_IOW`/`_IOR` macros from
/// `<sys/ioccom.h>` are unavailable in Swift, so the codes are computed from
/// their definitions: `io | ((len & IOCPARM_MASK) << 16) | (group << 8) | number`.
enum IOCTL {
    private static let iocOut: UInt = 0x4000_0000 // IOC_OUT  (_IOR)
    private static let iocIn: UInt = 0x8000_0000 // IOC_IN   (_IOW)
    private static let parmMask: UInt = 0x1FFF // IOCPARM_MASK
    private static let groupB: UInt = 0x42 // 'B'

    private static func code(_ direction: UInt, _ number: UInt, _ length: Int) -> UInt {
        direction | ((UInt(length) & parmMask) << 16) | (groupB << 8) | number
    }

    /// `BIOCGBLEN` — get the BPF buffer length. `_IOR('B', 102, u_int)`.
    static let bIOCGBLEN = code(iocOut, 102, MemoryLayout<UInt32>.size)
    /// `BIOCSETIF` — bind to an interface. `_IOW('B', 108, struct ifreq)`.
    static let bIOCSETIF = code(iocIn, 108, MemoryLayout<ifreq>.size)
    /// `BIOCIMMEDIATE` — deliver packets immediately. `_IOW('B', 112, u_int)`.
    static let bIOCIMMEDIATE = code(iocIn, 112, MemoryLayout<UInt32>.size)
    /// `BIOCSDLT` — set the data link type. `_IOW('B', 120, u_int)`.
    static let bIOCSDLT = code(iocIn, 120, MemoryLayout<UInt32>.size)
}
