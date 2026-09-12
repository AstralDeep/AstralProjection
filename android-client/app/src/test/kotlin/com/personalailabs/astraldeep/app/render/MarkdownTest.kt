package com.personalailabs.astraldeep.app.render

import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.intl.LocaleList
import androidx.compose.ui.text.toUpperCase
import com.personalailabs.astraldeep.app.AppConfig
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Feature 044 T029 — inline `[label](url)` markdown links become URL annotations. */
class MarkdownTest {
    @Test
    fun link_produces_a_url_annotation_and_inlines_the_label() {
        val a = inlineMarkdown("see [Google](https://google.com) now")
        assertEquals("see Google now", a.text)
        val links = a.getLinkAnnotations(0, a.length)
        assertEquals(1, links.size)
        assertEquals("https://google.com", (links.first().item as LinkAnnotation.Url).url)
    }

    @Test
    fun plain_text_is_unchanged_and_has_no_links() {
        val a = inlineMarkdown("just plain text")
        assertEquals("just plain text", a.text)
        assertTrue(a.getLinkAnnotations(0, a.length).isEmpty())
    }

    @Test
    fun bold_and_code_still_work_alongside_a_link() {
        val a = inlineMarkdown("**bold** `x` and [docs](http://d)")
        assertEquals("bold x and docs", a.text)
        assertEquals(1, a.getLinkAnnotations(0, a.length).size)
    }

    @Test
    fun a_malformed_link_stays_literal() {
        val a = inlineMarkdown("[no paren] here")
        assertEquals("[no paren] here", a.text)
        assertTrue(a.getLinkAnnotations(0, a.length).isEmpty())
    }

    @Test
    fun untrusted_schemes_and_malformed_destinations_remain_inert_labels() {
        for (url in listOf("javascript:alert", "data:text/html,hello", "intent:launch", "tel:+15555550100", "file:///etc/passwd", "content://private/item", "com.personalailabs.astraldeep:/oauth2redirect", "https://", "https://example.com/\\evil", "https://example.com/\u0000bad")) {
            val text = inlineMarkdown("before [Open]($url) after")
            assertEquals("before Open after", text.text)
            assertTrue(text.getLinkAnnotations(0, text.length).isEmpty(), url)
        }
    }

    @Test
    fun root_relative_link_resolves_against_configured_backend_instead_of_device() {
        val text = inlineMarkdown("[Audit](/api/audit?limit=5#details)")
        val link = text.getLinkAnnotations(0, text.length).single().item as LinkAnnotation.Url
        assertEquals("${AppConfig.API_BASE}/api/audit?limit=5#details", link.url)
    }

    @Test
    fun safe_external_and_email_destinations_are_preserved() {
        for (url in listOf("https://example.com/CaseSensitive?Key=Value#Section", "http://example.com/reference", "mailto:help@example.com?subject=Question")) {
            val text = inlineMarkdown("[Reference]($url)")
            assertEquals(url, (text.getLinkAnnotations(0, text.length).single().item as LinkAnnotation.Url).url)
        }
    }

    @Test
    fun relative_links_use_browser_resolution_and_reject_an_untrusted_base() {
        for ((reference, expected) in listOf("/docs/../audit?q=1#row" to "https://backend.example:8443/audit?q=1#row", "//public.example/reference" to "https://public.example/reference")) {
            val text = inlineMarkdown("[Read]($reference)", "https://backend.example:8443/base")
            assertEquals(expected, (text.getLinkAnnotations(0, text.length).single().item as LinkAnnotation.Url).url)
        }
        for (base in listOf("file:///private", "javascript:run", "https://", "https://user:password@backend.example", "https://backend.example/#fragment")) {
            val text = inlineMarkdown("[Read](/audit)", base)
            assertEquals("Read", text.text)
            assertTrue(text.getLinkAnnotations(0, text.length).isEmpty(), base)
        }
        for (reference in listOf("/\\public.example/path", "//", "relative/file", "#local", "mailto:", "mailto://private/path", "HTTPS://example.com/\r\nInjected")) {
            val text = inlineMarkdown("[Read]($reference)", "https://backend.example")
            assertTrue(text.getLinkAnnotations(0, text.length).isEmpty(), reference)
        }
    }

    @Test
    fun uppercasing_a_metric_title_preserves_exact_link_target_and_adjusted_range() {
        val url = "https://example.com/Mixed?Case=Keep#Section"
        val text = inlineMarkdown("straße [Docs]($url)").toUpperCase(LocaleList("en"))
        assertEquals("STRASSE DOCS", text.text)
        val link = text.getLinkAnnotations(0, text.length).single()
        assertEquals(url, (link.item as LinkAnnotation.Url).url)
        assertEquals("DOCS", text.text.substring(link.start, link.end))
        assertEquals(8, link.start)
    }
}
