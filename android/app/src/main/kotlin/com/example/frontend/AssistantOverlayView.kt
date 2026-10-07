package com.example.frontend

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.SweepGradient
import android.os.Build
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.animation.LinearInterpolator
import android.widget.FrameLayout
import kotlin.math.PI
import kotlin.math.sin

/** Trusted assistant-session surface. Only the panel is touchable, not the glow. */
class AssistantOverlayView(context: Context, preview: Boolean = false, onDismiss: () -> Unit) : FrameLayout(context) {
    val panel = HeyAgentNudgeView(context, preview, onDismiss)
    private val glow = AssistantEdgeGlowView(context)
    init {
        setBackgroundColor(Color.TRANSPARENT)
        clipChildren = false
        addView(glow, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        addView(panel, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM).apply {
            leftMargin = dp(18); rightMargin = dp(18); bottomMargin = dp(28)
        })
        setOnApplyWindowInsetsListener { _, insets ->
            @Suppress("DEPRECATION")
            val bottom = if (Build.VERSION.SDK_INT >= 30) insets.getInsets(WindowInsets.Type.systemBars()).bottom else insets.systemWindowInsetBottom
            (panel.layoutParams as LayoutParams).also { it.bottomMargin = bottom + dp(20); panel.layoutParams = it }
            if (Build.VERSION.SDK_INT >= 31) {
                val radius = insets.getRoundedCorner(android.view.RoundedCorner.POSITION_TOP_LEFT)?.radius
                if (radius != null && radius > 0) glow.cornerRadius = radius.toFloat()
            }
            insets
        }
    }
    fun updateState(phase: String, caption: String) {
        val title = when (phase) {
            "listening" -> "LISTENING"
            "thinking" -> "THINKING"
            "speaking" -> "SPEAKING"
            "executing" -> "ON IT"
            "success" -> "DONE"
            "needsInput" -> "YOUR TURN"
            "error" -> "LET’S TRY AGAIN"
            else -> "READY WHEN YOU ARE"
        }
        panel.updateCopy(title, caption.take(100))
        glow.updatePhase(phase)
    }
    fun setActive(active: Boolean) = glow.setActive(active)
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
}

private class AssistantEdgeGlowView(context: Context) : View(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    private val bounds = RectF()
    private val matrix = Matrix()
    private var shader: SweepGradient? = null
    private var animator: ValueAnimator? = null
    private var phase = 0f
    private var active = true
    private var state = "listening"
    var cornerRadius = 30f * resources.displayMetrics.density
    init {
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        isClickable = false; isFocusable = false
    }
    fun updatePhase(value: String) { state = value; createShader(); invalidate() }
    fun setActive(value: Boolean) {
        active = value
        if (value && isAttachedToWindow && windowVisibility == VISIBLE) start() else stop()
    }
    override fun onAttachedToWindow() { super.onAttachedToWindow(); if (active) start() }
    override fun onDetachedFromWindow() { stop(); super.onDetachedFromWindow() }
    override fun onWindowVisibilityChanged(visibility: Int) {
        super.onWindowVisibilityChanged(visibility)
        if (visibility == VISIBLE && active && isAttachedToWindow) start() else stop()
    }
    private fun start() {
        if (animator != null || (Build.VERSION.SDK_INT >= 26 && !ValueAnimator.areAnimatorsEnabled())) return
        animator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 4200; repeatCount = ValueAnimator.INFINITE; interpolator = LinearInterpolator()
            addUpdateListener { phase = it.animatedValue as Float; invalidate() }
            start()
        }
    }
    private fun stop() { animator?.cancel(); animator = null }
    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) { createShader() }
    private fun createShader() {
        val highlight = when (state) { "success" -> Color.rgb(83, 230, 177); "error" -> Color.rgb(255, 135, 150); else -> Color.rgb(0, 200, 255) }
        shader = SweepGradient(width / 2f, height / 2f, intArrayOf(Color.rgb(47, 107, 255), highlight, Color.argb(50, 47, 107, 255), Color.rgb(47, 107, 255)), floatArrayOf(0f, .35f, .7f, 1f))
    }
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val density = resources.displayMetrics.density
        val inset = 5f * density
        bounds.set(inset, inset, width - inset, height - inset)
        matrix.setRotate(phase * 360f, width / 2f, height / 2f)
        shader?.setLocalMatrix(matrix); paint.shader = shader
        val pulse = (sin(phase * 2 * PI).toFloat() + 1f) / 2f
        for ((stroke, alpha) in listOf(12f to 20, 6f to 45, 2f to (170 + pulse * 75).toInt())) {
            paint.strokeWidth = stroke * density; paint.alpha = alpha
            canvas.drawRoundRect(bounds, cornerRadius, cornerRadius, paint)
        }
    }
}
