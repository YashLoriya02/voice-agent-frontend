package com.example.frontend

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.SweepGradient
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.animation.LinearInterpolator
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.ImageButton
import android.content.res.ColorStateList
import android.text.TextUtils
import kotlin.math.PI
import kotlin.math.sin

/** Shared native assistant card used by the real invocation and settings preview. */
class HeyAgentNudgeView(
    context: Context,
    previewMode: Boolean = false,
    onDismiss: (() -> Unit)? = null,
) : FrameLayout(context) {

    private val subtitleView: TextView
    private val statusView: TextView

    init {
        clipToPadding = false
        clipChildren = false
        setPadding(dp(2), dp(2), dp(2), dp(2))
        elevation = dp(22).toFloat()
        contentDescription = "Hey Agent assistant panel"

        background = GradientDrawable(
            GradientDrawable.Orientation.TL_BR,
            intArrayOf(
                Color.rgb(61, 128, 255),
                Color.rgb(27, 235, 224),
                Color.rgb(49, 88, 232),
            ),
        ).apply {
            cornerRadius = dp(30).toFloat()
        }

        val surface = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(18), dp(15), dp(18), dp(13))
            background = GradientDrawable(
                GradientDrawable.Orientation.TL_BR,
                intArrayOf(
                    Color.rgb(5, 10, 24),
                    Color.rgb(6, 28, 60),
                    Color.rgb(5, 67, 112),
                ),
            ).apply {
                cornerRadius = dp(28).toFloat()
                setStroke(dp(1), Color.argb(150, 71, 163, 255))
            }
        }

        addView(
            surface,
            LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )

        val mainRow = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }

        mainRow.addView(
            AgentCoreView(context),
            LinearLayout.LayoutParams(dp(58), dp(58)).apply {
                marginEnd = dp(15)
            },
        )

        val copy = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.START
        }

        val eyebrow = TextView(context).apply {
            text = "YOUR PERSONAL ASSISTANT"
            setTextColor(Color.rgb(112, 171, 255))
            textSize = 8f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            letterSpacing = 0.18f
        }

        val title = TextView(context).apply {
            text = "HEY AGENT"
            setTextColor(Color.WHITE)
            textSize = 20f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            letterSpacing = 0.08f
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            includeFontPadding = false
        }

        subtitleView = TextView(context).apply {
            text = "HOW MAY I HELP?"
            setTextColor(Color.rgb(133, 226, 255))
            textSize = 11f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            letterSpacing = 0.12f
            includeFontPadding = false
        }

        copy.addView(eyebrow)
        copy.addView(
            title,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = dp(2) },
        )
        copy.addView(
            subtitleView,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = dp(4) },
        )

        mainRow.addView(
            copy,
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
        )

        val livePill = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(8), dp(5), dp(8), dp(5))
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(20).toFloat()
                setColor(Color.argb(145, 4, 18, 35))
                setStroke(dp(1), Color.argb(155, 49, 225, 183))
            }
        }

        livePill.addView(
            PulseDotView(context),
            LinearLayout.LayoutParams(dp(8), dp(8)).apply {
                marginEnd = dp(6)
            },
        )
        livePill.addView(
            TextView(context).apply {
                text = "LIVE"
                setTextColor(Color.rgb(83, 230, 177))
                textSize = 8f
                typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                letterSpacing = 0.12f
            },
        )
        if (onDismiss != null) {
            mainRow.addView(ImageButton(context).apply {
                contentDescription = "Close assistant"
                setImageResource(android.R.drawable.ic_menu_close_clear_cancel)
                imageTintList = ColorStateList.valueOf(Color.rgb(133, 226, 255))
                setBackgroundColor(Color.TRANSPARENT)
                setPadding(dp(10), dp(10), dp(10), dp(10))
                setOnClickListener { onDismiss() }
            }, LinearLayout.LayoutParams(dp(42), dp(42)))
        }
        surface.addView(mainRow)

        val signalRow = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }

        signalRow.addView(
            ListeningWaveView(context),
            LinearLayout.LayoutParams(dp(76), dp(24)),
        )

        statusView = TextView(context).apply {
            text = if (previewMode) "PREVIEW YOUR ASSISTANT" else "How can I help?"
            setTextColor(Color.rgb(91, 143, 197))
            textSize = 10f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            letterSpacing = 0.02f
            gravity = Gravity.END
            maxLines = 2
            ellipsize = TextUtils.TruncateAt.END
        }

        signalRow.addView(livePill, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginStart = dp(6); marginEnd = dp(8) })
        signalRow.addView(
            statusView,
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
        )

        surface.addView(
            signalRow,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = dp(10) },
        )
    }

    fun updateCopy(subtitle: String, status: String) {
        subtitleView.text = subtitle
        statusView.text = status
    }

    private fun dp(value: Int): Int {
        return (value * resources.displayMetrics.density).toInt()
    }
}

private class AgentCoreView(context: Context) : AssistantAnimatedView(context, 1900L) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val arcBounds = RectF()
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val cx = width / 2f
        val cy = height / 2f
        val pulse = (sin(phase * PI * 2).toFloat() + 1f) / 2f

        paint.style = Paint.Style.FILL
        paint.shader = RadialGradient(
            cx,
            cy,
            width * .48f,
            intArrayOf(
                Color.argb((115 + pulse * 45).toInt(), 29, 189, 255),
                Color.argb(24, 31, 105, 255),
                Color.TRANSPARENT,
            ),
            floatArrayOf(0f, .55f, 1f),
            Shader.TileMode.CLAMP,
        )
        canvas.drawCircle(cx, cy, width * .48f, paint)

        val ringRadius = width * .38f
        arcBounds.set(cx - ringRadius, cy - ringRadius, cx + ringRadius, cy + ringRadius)
        paint.shader = SweepGradient(
            cx,
            cy,
            intArrayOf(
                Color.TRANSPARENT,
                Color.rgb(72, 137, 255),
                Color.rgb(38, 239, 216),
                Color.TRANSPARENT,
            ),
            null,
        )
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = width * .055f
        paint.strokeCap = Paint.Cap.ROUND
        canvas.save()
        canvas.rotate(phase * 360f, cx, cy)
        canvas.drawArc(arcBounds, 25f, 285f, false, paint)
        canvas.restore()

        paint.shader = RadialGradient(
            cx - width * .08f,
            cy - width * .1f,
            width * .22f,
            Color.WHITE,
            Color.rgb(35, 180, 255),
            Shader.TileMode.CLAMP,
        )
        paint.style = Paint.Style.FILL
        canvas.drawCircle(cx, cy, width * (.125f + pulse * .015f), paint)
        paint.shader = null
    }
}

private class ListeningWaveView(context: Context) : AssistantAnimatedView(context, 1150L) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(46, 225, 214)
        strokeCap = Paint.Cap.ROUND
    }
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val barCount = 9
        val spacing = width / (barCount + 1f)
        paint.strokeWidth = spacing * .34f

        for (index in 0 until barCount) {
            val wave = (sin(phase * PI * 2 + index * .92).toFloat() + 1f) / 2f
            val barHeight = height * (.18f + wave * .62f)
            val x = spacing * (index + 1)
            canvas.drawLine(x, height / 2f - barHeight / 2f, x, height / 2f + barHeight / 2f, paint)
        }
    }
}

private class PulseDotView(context: Context) : AssistantAnimatedView(context, 900L, reverse = true) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        paint.color = Color.argb((130 + phase * 125).toInt(), 83, 230, 177)
        canvas.drawCircle(width / 2f, height / 2f, width * (.28f + phase * .18f), paint)
    }
}

/** Native animations stop with the window and honor Android reduced motion. */
private abstract class AssistantAnimatedView(context: Context, private val period: Long, private val reverse: Boolean = false) : View(context) {
    protected var phase = .5f
    private var animator: ValueAnimator? = null
    override fun onAttachedToWindow() { super.onAttachedToWindow(); if (windowVisibility == VISIBLE) startAnimation() }
    override fun onDetachedFromWindow() { stopAnimation(); super.onDetachedFromWindow() }
    override fun onWindowVisibilityChanged(visibility: Int) {
        super.onWindowVisibilityChanged(visibility)
        if (visibility == VISIBLE && isAttachedToWindow) startAnimation() else stopAnimation()
    }
    private fun startAnimation() {
        if (animator != null || (android.os.Build.VERSION.SDK_INT >= 26 && !ValueAnimator.areAnimatorsEnabled())) return
        animator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = period; repeatCount = ValueAnimator.INFINITE
            repeatMode = if (reverse) ValueAnimator.REVERSE else ValueAnimator.RESTART
            interpolator = LinearInterpolator()
            addUpdateListener { phase = it.animatedValue as Float; invalidate() }
            start()
        }
    }
    private fun stopAnimation() { animator?.cancel(); animator = null }
}
