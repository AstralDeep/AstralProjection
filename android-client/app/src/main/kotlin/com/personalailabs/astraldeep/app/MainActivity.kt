// The launcher Activity: it shows the not available yet screen and hosts nothing else.
// Everything else in the app stays compiled until the Android kernel port lands.

package com.personalailabs.astraldeep.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import com.personalailabs.astraldeep.app.ui.theme.AstralTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { AstralTheme { NotAvailableYetScreen() } }
    }
}
