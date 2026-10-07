package com.example.frontend

import org.junit.Assert.*
import org.junit.Test

class MapsRouteTextParserTest {
    @Test fun parsesDisplayedMinutesAndKilometres() {
        val route = MapsRouteTextParser.parse("25 min (12.5 km)")!!
        assertEquals(12500.0, route.distanceMeters, 0.01)
        assertEquals(1500L, route.durationSeconds)
        assertEquals("25 min", route.durationText)
        assertEquals("12.5 km", route.distanceText)
    }
    @Test fun supportsHoursDaysDecimalCommasAndImperialLabels() {
        assertEquals(4500L, MapsRouteTextParser.parse("1 hr 15 min • 12,5 km")!!.durationSeconds)
        assertEquals(93600L, MapsRouteTextParser.parse("1 day 2 hr (500 km)")!!.durationSeconds)
        assertEquals(3218.688, MapsRouteTextParser.parse("10 min (2 mi)")!!.distanceMeters, 0.01)
        assertEquals(500.0, MapsRouteTextParser.parse("2 min (500 m)")!!.distanceMeters, 0.01)
    }
    @Test fun preservesSeveralRouteOptionsRatherThanGuessingOne() {
        val tree = MapsTextNode(children = listOf(
            MapsTextNode("Driving", selected = true), MapsTextNode("10 min (3 km)"), MapsTextNode("12 min (4 km)")))
        assertTrue(MapsRouteTextParser.isDriving(tree))
        assertEquals(2, MapsRouteTextParser.routes(tree).size)
    }
    @Test fun joinsSeparateLabelsOnlyInAnIdentifiedRouteGroup() {
        val labels = listOf(MapsTextNode("20 min"), MapsTextNode("12 km"))
        assertTrue(MapsRouteTextParser.routes(MapsTextNode(children = labels)).isEmpty())
        assertEquals(1, MapsRouteTextParser.routes(MapsTextNode(children = labels, routeGroup = true)).size)
    }
    @Test fun rejectsIncompleteRangesTransitAndMixedSummaries() {
        for (text in listOf("25 min", "12 km", "Walking 25 min (12 km)", "20–30 min (12 km)", "10 min 3 km 12 min 4 km", "100 min (NaN km)")) {
            assertNull(text, MapsRouteTextParser.parse(text))
        }
    }
    @Test fun unselectedDrivingTabIsNotEvidenceOfDrivingMode() {
        assertFalse(MapsRouteTextParser.isDriving(MapsTextNode(children = listOf(MapsTextNode("Driving"), MapsTextNode("Walking", selected = true)))))
        assertTrue(MapsRouteTextParser.isDriving(MapsTextNode("Driving, selected")))
    }
    @Test fun matchesRequestedDestinationAgainstVisibleText() {
        val tree = MapsTextNode("Mumbai Airport, Driving", children = listOf(MapsTextNode("25 min (12 km)")))
        assertTrue(MapsRouteTextParser.matchesDestination(tree, "Mumbai airport"))
        assertFalse(MapsRouteTextParser.matchesDestination(tree, "Phoenix Marketcity"))
    }
    @Test fun duplicateAccessibilityLabelsDoNotCreateExtraRoutes() {
        val tree = MapsTextNode("25 min (12 km)", children = listOf(MapsTextNode("25 min (12 km)")))
        assertEquals(1, MapsRouteTextParser.routes(tree).size)
    }
}
