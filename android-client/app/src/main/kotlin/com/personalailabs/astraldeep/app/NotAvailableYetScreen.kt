// The only screen Android opens while the app waits for its kernel port.
// MainActivity hosts it and nothing else, and it names no sign-in and makes no network request.

package com.personalailabs.astraldeep.app

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

object NotAvailableYet {
    const val TEXT = "Astral for Android is not available yet. Use the Mac or iPhone app."
    const val TAG = "not-available-yet"
}

@Composable
fun NotAvailableYetScreen() {
    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Box(modifier = Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
            Text(
                text = NotAvailableYet.TEXT,
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onBackground,
                textAlign = TextAlign.Center,
                modifier = Modifier.testTag(NotAvailableYet.TAG),
            )
        }
    }
}
