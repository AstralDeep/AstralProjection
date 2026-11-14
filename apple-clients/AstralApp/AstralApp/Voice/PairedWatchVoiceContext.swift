// Binds a paired Watch voice session to the phone's verified owner and exact live mesh conversation.
// MeshRuntime supplies this context; the companion transport cannot create one from its own claims.

import AstralCore
import Foundation

nonisolated struct PairedWatchVoiceContext: Equatable, Sendable {
    let owner: CompanionVoiceOwner
    let chatId: String
    let title: String
    let meshSession: UUID
}
