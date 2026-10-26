// Owns the Sparkle updater for the direct-download Mac app and publishes check, error and relaunch state for the update UI.
// Relaunch is postponed while AstralAppMain's busy probe reports a running chat, computer, browser or command task.

#if os(macOS)
    import AstralCore
    import AstralSparkle
    import Combine
    import Foundation

    @MainActor
    protocol UpdaterControlling: AnyObject {
        var canCheckForUpdates: Bool { get }
        var canCheckForUpdatesChanges: AnyPublisher<Bool, Never> { get }
        var automaticallyChecksForUpdates: Bool { get set }
        var automaticallyDownloadsUpdates: Bool { get set }
        var allowsAutomaticUpdates: Bool { get }
        var lastUpdateCheckDate: Date? { get }
        func checkForUpdates()
    }

    @MainActor
    final class SparkleUpdater: UpdaterControlling {
        private let controller: SPUStandardUpdaterController

        init(controller: SPUStandardUpdaterController) { self.controller = controller }

        var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
        var canCheckForUpdatesChanges: AnyPublisher<Bool, Never> {
            controller.updater.publisher(for: \.canCheckForUpdates).eraseToAnyPublisher()
        }
        var automaticallyChecksForUpdates: Bool {
            get { controller.updater.automaticallyChecksForUpdates }
            set { controller.updater.automaticallyChecksForUpdates = newValue }
        }
        var automaticallyDownloadsUpdates: Bool {
            get { controller.updater.automaticallyDownloadsUpdates }
            set { controller.updater.automaticallyDownloadsUpdates = newValue }
        }
        var allowsAutomaticUpdates: Bool { controller.updater.allowsAutomaticUpdates }
        var lastUpdateCheckDate: Date? { controller.updater.lastUpdateCheckDate }
        func checkForUpdates() { controller.checkForUpdates(nil) }
    }

    enum UpdateStatus: Equatable {
        case restartPending
        case failed(String)
    }

    @MainActor
    final class UpdateCoordinator: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
        static let previewKey = "update.channel.preview"
        static let busyPollInterval: Duration = .seconds(5)

        @Published private(set) var canCheckForUpdates = false
        @Published private(set) var lastCheck: Date?
        @Published private(set) var lastError: String?
        @Published private(set) var pendingRelaunch = false
        @Published private(set) var policyFailure: String?
        @Published private(set) var automaticChecks = false
        @Published private(set) var automaticInstall = false
        @Published private(set) var automaticInstallAvailable = false
        @Published private(set) var previewChannel: Bool
        @Published var settingsPresented = false

        private var updater: (any UpdaterControlling)?
        private var observation: AnyCancellable?
        private var relaunchHandler: (() -> Void)?
        private var relaunchPoll: Task<Void, Never>?
        private let isBusy: @MainActor () -> Bool
        private let defaults: UserDefaults
        private let clock: @MainActor () -> Date
        private let pollInterval: Duration

        var isEnabled: Bool { updater != nil }

        var status: UpdateStatus? {
            if pendingRelaunch { return .restartPending }
            if let failure = lastError ?? policyFailure { return .failed(failure) }
            return nil
        }

        init(
            isBusy: @escaping @MainActor () -> Bool, defaults: UserDefaults = .standard,
            clock: @escaping @MainActor () -> Date = { Date() }, pollInterval: Duration = busyPollInterval
        ) {
            self.isBusy = isBusy
            self.defaults = defaults
            self.clock = clock
            self.pollInterval = pollInterval
            previewChannel = defaults.bool(forKey: Self.previewKey)
            super.init()
        }

        static func live(isBusy: @escaping @MainActor () -> Bool) -> UpdateCoordinator {
            let coordinator = UpdateCoordinator(isBusy: isBusy)
            guard
                Bundle.main.object(forInfoDictionaryKey: "ASTRALDistribution") as? String
                    == UpdatePolicyGate.distributionMarker
            else { return coordinator }
            let controller = SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: coordinator, userDriverDelegate: coordinator)
            coordinator.attach(SparkleUpdater(controller: controller))
            return coordinator
        }

        static func isTaskActive(turnActive: Bool, session: ComputerHostSession?) -> Bool {
            turnActive || session != nil
        }

        static func installedVersion(bundle: Bundle = .main) -> String {
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
            return "\(version) (\(build))"
        }

        func attach(_ updater: any UpdaterControlling) {
            self.updater = updater
            canCheckForUpdates = updater.canCheckForUpdates
            lastCheck = updater.lastUpdateCheckDate
            automaticChecks = updater.automaticallyChecksForUpdates
            automaticInstall = updater.automaticallyDownloadsUpdates
            automaticInstallAvailable = updater.allowsAutomaticUpdates
            observation = updater.canCheckForUpdatesChanges.receive(on: DispatchQueue.main).sink { [weak self] value in
                MainActor.assumeIsolated { self?.canCheckForUpdates = value }
            }
        }

        func checkForUpdates() { updater?.checkForUpdates() }

        func setAutomaticChecks(_ value: Bool) {
            updater?.automaticallyChecksForUpdates = value
            automaticChecks = updater?.automaticallyChecksForUpdates ?? false
        }

        func setAutomaticInstall(_ value: Bool) {
            updater?.automaticallyDownloadsUpdates = value
            automaticInstall = updater?.automaticallyDownloadsUpdates ?? false
        }

        func setPreviewChannel(_ value: Bool) {
            defaults.set(value, forKey: Self.previewKey)
            previewChannel = value
        }

        func notePolicy(failure: UpdatePolicyFailure?) {
            policyFailure = failure.map(\.summary)
        }

        func enforce(_ gate: UpdatePolicyGate?) async -> UpdateRequirement? {
            guard let gate else { return nil }
            let outcome = await gate.evaluate()
            notePolicy(failure: gate.lastFailure)
            if case .required(let requirement) = outcome { return requirement }
            return nil
        }

        func allowedChannels(for updater: SPUUpdater) -> Set<String> {
            previewChannel ? ["preview"] : []
        }

        func updater(
            _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
            untilInvokingBlock installHandler: @escaping () -> Void
        ) -> Bool {
            postponeRelaunch(installHandler)
        }

        func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
            lastCheck = clock()
            lastError = nil
        }

        func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
            record(error)
        }

        func updater(
            _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?
        ) {
            lastCheck = clock()
            if let error, !Self.isBenign(error) { record(error) } else { lastError = nil }
        }

        var supportsGentleScheduledUpdateReminders: Bool { true }

        func postponeRelaunch(_ handler: @escaping () -> Void) -> Bool {
            guard isBusy() else { return false }
            relaunchHandler = handler
            pendingRelaunch = true
            if relaunchPoll == nil {
                relaunchPoll = Task { [weak self] in
                    while let self, !Task.isCancelled {
                        try? await Task.sleep(for: self.pollInterval)
                        if Task.isCancelled || self.releaseRelaunchIfIdle() { return }
                    }
                }
            }
            return true
        }

        @discardableResult
        func releaseRelaunchIfIdle() -> Bool {
            guard let handler = relaunchHandler else {
                relaunchPoll = nil
                return true
            }
            guard !isBusy() else { return false }
            relaunchHandler = nil
            relaunchPoll = nil
            pendingRelaunch = false
            handler()
            return true
        }

        func record(_ error: any Error) {
            guard !Self.isBenign(error) else { return }
            lastError = String((error as NSError).localizedDescription.prefix(200))
        }

        static func isBenign(_ error: any Error) -> Bool {
            let nsError = error as NSError
            return nsError.domain == SUSparkleErrorDomain
                && [SUError.noUpdateError, SUError.installationCanceledError].map { Int($0.rawValue) }.contains(
                    nsError.code)
        }
    }
#endif
