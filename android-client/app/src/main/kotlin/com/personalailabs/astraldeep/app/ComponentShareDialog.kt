// Composable share dialog that keeps content inside the app until an explicit user copy — no external share
// intent or automatic clipboard write.

package com.personalailabs.astraldeep.app

import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable

@Composable
internal fun ComponentShareDialog(
    url: String,
    onCopy: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Share component") },
        text = { SelectionContainer { Text(url) } },
        confirmButton = { TextButton(onClick = onCopy) { Text("Copy link") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Done") } },
    )
}
