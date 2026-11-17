// Watches the processes of one confined call on macOS through libproc and KERN_PROCARGS2, and ends every one of them at the end of the call.
// ExecLauncher samples it between waits for the memory and process limits and calls end() on every exit path.

import Foundation

#if os(macOS)
    struct ExecProcessUsage: Equatable {
        let start: UInt64
        let exited: Bool
        let footprint: UInt64
    }

    protocol ExecProcessTable {
        func pids(kind: UInt32, info: UInt32) throws -> [Int32]
        func usage(_ pid: Int32) -> ExecProcessUsage?
        func strings(_ pid: Int32) -> [[UInt8]]?
    }

    struct DarwinProcessTable: ExecProcessTable {
        static let pgrpOnly: UInt32 = 2
        static let uidOnly: UInt32 = 4
        static let ppidOnly: UInt32 = 6

        func pids(kind: UInt32, info: UInt32) throws -> [Int32] {
            var capacity = max(Int(proc_listpids(kind, info, nil, 0)), 0) / MemoryLayout<Int32>.size + 256
            while true {
                var buffer = [Int32](repeating: 0, count: capacity)
                let bytes = proc_listpids(kind, info, &buffer, Int32(capacity * MemoryLayout<Int32>.size))
                if bytes < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                let filled = Int(bytes) / MemoryLayout<Int32>.size
                if filled < capacity { return buffer[0..<filled].filter { $0 > 0 } }
                capacity *= 2
            }
        }

        func usage(_ pid: Int32) -> ExecProcessUsage? {
            var info = rusage_info_v0()
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V0, $0) }
            }
            if status != 0 { return nil }
            return ExecProcessUsage(
                start: info.ri_proc_start_abstime, exited: info.ri_proc_exit_abstime != 0, footprint: info.ri_phys_footprint)
        }

        func strings(_ pid: Int32) -> [[UInt8]]? {
            var argmax: Int32 = 0
            var size = MemoryLayout<Int32>.size
            var name: [Int32] = [CTL_KERN, KERN_ARGMAX]
            guard sysctl(&name, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: Int(argmax))
            var length = buffer.count
            var request: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            guard sysctl(&request, 3, &buffer, &length, nil, 0) == 0, length > 4 else { return nil }
            return buffer[4..<length].split(separator: 0, omittingEmptySubsequences: true).map(Array.init)
        }
    }

    final class ExecWatch {
        static let sweepRounds = 64
        static let sweepPause: useconds_t = 5000

        private let table: ExecProcessTable
        private let root: Int32
        private let marker: [UInt8]?
        private let own = getpid()
        private let uid = geteuid()
        private let rootStart: UInt64?
        private var known: [Int32: UInt64] = [:]
        private var scanned = Set<Int32>()
        var started: Bool { rootStart != nil }

        init(root: Int32, marker: String?, table: ExecProcessTable = DarwinProcessTable()) {
            self.table = table
            self.root = root
            self.marker = marker.map { Array($0.utf8) }
            let first = table.usage(root)
            rootStart = first?.start
            if let first { known[root] = first.start }
        }

        static func userProcessCount(_ table: ExecProcessTable = DarwinProcessTable()) throws -> Int {
            try table.pids(kind: DarwinProcessTable.uidOnly, info: UInt32(geteuid())).count
        }

        private var groupIsOurs: Bool {
            guard let current = table.usage(root) else { return true }
            return current.start == rootStart
        }

        private func marked(every: Bool) throws -> [Int32] {
            let listed = try table.pids(kind: DarwinProcessTable.uidOnly, info: UInt32(uid))
            scanned.formIntersection(listed)
            var found = [Int32]()
            guard let marker else { return found }
            for pid in listed where pid != own && (every || !scanned.contains(pid)) {
                scanned.insert(pid)
                if table.strings(pid)?.contains(marker) == true { found.append(pid) }
            }
            return found
        }

        private func discover(every: Bool) throws -> [Int32: ExecProcessUsage] {
            var fresh = groupIsOurs ? try table.pids(kind: DarwinProcessTable.pgrpOnly, info: UInt32(root)) : []
            if marker != nil { fresh += try marked(every: every) }
            var pending = known.keys.map { ($0, false) } + fresh.map { ($0, true) }
            var found = [Int32: ExecProcessUsage]()
            while let (pid, isFresh) = pending.popLast() {
                if found[pid] != nil || pid == own { continue }
                guard let usage = table.usage(pid), isFresh || known[pid] == usage.start else { continue }
                found[pid] = usage
                pending += try table.pids(kind: DarwinProcessTable.ppidOnly, info: UInt32(pid)).map { ($0, true) }
            }
            known = found.mapValues(\.start)
            return found
        }

        func sample() throws -> (processes: Int, memory: UInt64) {
            let found = try discover(every: false)
            return (found.count, found.values.filter { !$0.exited }.reduce(0) { $0 + $1.footprint })
        }

        private func signalGroup() {
            if groupIsOurs { killpg(root, SIGKILL) }
        }

        private func live() throws -> Set<Int32> {
            signalGroup()
            return Set(try discover(every: true).filter { !$0.value.exited }.keys)
        }

        func end() throws -> Set<Int32> {
            var survivors = try live()
            for _ in 0..<Self.sweepRounds where !survivors.isEmpty {
                for pid in survivors { kill(pid, SIGKILL) }
                usleep(Self.sweepPause)
                survivors = try live()
            }
            return survivors
        }
    }
#endif
