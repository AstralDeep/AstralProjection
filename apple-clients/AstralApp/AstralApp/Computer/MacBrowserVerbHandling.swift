// Declares the seam through which the Mac computer host hands browser pane verbs to the embedded browser.
// MacComputerHost routes every browser_* request here on its non-physical executor; authorize rechecks the admission ticket.

#if os(macOS)
    import AstralCore
    import Foundation

    @MainActor protocol MacBrowserVerbHandling: AnyObject {
        var isEnabled: Bool { get }
        func handle(
            _ request: ComputerHostRequest, ticket: ComputerHostTicket,
            authorize: @escaping @Sendable () throws -> Void
        ) async throws -> [String: JSONValue]
    }
#endif
