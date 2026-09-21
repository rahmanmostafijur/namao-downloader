package com.namao.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import com.namao.app.settings.AppSettings
import com.namao.app.ui.NamaoApp
import com.namao.app.ui.theme.NamaoTheme

/**
 * A thin Compose host: permission requests, the SAF folder picker (which
 * must be registered here, before STARTED), and incoming share/view intents.
 * All actual state lives in the Room database / DataStore, read by the
 * screens' view models — so recreating this Activity (rotation, process
 * death) never loses in-flight download state (Phase 2).
 */
class MainActivity : ComponentActivity() {

    private var folderPickedCallback: ((Uri) -> Unit)? = null

    private val folderPickerLauncher =
        registerForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
            if (uri != null) folderPickedCallback?.invoke(uri)
            folderPickedCallback = null
        }

    private val notificationPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { /* no-op either way */ }

    private var sharedUrlState by mutableStateOf<String?>(null)
    private var initialRouteState by mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestNotificationPermissionIfNeeded()
        handleIntent(intent)

        setContent {
            val app = application as NamaoApplication
            val settings by app.settingsRepository.settings.collectAsState(initial = AppSettings())
            NamaoTheme(settings.themeMode) {
                NamaoApp(
                    sharedUrl = sharedUrlState,
                    onSharedUrlConsumed = { sharedUrlState = null },
                    initialRoute = initialRouteState,
                    onInitialRouteConsumed = { initialRouteState = null },
                    onPickDownloadFolder = { onPicked ->
                        folderPickedCallback = onPicked
                        folderPickerLauncher.launch(null)
                    },
                )
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent) {
        when (intent.action) {
            Intent.ACTION_SEND -> if (intent.type == "text/plain") {
                intent.getStringExtra(Intent.EXTRA_TEXT)?.let { extractUrl(it) }?.let { sharedUrlState = it }
            }
            Intent.ACTION_VIEW -> intent.dataString?.let { sharedUrlState = it }
            ACTION_OPEN_QUEUE -> initialRouteState = "queue"
            ACTION_OPEN_HISTORY -> initialRouteState = "history"
        }
    }

    private fun extractUrl(text: String): String? = URL_REGEX.find(text)?.value

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val granted = ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
            if (!granted) {
                notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            }
        }
    }

    companion object {
        const val ACTION_OPEN_QUEUE = "com.namao.app.action.OPEN_QUEUE"
        const val ACTION_OPEN_HISTORY = "com.namao.app.action.OPEN_HISTORY"
        private val URL_REGEX = Regex("https?://\\S+")
    }
}
