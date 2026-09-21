package com.namao.app.engine

import com.yausername.youtubedl_android.mapper.VideoFormat
import com.yausername.youtubedl_android.mapper.VideoInfo

/**
 * Kotlin port of build_qualities() in the desktop main.py: turns yt-dlp's raw
 * format list into one entry per resolution (highest bitrate wins ties),
 * highest first, plus an audio-only option. Only ever reflects formats the
 * source actually reported (Phase 7/30 — no fabricated resolutions).
 */
object QualityBuilder {

    fun build(platform: String, info: VideoInfo): MediaInfo {
        val formats: List<VideoFormat> = info.formats ?: emptyList()

        val videoFormats = formats.filter { it.vcodec != null && it.vcodec != "none" }
        val audioFormats = formats.filter {
            (it.acodec != null && it.acodec != "none") && (it.vcodec == null || it.vcodec == "none")
        }

        val bestAudio = audioFormats.maxByOrNull { it.abr }
        val bestAudioSize = bestAudio?.let { sizeOf(it.fileSize, it.fileSizeApproximate) }

        val bestByHeight = LinkedHashMap<Int, VideoFormat>()
        for (f in videoFormats) {
            if (f.height <= 0) continue
            val current = bestByHeight[f.height]
            if (current == null || f.tbr > current.tbr) {
                bestByHeight[f.height] = f
            }
        }

        val qualities = mutableListOf<QualityOption>()
        val heights = bestByHeight.keys.sortedDescending()
        for ((index, height) in heights.withIndex()) {
            val f = bestByHeight.getValue(height)
            var size = sizeOf(f.fileSize, f.fileSizeApproximate)
            val hasAudio = f.acodec != null && f.acodec != "none"
            if (!hasAudio && bestAudioSize != null && size != null) {
                size += bestAudioSize
            }
            qualities += QualityOption(
                id = height.toString(),
                label = "${height}p",
                note = if (index == 0) "Original quality" else "",
                sizeLabel = FileSize.format(size),
                kind = if (hasAudio) "progressive" else "video-only",
            )
        }

        qualities += QualityOption(
            id = "audio",
            label = "Audio only",
            note = "MP3",
            sizeLabel = FileSize.format(bestAudioSize),
            kind = "audio",
        )

        return MediaInfo(
            platform = platform,
            title = info.title?.takeIf { it.isNotBlank() } ?: "Untitled",
            uploader = info.uploader?.takeIf { it.isNotBlank() } ?: "",
            durationSeconds = info.duration.toLong(),
            thumbnailUrl = info.thumbnail,
            qualities = qualities,
        )
    }

    private fun sizeOf(fileSize: Long, fileSizeApprox: Long): Long? =
        if (fileSize > 0) fileSize else if (fileSizeApprox > 0) fileSizeApprox else null
}
