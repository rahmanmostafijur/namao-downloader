package com.namao.app.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards the download state machine's two invariants (Phase 7): every status
 * is either active or terminal, never both, and never neither — so a status
 * added later can't silently fall through the Queue/History split or get
 * stuck with no screen able to show it.
 */
class DownloadStatusTest {

    @Test fun `every status is exactly active or terminal, never both, never neither`() {
        val allStatuses = DownloadStatus.entries.map { it.name }.toSet()
        val categorized = (ACTIVE_STATUSES + TERMINAL_STATUSES).toSet()
        val overlap = ACTIVE_STATUSES.toSet().intersect(TERMINAL_STATUSES.toSet())

        assertEquals("every DownloadStatus must be categorized", allStatuses, categorized)
        assertTrue("a status cannot be both active and terminal", overlap.isEmpty())
    }

    @Test fun `completed failed and cancelled are the only terminal statuses`() {
        assertEquals(
            setOf(DownloadStatus.COMPLETED.name, DownloadStatus.FAILED.name, DownloadStatus.CANCELLED.name),
            TERMINAL_STATUSES.toSet(),
        )
    }
}
