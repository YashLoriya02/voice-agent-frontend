package com.example.frontend

import android.app.Activity
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Bundle
import android.view.ViewGroup
import android.view.WindowManager

/** Settings preview of the same native surface used by the system assistant. */
class AssistantPreviewActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        window.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        // The shared assistant surface draws its own dimmed, animated backdrop.
        window.clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT

        androidx.core.view.WindowCompat.setDecorFitsSystemWindows(window, false)
        val root = AssistantOverlayView(this, preview = true, onDismiss = { finish() })
        root.setOnClickListener { finish() }
        setContentView(root)
    }

    override fun onStart() {
        super.onStart()
        window.setLayout(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT,
        )
    }

}
