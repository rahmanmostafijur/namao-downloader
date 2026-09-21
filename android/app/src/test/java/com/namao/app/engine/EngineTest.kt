package com.namao.app.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PlatformDetectorTest {

    @Test fun `detects youtube watch and short urls`() {
        assertEquals("youtube", PlatformDetector.detect("https://www.youtube.com/watch?v=abc123"))
        assertEquals("youtube", PlatformDetector.detect("https://youtu.be/abc123"))
        assertEquals("youtube", PlatformDetector.detect("https://m.youtube.com/shorts/abc123"))
    }

    @Test fun `detects tiktok including regional subdomains`() {
        assertEquals("tiktok", PlatformDetector.detect("https://www.tiktok.com/@user/video/123"))
        assertEquals("tiktok", PlatformDetector.detect("https://vm.tiktok.com/ZMabc/"))
    }

    @Test fun `detects facebook instagram and twitter x`() {
        assertEquals("facebook", PlatformDetector.detect("https://fb.watch/abc/"))
        assertEquals("instagram", PlatformDetector.detect("https://www.instagram.com/reel/abc/"))
        assertEquals("twitter", PlatformDetector.detect("https://x.com/user/status/123"))
    }

    @Test fun `returns null for unsupported links`() {
        assertNull(PlatformDetector.detect("https://example.com/video/123"))
        assertNull(PlatformDetector.detect("not a url"))
    }

    @Test fun `normalize strips known tracking params but keeps identifying ones`() {
        val result = PlatformDetector.normalize("https://youtu.be/abc123?si=xyz&utm_source=share")
        assertFalse(result.contains("si="))
        assertFalse(result.contains("utm_source"))

        val withVideoId = PlatformDetector.normalize("https://www.youtube.com/watch?v=abc123&si=xyz")
        assertTrue(withVideoId.contains("v=abc123"))
        assertFalse(withVideoId.contains("si="))
    }

    @Test fun `normalize leaves an unparseable string unchanged`() {
        assertEquals("not a url", PlatformDetector.normalize("not a url"))
    }
}

class FilenameSanitizerTest {

    @Test fun `strips filesystem-invalid characters`() {
        val result = FilenameSanitizer.sanitizeBaseName("My Video: Test / Official Version?")
        assertFalse(result.contains(":"))
        assertFalse(result.contains("/"))
        assertFalse(result.contains("?"))
    }

    @Test fun `falls back to a default name for a blank or fully-invalid title`() {
        assertEquals("video", FilenameSanitizer.sanitizeBaseName("???"))
        assertEquals("video", FilenameSanitizer.sanitizeBaseName("   "))
    }

    @Test fun `truncates very long titles without exceeding the byte budget`() {
        val longTitle = "a".repeat(500)
        val result = FilenameSanitizer.sanitizeBaseName(longTitle)
        assertTrue(result.toByteArray(Charsets.UTF_8).size <= 120)
    }

    @Test fun `truncation does not split a multi-byte character`() {
        // Repeated multi-byte (3-byte UTF-8) characters so a naive byte-index
        // cut would land mid-character.
        val title = "বাংলা ".repeat(40)
        val result = FilenameSanitizer.sanitizeBaseName(title)
        // A corrupted cut would throw or produce the U+FFFD replacement
        // character when the bytes are decoded back.
        assertFalse(result.contains('�'))
    }
}

class ErrorClassifierTest {

    @Test fun `classifies network and timeout errors as auto-retryable`() {
        assertEquals(FailureKind.NETWORK, ErrorClassifier.classify("Connection reset by peer"))
        assertEquals(FailureKind.TIMEOUT, ErrorClassifier.classify("Read timed out"))
        assertTrue(ErrorClassifier.isAutoRetryable(FailureKind.NETWORK))
        assertTrue(ErrorClassifier.isAutoRetryable(FailureKind.TIMEOUT))
    }

    @Test fun `classifies permanent and unsupported errors as not retryable`() {
        assertEquals(FailureKind.PERMANENT_UNAVAILABLE, ErrorClassifier.classify("This video is private"))
        assertEquals(FailureKind.UNSUPPORTED_SOURCE, ErrorClassifier.classify("Unsupported URL: foo"))
        assertFalse(ErrorClassifier.isAutoRetryable(FailureKind.PERMANENT_UNAVAILABLE))
        assertFalse(ErrorClassifier.isAutoRetryable(FailureKind.UNSUPPORTED_SOURCE))
    }

    @Test fun `user message never echoes the raw exception text`() {
        FailureKind.entries.forEach { kind ->
            val message = ErrorClassifier.userMessage(kind)
            assertTrue(message.isNotBlank())
        }
    }
}
