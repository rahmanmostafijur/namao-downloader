package com.namao.app.ui

import android.net.Uri
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.namao.app.ui.dashboard.DashboardScreen
import com.namao.app.ui.history.HistoryScreen
import com.namao.app.ui.home.HomeScreen
import com.namao.app.ui.queue.QueueScreen
import com.namao.app.ui.settings.SettingsScreen

private data class TopLevelDestination(val route: String, val label: String, val icon: androidx.compose.ui.graphics.vector.ImageVector)

private val DESTINATIONS = listOf(
    TopLevelDestination("home", "Home", Icons.Default.Home),
    TopLevelDestination("queue", "Queue", Icons.Default.Download),
    TopLevelDestination("history", "History", Icons.AutoMirrored.Filled.List),
    TopLevelDestination("settings", "Settings", Icons.Default.Settings),
)

@Composable
fun NamaoApp(
    sharedUrl: String?,
    onSharedUrlConsumed: () -> Unit,
    initialRoute: String?,
    onInitialRouteConsumed: () -> Unit,
    onPickDownloadFolder: ((Uri) -> Unit) -> Unit,
) {
    val navController = rememberNavController()

    LaunchedEffect(initialRoute) {
        if (initialRoute != null) {
            navController.navigate(initialRoute) { launchSingleTop = true }
            onInitialRouteConsumed()
        }
    }
    LaunchedEffect(sharedUrl) {
        if (sharedUrl != null) {
            navController.navigate("home") { launchSingleTop = true }
        }
    }

    Scaffold(
        bottomBar = {
            val backStackEntry by navController.currentBackStackEntryAsState()
            val currentDestination = backStackEntry?.destination
            NavigationBar {
                DESTINATIONS.forEach { destination ->
                    val selected = currentDestination?.hierarchy?.any { it.route == destination.route } == true
                    NavigationBarItem(
                        selected = selected,
                        onClick = {
                            navController.navigate(destination.route) {
                                popUpTo(navController.graph.findStartDestination().id) { saveState = true }
                                launchSingleTop = true
                                restoreState = true
                            }
                        },
                        icon = { Icon(destination.icon, contentDescription = destination.label) },
                        label = { Text(destination.label) },
                    )
                }
            }
        },
    ) { padding ->
        NavHost(
            navController = navController,
            startDestination = "home",
            modifier = Modifier.padding(padding),
        ) {
            composable("home") {
                HomeScreen(
                    sharedUrl = sharedUrl,
                    onSharedUrlConsumed = onSharedUrlConsumed,
                    onNavigateToQueue = {
                        navController.navigate("queue") { launchSingleTop = true }
                    },
                    onNavigateToDashboard = {
                        navController.navigate("dashboard") { launchSingleTop = true }
                    },
                )
            }
            composable("queue") { QueueScreen() }
            composable("history") { HistoryScreen() }
            composable("settings") { SettingsScreen(onPickDownloadFolder = onPickDownloadFolder) }
            composable("dashboard") {
                DashboardScreen(
                    onNavigateToHistory = { navController.navigate("history") { launchSingleTop = true } },
                    onNavigateToSettings = { navController.navigate("settings") { launchSingleTop = true } },
                )
            }
        }
    }
}
