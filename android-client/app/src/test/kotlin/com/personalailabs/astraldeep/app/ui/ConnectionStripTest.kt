// Verifies initial and interrupted connection status for the shared Android console.

package com.personalailabs.astraldeep.app.ui

import com.personalailabs.astraldeep.app.transport.ConnectionState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class ConnectionStripTest {
    @Test
    fun initial_connecting_and_failure_remain_visible() {
        assertEquals("Connecting…", connectionStripLabel(ConnectionState.Connecting, everConnected = false))
        assertEquals("Unable to connect. Check your connection and retry.", connectionStripLabel(ConnectionState.Disconnected, everConnected = false))
    }

    @Test
    fun hidden_while_connected() {
        assertNull(connectionStripLabel(ConnectionState.Connected, everConnected = true))
    }

    @Test
    fun reconnecting_after_a_drop() {
        assertEquals("Reconnecting…", connectionStripLabel(ConnectionState.Disconnected, everConnected = true))
        assertEquals("Reconnecting…", connectionStripLabel(ConnectionState.Connecting, everConnected = true))
    }

    @Test
    fun reauth_label_on_auth_required() {
        assertEquals("Re-authenticating…", connectionStripLabel(ConnectionState.AuthRequired, everConnected = true))
    }
}
