// Quits and reopens the running Mac app so macOS applies a newly granted Screen Recording or Input Monitoring switch.
// MacComputerHost calls it from the computer-access setup steps; a detached shell reopens the bundle once this
// process has exited.

#if os(macOS)
    import AppKit
    import Foundation

    enum MacAppRelauncher {
        static let waiter =
            "i=0; while /bin/kill -0 \"$1\" 2>/dev/null; do i=$((i + 1)); [ \"$i\" -gt 600 ] && exit 1; "
            + "/bin/sleep 0.1; done; exec \"$2\" \"$3\""

        @MainActor static func relaunch(
            pid: pid_t = ProcessInfo.processInfo.processIdentifier, bundle: URL = Bundle.main.bundleURL,
            opener: String = "/usr/bin/open", shell: String = "/bin/sh",
            terminate: @MainActor () -> Void = { NSApp.terminate(nil) }
        ) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-c", waiter, "astral-relaunch", String(pid), opener, bundle.path]
            do {
                try process.run()
            } catch {
                return false
            }
            terminate()
            return true
        }
    }
#endif
