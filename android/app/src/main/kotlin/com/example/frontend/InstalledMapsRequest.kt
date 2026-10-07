package com.example.frontend

import java.net.URLEncoder

/** The installed Maps app owns current location; never supply a custom origin. */
object InstalledMapsRequest {
    fun url(destination: String, startNavigation: Boolean = false): String {
        require(destination.isNotBlank() && destination.length <= 250)
        val encoded = URLEncoder.encode(destination, "UTF-8")
        return "https://www.google.com/maps/dir/?api=1&destination=$encoded&travelmode=driving" +
            if (startNavigation) "&dir_action=navigate" else ""
    }
}
