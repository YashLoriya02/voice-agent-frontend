package com.example.frontend

import org.junit.Assert.*
import org.junit.Test
import java.net.URI
import java.net.URLDecoder

class InstalledMapsRequestTest {
    private fun query(url: String) = URI(url).rawQuery.split('&').associate {
        val parts = it.split('=', limit = 2)
        parts[0] to URLDecoder.decode(parts[1], "UTF-8")
    }
    @Test fun navigationUsesMapsCurrentLocationWithoutOriginCoordinatesOrKey() {
        assertEquals(mapOf("api" to "1", "destination" to "Pune", "travelmode" to "driving", "dir_action" to "navigate"), query(InstalledMapsRequest.url("Pune", true)))
    }
    @Test fun distanceOnlyDirectionsDoNotStartNavigationAndPreserveDestinationCharacters() {
        val destination = "Café, Kurla & Mumbai / Gate #1"
        assertEquals(mapOf("api" to "1", "destination" to destination, "travelmode" to "driving"), query(InstalledMapsRequest.url(destination)))
    }
    @Test fun invalidDestinationsCannotBecomeNavigationRequests() {
        for (destination in listOf("", " ", "x".repeat(251))) {
            try { InstalledMapsRequest.url(destination, true); fail("Invalid destination accepted") }
            catch (_: IllegalArgumentException) { }
        }
    }
}
