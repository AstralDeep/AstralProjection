package com.personalailabs.astraldeep.app

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFails
import kotlin.test.assertFalse
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class WorkspaceExportDestinationTest {
    private class Destination(var bytes: ByteArray = byteArrayOf()) : WorkspaceExportDestination {
        var removed = false
        var opened = false
        var afterWrite: () -> Unit = {}

        override fun isEmpty() = bytes.isEmpty()

        override fun delete() {
            removed = true
            bytes = byteArrayOf()
        }

        override fun open() =
            object : ByteArrayOutputStream() {
                init {
                    opened = true
                }

                override fun write(
                    value: ByteArray,
                    offset: Int,
                    count: Int,
                ) {
                    super.write(value, offset, count)
                    bytes = toByteArray()
                    afterWrite()
                }
            }
    }

    @Test fun stale_nonempty_callback_is_never_opened_or_deleted() =
        runTest {
            val destination = Destination("unrelated".toByteArray())
            val save = WorkspaceExportSave(destination)
            val source = File.createTempFile("workspace-test", ".html")
            try {
                assertFails { save.copy(source) { false } }
                save.cleanup()
                assertFalse(destination.opened)
                assertFalse(destination.removed)
                assertEquals("unrelated", destination.bytes.decodeToString())
            } finally {
                source.delete()
            }
        }

    @Test fun known_empty_abandoned_callback_is_removed_without_reading_source() =
        runTest {
            val destination = Destination()
            WorkspaceExportSave(destination).cleanup()
            assertTrue(destination.removed)
            assertFalse(destination.opened)
        }

    @Test fun failed_copy_removes_only_the_owned_partial_destination() =
        runTest {
            val destination = Destination()
            val neighbor = Destination("unrelated".toByteArray())
            var current = true
            destination.afterWrite = { current = false }
            val source = File.createTempFile("workspace-test", ".html").apply { writeText("private canvas") }
            val save = WorkspaceExportSave(destination)
            try {
                assertFails { save.copy(source) { current } }
                assertTrue(destination.bytes.isNotEmpty())
                save.cleanup()
                assertTrue(destination.removed)
                assertFalse(neighbor.removed)
                assertEquals("unrelated", neighbor.bytes.decodeToString())
            } finally {
                source.delete()
            }
        }

    @Test fun coroutine_cancel_removes_its_partial_output_after_writer_closes() =
        runTest {
            val destination = Destination()
            val written = CountDownLatch(1)
            val release = CountDownLatch(1)
            destination.afterWrite = {
                written.countDown()
                check(release.await(5, TimeUnit.SECONDS))
            }
            val source = File.createTempFile("workspace-test", ".html").apply { writeText("private canvas") }
            val save = WorkspaceExportSave(destination)
            val job =
                launch {
                    try {
                        save.copy(source) { true }
                    } finally {
                        save.cleanup()
                    }
                }
            try {
                runCurrent()
                withContext(Dispatchers.IO) { assertTrue(written.await(5, TimeUnit.SECONDS)) }
                job.cancel()
                release.countDown()
                job.join()
                assertTrue(destination.removed)
            } finally {
                release.countDown()
                source.delete()
            }
        }

    @Test fun successful_current_copy_and_nonempty_destination_refusal() =
        runTest {
            val source = File.createTempFile("workspace-test", ".html").apply { writeText("current canvas") }
            try {
                val destination = Destination()
                WorkspaceExportSave(destination).copy(source) { true }
                assertEquals("current canvas", destination.bytes.decodeToString())
                assertFalse(destination.removed)
                val foreign = Destination("keep".toByteArray())
                val refused = WorkspaceExportSave(foreign)
                assertFails { refused.copy(source) { true } }
                refused.cleanup()
                assertFalse(foreign.opened)
                assertFalse(foreign.removed)
            } finally {
                source.delete()
            }
        }
}
