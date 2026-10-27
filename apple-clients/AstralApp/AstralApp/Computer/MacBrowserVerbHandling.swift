// Declares the seam through which the Mac computer host hands browser pane verbs to the embedded browser.
// MacComputerHost routes every browser_* request here off the physical queue; authorize rechecks the admission ticket.
// The host calls discardPermits when a person pauses or takes over; an approval decision keeps the review it answers.

#if os(macOS)
    import AstralCore
    import Foundation

    @MainActor protocol MacBrowserVerbHandling: AnyObject {
        var isEnabled: Bool { get }
        func handle(
            _ request: ComputerHostRequest, ticket: ComputerHostTicket,
            authorize: @escaping @Sendable () throws -> Void
        ) async throws -> [String: JSONValue]
        func discardPermits()
    }
#endif
