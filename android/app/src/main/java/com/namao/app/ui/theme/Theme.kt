package com.namao.app.ui.theme

import android.app.Activity
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat
import com.namao.app.settings.ThemeMode

// Same neutral zinc palette as the shared web UI (static/index.html), so the
// Android app and the desktop/browser version feel like the same product.
private val Zinc50 = Color(0xFFF7F7F8)
private val Zinc100 = Color(0xFFECECEE)
private val Zinc400 = Color(0xFF9A9AA2)
private val Zinc600 = Color(0xFF52525B)
private val Zinc800 = Color(0xFF27272E)
private val Zinc900 = Color(0xFF17171B)
private val Ink = Color(0xFF0A0A0D)
private val Danger = Color(0xFFDC2626)

private val LightColors = lightColorScheme(
    primary = Zinc600,
    onPrimary = Color.White,
    secondary = Zinc600,
    background = Zinc50,
    onBackground = Ink,
    surface = Color.White,
    onSurface = Ink,
    surfaceVariant = Zinc100,
    error = Danger,
)

private val DarkColors = darkColorScheme(
    primary = Zinc400,
    onPrimary = Ink,
    secondary = Zinc400,
    background = Ink,
    onBackground = Zinc50,
    surface = Zinc900,
    onSurface = Zinc50,
    surfaceVariant = Zinc800,
    error = Color(0xFFF87171),
)

private val NamaoTypography = Typography(
    titleLarge = TextStyle(fontWeight = FontWeight.SemiBold, fontSize = 22.sp),
    titleMedium = TextStyle(fontWeight = FontWeight.SemiBold, fontSize = 17.sp),
    bodyMedium = TextStyle(fontWeight = FontWeight.Normal, fontSize = 14.sp),
    labelLarge = TextStyle(fontWeight = FontWeight.Medium, fontSize = 14.sp),
)

/** Per-platform accent, matching the tint each platform gets in the shared
 * web UI — used sparingly (a chip, a thumbnail border), never as the whole
 * screen's color so the app still reads as one consistent product. */
fun platformAccent(platform: String): Color = when (platform) {
    "youtube" -> Color(0xFFFF0033)
    "facebook" -> Color(0xFF0866FF)
    "tiktok" -> Color(0xFF0EB8B8)
    "twitter" -> Color(0xFF7C8591)
    "instagram" -> Color(0xFFE1306C)
    else -> Zinc600
}

@Composable
fun NamaoTheme(themeMode: ThemeMode, content: @Composable () -> Unit) {
    val useDark = when (themeMode) {
        ThemeMode.SYSTEM -> isSystemInDarkTheme()
        ThemeMode.LIGHT -> false
        ThemeMode.DARK -> true
    }
    val colorScheme = if (useDark) DarkColors else LightColors

    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as Activity).window
            window.statusBarColor = colorScheme.background.toArgb()
            WindowCompat.getInsetsController(window, view).isAppearanceLightStatusBars = !useDark
        }
    }

    MaterialTheme(
        colorScheme = colorScheme,
        typography = NamaoTypography,
        content = content,
    )
}
