package com.example.frontend

/** Formatting/emoji cleanup stays on-device for private mail and messages. */
internal object SpokenText {
    fun clean(input: String): String {
        var text = input
            .replace(Regex("```[^\\n]*\\n"), "").replace("```", "")
            .replace(Regex("!\\[[^]]*]\\([^)]*\\)"), "")
            .replace(Regex("\\[([^]]+)]\\([^)]*\\)"), "$1")
            .replace(Regex("</?[A-Za-z][A-Za-z0-9]*(?:\\s[^>]*)?/?>"), "")
            .replace("&nbsp;", " ").replace("&amp;", "&")
            .replace(Regex("^\\s*(?:#{1,6}\\s+|>\\s*|[-*+]\\s+)", RegexOption.MULTILINE), "")
            .replace(Regex("(\\d)\\s*\\*\\s*(?=\\d)"), "$1 times ")
            .replace(Regex("\\*\\*(.+?)\\*\\*|__(.+?)__|~~(.+?)~~")) {
                it.groupValues.drop(1).first { group -> group.isNotEmpty() }
            }
            .replace(Regex("(?<!\\w)[*_]([^*_\\n]+)[*_](?!\\w)"), "$1")
            .replace("`", "").replace(Regex("\\*+"), "")
        text = buildString {
            text.codePoints().forEach { rune ->
                if (!isEmoji(rune)) appendCodePoint(rune)
            }
        }
        return text.replace(Regex("\\s+"), " ").trim()
    }

    private fun isEmoji(rune: Int): Boolean =
        rune in 0x1F000..0x1FAFF || rune in 0x2600..0x27BF ||
        rune in 0x23E9..0x23F3 || rune in 0xE0020..0xE007F ||
        rune in listOf(0x231A, 0x231B, 0x2B50, 0x2B55, 0x200D, 0xFE0E, 0xFE0F, 0x20E3)
}
