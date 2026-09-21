package com.namao.app.engine

import android.content.Context
import com.yausername.youtubedl_android.YoutubeDLRequest
import java.io.File

/**
 * Netscape-format cookies.txt for platforms (Instagram in particular) that
 * require a logged-in session even for public-looking posts. Stored only in
 * app-private storage — never the shared Downloads directory, never sent
 * anywhere but back to yt-dlp's own `--cookies` flag (Phase 23).
 */
object CookieStore {

    private fun file(context: Context): File = File(context.filesDir, "cookies.txt")

    fun hasCookies(context: Context): Boolean = file(context).let { it.exists() && it.length() > 0 }

    fun read(context: Context): String = file(context).let { if (it.exists()) it.readText() else "" }

    fun save(context: Context, text: String) {
        val target = file(context)
        if (text.isBlank()) target.delete() else target.writeText(text)
    }

    fun applyTo(context: Context, request: YoutubeDLRequest) {
        val cookieFile = file(context)
        if (cookieFile.exists() && cookieFile.length() > 0) {
            request.addOption("--cookies", cookieFile.absolutePath)
        }
    }
}
