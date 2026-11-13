import Darwin
import Foundation
import MurmurCore

/// How long this process has been running, from the kernel's record of when it started. The
/// timings log keeps it for a dictation the keyboard opened the app for: a few hundred
/// milliseconds means the link launched Murmur, which is the slow way in.
enum ProcessAge {
    static var milliseconds: Int? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let started = info.kp_proc.p_starttime
        let startedAt = Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
        let age = Date().milliseconds(since: startedAt)
        return age >= 0 ? age : nil
    }
}
