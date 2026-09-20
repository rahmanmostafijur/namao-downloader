package com.namao.app

import android.annotation.SuppressLint
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Environment
import android.util.Log
import android.webkit.JavascriptInterface
import android.webkit.MimeTypeMap
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.documentfile.provider.DocumentFile
import androidx.webkit.WebViewAssetLoader
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLException
import com.yausername.youtubedl_android.YoutubeDLRequest
import com.yausername.ffmpeg.FFmpeg
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CountDownLatch
import kotlin.concurrent.thread

/**
 * Namao, ported to a standalone Android app: no PC, no server. The WebView
 * shows the exact same frontend (static/index.html) used by the desktop
 * version; NamaoBridge below stands in for what main.py's FastAPI routes did,
 * calling into a bundled yt-dlp + ffmpeg instead of a Python process.
 */
class MainActivity : AppCompatActivity() {

    companion object {
        private const val DOWNLOAD_FOLDER_KEY = "download_folder_uri"
    }

    private lateinit var webView: WebView

    // Mirrors PLATFORM_PATTERNS in main.py — kept as a second check here
    // even though the frontend JS already screens the URL first.
    private val platformPatterns = linkedMapOf(
        "youtube" to Regex("(youtube\\.com|youtu\\.be)", RegexOption.IGNORE_CASE),
        "facebook" to Regex("(facebook\\.com|fb\\.watch|fb\\.com)", RegexOption.IGNORE_CASE),
        "tiktok" to Regex("([a-z]{2}\\.)?tiktok\\.com", RegexOption.IGNORE_CASE),
        "twitter" to Regex("(twitter\\.com|x\\.com)", RegexOption.IGNORE_CASE),
        "instagram" to Regex("instagram\\.com", RegexOption.IGNORE_CASE),
    )

    private fun detectPlatform(url: String): String? =
        platformPatterns.entries.firstOrNull { it.value.containsMatchIn(url) }?.key

    // youtubedl-android bundles a yt-dlp binary frozen at the library's last
    // release, which goes stale fast — YouTube in particular changes often
    // enough that an old yt-dlp regresses to audio-only or nothing at all.
    // This mirrors the desktop README's "pip install -U yt-dlp" advice: self
    // update once on startup, and make every bridge call wait for it so the
    // very first fetch after install also benefits (the frontend's existing
    // "Reading video info…" loading state covers this wait for free).
    private val readyLatch = CountDownLatch(1)

    // Storage Access Framework folder picker: lets the user choose where
    // downloads land instead of a hardcoded Downloads/Namao. Must be
    // registered before the Activity reaches STARTED, so this is a field,
    // not something created lazily inside a bridge method.
    private val prefs by lazy { getSharedPreferences("namao", MODE_PRIVATE) }

    private fun savedFolderUri(): Uri? =
        prefs.getString(DOWNLOAD_FOLDER_KEY, null)?.let { Uri.parse(it) }

    private fun folderDisplayName(): String {
        val uri = savedFolderUri() ?: return "Downloads/Namao (default)"
        val doc = DocumentFile.fromTreeUri(this, uri)
        return doc?.name?.let { "…/$it" } ?: "Downloads/Namao (default)"
    }

    private val folderPickerLauncher =
        registerForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
            if (uri != null) {
                contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                )
                prefs.edit().putString(DOWNLOAD_FOLDER_KEY, uri.toString()).apply()
            }
            evalJs(
                "window.__namaoFolderChosen && window.__namaoFolderChosen(${JSONObject.quote(folderDisplayName())})"
            )
        }

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        thread {
            try {
                YoutubeDL.getInstance().init(this)
                FFmpeg.getInstance().init(this)
                try {
                    YoutubeDL.getInstance().updateYoutubeDL(this)
                } catch (e: YoutubeDLException) {
                    Log.e("Namao", "yt-dlp self-update failed, continuing with bundled version", e)
                }
            } catch (e: YoutubeDLException) {
                Log.e("Namao", "failed to initialize youtubedl-android", e)
            } finally {
                readyLatch.countDown()
            }
        }

        webView = WebView(this)
        setContentView(webView)

        val assetLoader = WebViewAssetLoader.Builder()
            .addPathHandler("/assets/", WebViewAssetLoader.AssetsPathHandler(this))
            .build()

        webView.settings.javaScriptEnabled = true
        webView.settings.domStorageEnabled = true
        webView.addJavascriptInterface(NamaoBridge(), "NamaoBridge")
        webView.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(
                view: WebView,
                request: WebResourceRequest
            ): WebResourceResponse? = assetLoader.shouldInterceptRequest(request.url)
        }
        webView.loadUrl("https://appassets.androidplatform.net/assets/index.html")
    }

    override fun onBackPressed() {
        if (webView.canGoBack()) webView.goBack() else super.onBackPressed()
    }

    // ---------------------------------------------------------------------
    // JS <-> Kotlin bridge
    // ---------------------------------------------------------------------

    private fun evalJs(js: String) {
        runOnUiThread { webView.evaluateJavascript(js, null) }
    }

    private fun resolveInfoJs(callId: String, jsonPayload: String) {
        evalJs("window.__namaoInfoResolve && window.__namaoInfoResolve('$callId', ${JSONObject.quote(jsonPayload)})")
    }

    private fun resolveDownloadJs(callId: String, filename: String) {
        evalJs("window.__namaoDownloadResolve && window.__namaoDownloadResolve('$callId', ${JSONObject.quote(filename)})")
    }

    private fun progressJs(callId: String, percent: Float) {
        evalJs("window.__namaoProgress && window.__namaoProgress('$callId', $percent)")
    }

    private fun rejectJs(callId: String, message: String) {
        evalJs("window.__namaoReject && window.__namaoReject('$callId', ${JSONObject.quote(message)})")
    }

    inner class NamaoBridge {

        @JavascriptInterface
        fun fetchInfo(url: String, callId: String) {
            thread {
                val platform = detectPlatform(url)
                if (platform == null) {
                    rejectJs(
                        callId,
                        "That link doesn't look like YouTube, Facebook, TikTok, X/Twitter, or Instagram."
                    )
                    return@thread
                }
                try {
                    readyLatch.await()
                    val infoRequest = YoutubeDLRequest(url)
                    applyCookies(infoRequest)
                    val info = YoutubeDL.getInstance().getInfo(infoRequest)
                    val json = buildInfoJson(platform, info)
                    resolveInfoJs(callId, json.toString())
                } catch (e: Exception) {
                    rejectJs(
                        callId,
                        e.message
                            ?: "Couldn't read that video. It may be private, deleted, age-restricted, or blocked in your region."
                    )
                }
            }
        }

        @JavascriptInterface
        fun download(url: String, quality: String, callId: String) {
            thread {
                if (detectPlatform(url) == null) {
                    rejectJs(callId, "Unsupported link.")
                    return@thread
                }

                val tempDir = File(cacheDir, "dl_$callId")
                tempDir.mkdirs()
                try {
                    readyLatch.await()
                    val outTemplate = File(tempDir, "%(title).120B.%(ext)s").absolutePath
                    val request = buildDownloadRequest(url, quality, outTemplate)

                    YoutubeDL.getInstance().execute(request, callId) { progress, _, _ ->
                        progressJs(callId, progress)
                    }

                    val files = tempDir.listFiles()
                    if (files.isNullOrEmpty()) {
                        rejectJs(callId, "Download produced no file.")
                        return@thread
                    }
                    val result = files.maxByOrNull { it.length() }!!

                    resolveDownloadJs(callId, saveResultFile(result))
                } catch (e: Exception) {
                    rejectJs(
                        callId,
                        e.message ?: "Download failed — the video may no longer be available."
                    )
                } finally {
                    tempDir.deleteRecursively()
                }
            }
        }

        // Cookie file lives in the app's private storage (filesDir), never
        // the shared Downloads directory — it can contain live session
        // tokens. Netscape format, exactly what yt-dlp's --cookies expects.
        @JavascriptInterface
        fun hasCookies(): Boolean = cookiesFile().let { it.exists() && it.length() > 0 }

        @JavascriptInterface
        fun getCookies(): String = if (cookiesFile().exists()) cookiesFile().readText() else ""

        @JavascriptInterface
        fun saveCookies(text: String) {
            val file = cookiesFile()
            if (text.trim().isEmpty()) {
                file.delete()
            } else {
                file.writeText(text)
            }
        }

        // Launching the system folder picker has to happen on the UI thread;
        // the result comes back later via folderPickerLauncher's callback,
        // which notifies JS through window.__namaoFolderChosen.
        @JavascriptInterface
        fun pickDownloadFolder() {
            runOnUiThread { folderPickerLauncher.launch(null) }
        }

        @JavascriptInterface
        fun getDownloadFolderName(): String = folderDisplayName()
    }

    private fun cookiesFile(): File = File(filesDir, "cookies.txt")

    // Writes into the user-chosen SAF folder if one was picked; otherwise
    // falls back to Downloads/Namao (also used if the chosen folder became
    // unwritable, e.g. a removed SD card).
    private fun saveResultFile(result: File): String {
        val treeUri = savedFolderUri()
        if (treeUri != null) {
            val treeDoc = DocumentFile.fromTreeUri(this, treeUri)
            if (treeDoc != null && treeDoc.canWrite()) {
                val mime = MimeTypeMap.getSingleton()
                    .getMimeTypeFromExtension(result.extension) ?: "application/octet-stream"
                val newFile = treeDoc.createFile(mime, result.name)
                if (newFile != null) {
                    val out = contentResolver.openOutputStream(newFile.uri)
                    if (out != null) {
                        out.use { stream -> result.inputStream().use { it.copyTo(stream) } }
                        return newFile.name ?: result.name
                    }
                }
            }
        }

        val downloadsDir = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            "Namao"
        )
        downloadsDir.mkdirs()
        val destFile = File(downloadsDir, result.name)
        result.copyTo(destFile, overwrite = true)
        return destFile.name
    }

    private fun applyCookies(request: YoutubeDLRequest) {
        val file = cookiesFile()
        if (file.exists() && file.length() > 0) {
            request.addOption("--cookies", file.absolutePath)
        }
    }

    // ---------------------------------------------------------------------
    // Format-string selection — same yt-dlp flags main.py already validated,
    // just issued via YoutubeDLRequest instead of yt-dlp's Python API. ffmpeg
    // is always bundled here, so unlike main.py there's no PATH-less fallback.
    // ---------------------------------------------------------------------

    private fun buildDownloadRequest(url: String, quality: String, outTemplate: String): YoutubeDLRequest {
        val request = YoutubeDLRequest(url)
        applyCookies(request)
        request.addOption("-o", outTemplate)
        when {
            quality == "audio" -> {
                request.addOption("-f", "bestaudio/best")
                request.addOption("-x")
                request.addOption("--audio-format", "mp3")
                request.addOption("--audio-quality", "192K")
            }
            quality == "best" -> {
                request.addOption("-f", "bv*+ba/b")
                request.addOption("--merge-output-format", "mp4")
            }
            else -> {
                val height = quality.toIntOrNull()
                    ?: throw IllegalArgumentException("Invalid quality value.")
                request.addOption("-f", "bv*[height<=$height]+ba/b[height<=$height]/b")
                request.addOption("--merge-output-format", "mp4")
            }
        }
        return request
    }

    // ---------------------------------------------------------------------
    // Quality list building — a Kotlin port of build_qualities() in main.py.
    // ---------------------------------------------------------------------

    private fun formatSize(numBytes: Long?): String? {
        if (numBytes == null || numBytes <= 0) return null
        var size = numBytes.toDouble()
        val units = listOf("B", "KB", "MB", "GB")
        for (unit in units) {
            if (size < 1024 || unit == "GB") {
                return if (unit == "B") "${size.toInt()} B" else String.format("%.1f %s", size, unit)
            }
            size /= 1024
        }
        return null
    }

    private fun sizeOf(fileSize: Long, fileSizeApprox: Long): Long? =
        if (fileSize > 0) fileSize else if (fileSizeApprox > 0) fileSizeApprox else null

    private fun buildQualities(info: com.yausername.youtubedl_android.mapper.VideoInfo): JSONArray {
        val formats = info.formats ?: arrayListOf()

        val videoFormats = formats.filter { it.vcodec != null && it.vcodec != "none" }
        val audioFormats = formats.filter {
            (it.acodec != null && it.acodec != "none") && (it.vcodec == null || it.vcodec == "none")
        }

        val bestAudio = audioFormats.maxByOrNull { it.abr }
        val bestAudioSize = bestAudio?.let { sizeOf(it.fileSize, it.fileSizeApproximate) }

        val bestByHeight = LinkedHashMap<Int, com.yausername.youtubedl_android.mapper.VideoFormat>()
        for (f in videoFormats) {
            if (f.height <= 0) continue
            val current = bestByHeight[f.height]
            if (current == null || f.tbr > current.tbr) {
                bestByHeight[f.height] = f
            }
        }

        val qualities = JSONArray()
        val heights = bestByHeight.keys.sortedDescending()
        for ((index, height) in heights.withIndex()) {
            val f = bestByHeight.getValue(height)
            var size = sizeOf(f.fileSize, f.fileSizeApproximate)
            val hasAudio = f.acodec != null && f.acodec != "none"
            if (!hasAudio && bestAudioSize != null && size != null) {
                size += bestAudioSize
            }
            val obj = JSONObject()
            obj.put("id", height.toString())
            obj.put("label", "${height}p")
            obj.put("note", if (index == 0) "Original quality" else "")
            obj.put("size", formatSize(size) ?: JSONObject.NULL)
            obj.put("kind", if (hasAudio) "progressive" else "video-only")
            qualities.put(obj)
        }

        val audioObj = JSONObject()
        audioObj.put("id", "audio")
        audioObj.put("label", "Audio only")
        audioObj.put("note", "MP3")
        audioObj.put("size", formatSize(bestAudioSize) ?: JSONObject.NULL)
        audioObj.put("kind", "audio")
        qualities.put(audioObj)

        return qualities
    }

    private fun buildInfoJson(
        platform: String,
        info: com.yausername.youtubedl_android.mapper.VideoInfo
    ): JSONObject {
        val obj = JSONObject()
        obj.put("platform", platform)
        obj.put("title", info.title ?: "Untitled")
        obj.put("uploader", info.uploader ?: "")
        obj.put("duration", info.duration)
        obj.put("thumbnail", info.thumbnail ?: JSONObject.NULL)
        obj.put("ffmpeg", true)
        obj.put("qualities", buildQualities(info))
        return obj
    }
}
