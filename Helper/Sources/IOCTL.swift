import Darwin

/// BPF and interface-clone `ioctl` request codes. The `_IOC`/`_IOW`/`_IOR`
/// macros from `<sys/ioccom.h>` are unavailable in Swift, so the codes are
/// computed from their definitions:
/// `io | ((len & IOCPARM_MASK) << 16) | (group << 8) | number`.
enum IOCTL {
    private static let iocOut: UInt = 0x4000_0000 // IOC_OUT   (_IOR)
    private static let iocIn: UInt = 0x8000_0000 // IOC_IN    (_IOW)
    private static let iocInOut: UInt = 0xC000_0000 // IOC_INOUT (_IOWR)
    private static let parmMask: UInt = 0x1FFF // IOCPARM_MASK
    private static let groupB: UInt = 0x42 // 'B' (BPF)
    private static let groupI: UInt = 0x69 // 'i' (interface ioctls)

    private static func code(_ direction: UInt, _ group: UInt, _ number: UInt, _ length: Int) -> UInt {
        direction | ((UInt(length) & parmMask) << 16) | (group << 8) | number
    }

    /// `BIOCGBLEN` — get the BPF buffer length. `_IOR('B', 102, u_int)`.
    static let bIOCGBLEN = code(iocOut, groupB, 102, MemoryLayout<UInt32>.size)
    /// `BIOCSBLEN` — set the BPF buffer length (before binding an interface).
    /// `_IOWR('B', 102, u_int)`.
    static let bIOCSBLEN = code(iocInOut, groupB, 102, MemoryLayout<UInt32>.size)
    /// `BIOCGDLT` — get the data link type. `_IOR('B', 106, u_int)`.
    static let bIOCGDLT = code(iocOut, groupB, 106, MemoryLayout<UInt32>.size)
    /// `BIOCSETIF` — bind to an interface. `_IOW('B', 108, struct ifreq)`.
    static let bIOCSETIF = code(iocIn, groupB, 108, MemoryLayout<ifreq>.size)
    /// `BIOCIMMEDIATE` — deliver packets immediately. `_IOW('B', 112, u_int)`.
    static let bIOCIMMEDIATE = code(iocIn, groupB, 112, MemoryLayout<UInt32>.size)
    /// `BIOCSDLT` — set the data link type. `_IOW('B', 120, u_int)`.
    static let bIOCSDLT = code(iocIn, groupB, 120, MemoryLayout<UInt32>.size)
    /// `BIOCSWANTPKTAP` — request per-packet pktap headers (process attribution).
    /// Private ioctl from `xnu bsd/net/bpf_private.h`: `_IOWR('B', 127, u_int)`.
    /// Without this, a BPF bound to a pktap interface delivers plain DLT_RAW with
    /// no process information; with it, the link type becomes DLT_PKTAP.
    static let bIOCSWantPKTAP = code(iocInOut, groupB, 127, MemoryLayout<UInt32>.size)

    /// `SIOCIFCREATE` — create a clone interface (e.g. `pktap`). The kernel fills
    /// in the chosen unit name. `_IOWR('i', 120, struct ifreq)`.
    static let siocIFCreate = code(iocInOut, groupI, 120, MemoryLayout<ifreq>.size)
    /// `SIOCIFDESTROY` — destroy a clone interface. `_IOW('i', 121, struct ifreq)`.
    static let siocIFDestroy = code(iocIn, groupI, 121, MemoryLayout<ifreq>.size)
}
