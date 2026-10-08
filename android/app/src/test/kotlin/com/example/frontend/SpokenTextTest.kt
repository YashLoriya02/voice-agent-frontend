package com.example.frontend

import org.junit.Assert.*
import org.junit.Test

class SpokenTextTest {
    @Test fun messageFormattingAndEmojiAreNotReadAsSymbolNames() {
        assertEquals("Lunch Try rice Details", SpokenText.clean("## Lunch\n**Try** *rice* 🍽️ 🛍️ 🫂\n- [Details](https://example.com)"))
        assertEquals("", SpokenText.clean("👩🏽‍💻 🇮🇳 👨‍👩‍👧‍👦"))
    }
    @Test fun meaningfulMathUnitsAndLocalLanguagesStayIntact() {
        assertEquals("₹250, 50%, 25°C. 2 times 3 times 4 = 24. 3 < 5. Café मुंबई नमस्ते.",
            SpokenText.clean("₹250, 50%, 25°C. 2 * 3 * 4 = 24. 3 < 5. Café मुंबई नमस्ते."))
    }
}
