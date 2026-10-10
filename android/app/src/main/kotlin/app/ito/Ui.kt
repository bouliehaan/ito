package app.ito

import android.content.Context
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView

/**
 * The samo-server console, on a phone: neutral black → grey → white, one mono
 * face (Office Code Pro), hard corners, white as the only accent, `//` section
 * heads. No AndroidX, no Compose; the phone screen is a status panel you look
 * at twice.
 */
object Ui {
    const val BG = 0xFF000000.toInt()
    const val SURFACE = 0xFF151515.toInt()
    const val LINE = 0x14FFFFFF
    const val LINE_STRONG = 0x26FFFFFF
    const val TEXT = 0xFFF2F2F2.toInt()
    const val DIM = 0xFF9E9E9E.toInt()
    const val MUTED = 0xFF6A6A6A.toInt()
    const val DANGER = 0xFFCF6F6F.toInt()

    private var regular: Typeface? = null
    private var bold: Typeface? = null

    fun face(ctx: Context, isBold: Boolean = false): Typeface {
        if (regular == null) {
            regular = ctx.resources.getFont(R.font.officecodepro_regular)
            bold = ctx.resources.getFont(R.font.officecodepro_bold)
        }
        return if (isBold) bold!! else regular!!
    }

    fun dp(ctx: Context, v: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, ctx.resources.displayMetrics).toInt()

    fun text(ctx: Context, s: String, size: Float = 16f, color: Int = TEXT, isBold: Boolean = false) = TextView(ctx).apply {
        text = s
        typeface = face(ctx, isBold)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, size)
        setTextColor(color)
        setLineSpacing(0f, 1.25f)
    }

    /** Small tracked caps. Never used for the wordmark: ito is always lowercase. */
    fun label(ctx: Context, s: String) = text(ctx, s.uppercase(), 12.5f, MUTED).apply { letterSpacing = 0.14f }

    fun section(ctx: Context, s: String) = text(ctx, "// $s", 13.5f, DIM).apply {
        letterSpacing = 0.06f
        setPadding(0, dp(ctx, 30f), 0, dp(ctx, 10f))
    }

    fun row(ctx: Context, key: String, value: String, valueColor: Int = TEXT) = LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL
        setPadding(0, dp(ctx, 7f), 0, dp(ctx, 7f))
        // Wide enough for "WI-FI CALLING" in tracked caps, plus a gap before the value.
        addView(label(ctx, key).apply {
            minWidth = dp(ctx, 150f)
            setPadding(0, 0, dp(ctx, 12f), 0)
            gravity = Gravity.CENTER_VERTICAL
        })
        addView(text(ctx, value, 16f, valueColor), LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
    }

    fun button(ctx: Context, s: String, primary: Boolean = false, danger: Boolean = false, onClick: () -> Unit) =
        text(ctx, s.uppercase(), 14f, if (primary) BG else if (danger) DANGER else TEXT, isBold = true).apply {
            letterSpacing = 0.12f
            gravity = Gravity.CENTER
            setPadding(dp(ctx, 20f), dp(ctx, 14f), dp(ctx, 20f), dp(ctx, 14f))
            background = GradientDrawable().apply {
                cornerRadius = 0f
                setColor(if (primary) TEXT else BG)
                setStroke(dp(ctx, 1f), if (primary) TEXT else if (danger) DANGER else LINE_STRONG)
            }
            isClickable = true
            setOnClickListener { onClick() }
        }

    fun hairline(ctx: Context) = View(ctx).apply {
        setBackgroundColor(LINE)
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(ctx, 1f))
    }

    fun card(ctx: Context) = LinearLayout(ctx).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(ctx, 20f), dp(ctx, 20f), dp(ctx, 20f), dp(ctx, 20f))
        background = GradientDrawable().apply {
            cornerRadius = 0f
            setColor(SURFACE)
            setStroke(dp(ctx, 1f), LINE)
        }
    }
}
