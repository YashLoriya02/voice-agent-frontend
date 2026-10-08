package com.example.frontend

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.RadialGradient
import android.graphics.Shader
import android.graphics.SweepGradient
import android.os.Build
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.animation.LinearInterpolator
import android.widget.FrameLayout
import kotlin.math.PI
import kotlin.math.cos
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
    private val atmospherePaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val bounds = RectF()
    private val matrix = Matrix()
    private var shader: SweepGradient? = null
    private var animator: ValueAnimator? = null
    private var phase = .15f
    private var active = true
    private var state = "listening"
    private val blue = Color.rgb(55, 125, 255)
    private val red = Color.rgb(255, 86, 112)
    private val green = Color.rgb(66, 232, 171)
    private val yellow = Color.rgb(255, 208, 100)
    private val clouds = intArrayOf(blue, red, green, yellow).map { color ->
        RadialGradient(0f, 0f, 1f,
            intArrayOf(withAlpha(color, 170), withAlpha(color, 100), withAlpha(color, 28), withAlpha(color, 0)),
            floatArrayOf(0f, .22f, .6f, 1f), Shader.TileMode.CLAMP)
    }
    var cornerRadius = 30f * resources.displayMetrics.density
    init {
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        isClickable = false; isFocusable = false
    }
    fun updatePhase(value: String) {
        if (state == value) return
        state = value
        createShader()
        invalidate()
    }
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
            duration = 12000; repeatCount = ValueAnimator.INFINITE; interpolator = LinearInterpolator()
            addUpdateListener { phase = it.animatedValue as Float; postInvalidateOnAnimation() }
            start()
        }
    }
    private fun stop() { animator?.cancel(); animator = null }
    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) { createShader() }
    private fun createShader() {
        val highlight = when (state) { "success" -> green; "error" -> red; else -> Color.rgb(101, 227, 255) }
        shader = SweepGradient(width / 2f, height / 2f,
            intArrayOf(blue, red, yellow, green, highlight, blue),
            floatArrayOf(0f, .2f, .4f, .6f, .82f, 1f))
    }
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        // Dim the actual underlying screen. Drawing the scrim here makes the
        // preview and trusted voice session identical, with no extra overlay
        // permission, screenshots, or dependence on cross-window blur support.
        canvas.drawColor(Color.argb(132, 2, 5, 12))
        val orbit = phase * PI.toFloat() * 2f
        val breathing = (sin(orbit * 2f) + 1f) / 2f
        val energy = when (state) {
            "listening", "speaking" -> 1f
            "thinking", "executing" -> .9f
            else -> .75f
        }
        // Soft radial falloff provides a blurred-light appearance using cached
        // GPU shaders. The asymmetrical fields move slowly around the edges,
        // leaving the center and the assistant's text clear.
        cloud(canvas, 0, width * (.04f + .07f * sin(orbit)), height * (.25f + .08f * cos(orbit)), width * .66f, height * .37f, energy)
        cloud(canvas, 1, width * (.96f - .06f * cos(orbit)), height * (.1f + .06f * sin(orbit)), width * .61f, height * .28f, energy)
        cloud(canvas, 2, width * (.18f + .07f * cos(orbit)), height * (.97f - .07f * sin(orbit)), width * .75f, height * .31f, energy)
        cloud(canvas, 3, width * (.98f - .05f * sin(orbit)), height * (.74f + .06f * cos(orbit)), width * .57f, height * .33f, energy)
        // A wider blue/green halo links the floating card to the screen field.
        cloud(canvas, if (state == "success") 2 else 0, width * .52f, height * .94f,
            width * .65f, height * (.2f + .025f * breathing), .55f)
        val density = resources.displayMetrics.density
        val inset = 5f * density
        bounds.set(inset, inset, width - inset, height - inset)
        matrix.setRotate(phase * 360f, width / 2f, height / 2f)
        shader?.setLocalMatrix(matrix); paint.shader = shader
        // Wide translucent layers blend into the aurora; the narrow light trace
        // retains the recognizable full-device assistant outline.
        edge(canvas, density, 30f, 12)
        edge(canvas, density, 16f, 22)
        edge(canvas, density, 7f, 46)
        edge(canvas, density, 1.8f, (165 + breathing * 65).toInt())
    }
    private fun cloud(canvas: Canvas, index: Int, x: Float, y: Float, rx: Float, ry: Float, intensity: Float) {
        if (rx <= 0f || ry <= 0f) return
        atmospherePaint.shader = clouds[index]
        atmospherePaint.alpha = (205 * intensity).toInt()
        canvas.save()
        canvas.translate(x, y)
        canvas.scale(rx, ry)
        canvas.drawCircle(0f, 0f, 1f, atmospherePaint)
        canvas.restore()
    }
    private fun edge(canvas: Canvas, density: Float, stroke: Float, alpha: Int) {
        paint.strokeWidth = stroke * density
        paint.alpha = alpha
        canvas.drawRoundRect(bounds, cornerRadius, cornerRadius, paint)
    }
    private fun withAlpha(color: Int, alpha: Int) = Color.argb(alpha, Color.red(color), Color.green(color), Color.blue(color))
}
