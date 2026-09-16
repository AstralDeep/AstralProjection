package com.personalailabs.astraldeep.app.auth

/** Activity-owned equality fence, never proof of server authorization. */
internal class AuthAttemptFence {
    private var epoch = 0L
    private var mode = Mode.LEGACY

    enum class Mode { LEGACY, SERVER }

    class Ticket internal constructor(internal val epoch: Long, internal var mode: Mode) {
        internal var consumed = false
        override fun toString(): String = "AuthAttemptTicket"
    }

    @Synchronized fun capture(): Ticket = Ticket(epoch, mode)

    @Synchronized fun begin(): Ticket {
        epoch++
        return Ticket(epoch, mode)
    }

    @Synchronized fun select(ticket: Ticket, selected: Mode) {
        current(ticket)
        if (ticket.consumed) unavailable()
        ticket.mode = selected
        mode = selected
    }

    @Synchronized fun consume(ticket: Ticket) {
        current(ticket)
        if (ticket.consumed) unavailable()
        ticket.consumed = true
    }

    @Synchronized fun <T> guarded(ticket: Ticket, block: () -> T): T {
        current(ticket)
        return block()
    }

    @Synchronized fun <T> publish(ticket: Ticket, block: () -> T): T {
        current(ticket)
        mode = ticket.mode
        return block()
    }

    @Synchronized fun currentMode(): Mode = mode

    @Synchronized fun retire() { epoch++ }

    private fun current(ticket: Ticket) {
        if (ticket.epoch != epoch) unavailable()
    }

    private fun unavailable(): Nothing = throw ServerSessionException(ServerSessionException.Reason.RETIRED)
}
