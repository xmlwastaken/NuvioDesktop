package com.nuvio.app.features.discordrpc

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Discord activity types. Only the ones we can meaningfully emit over RPC are listed.
 * Type 3 ("Watching") makes the Discord client render "Watching Nuvio" instead of
 * "Playing Nuvio", which is what a media player should be reporting.
 */
internal object DiscordActivityType {
    const val PLAYING = 0
    const val WATCHING = 3
}

@Serializable
internal data class DiscordActivity(
    val type: Int? = null,
    /**
     * Overrides the headline of the presence card. Without it Discord falls back to the
     * registered application name ("Nuvio"), which is not what a media player wants to say —
     * we put the series/movie title here so the card reads "Watching Game of Thrones".
     */
    val name: String? = null,
    val details: String? = null,
    val state: String? = null,
    val timestamps: DiscordActivityTimestamps? = null,
    val assets: DiscordActivityAssets? = null,
    val buttons: List<DiscordActivityButton>? = null,
) {
    /**
     * Discord rate-limits SET_ACTIVITY (roughly 5 updates per 20 seconds), so we only push a
     * frame when something the user can actually see has changed.
     *
     * Timestamps are derived from the wall clock (`now - position`), so during uninterrupted
     * playback they are nominally constant but can jitter by a second from integer rounding.
     * Treating a <= [TIMESTAMP_TOLERANCE_SECONDS] drift as "unchanged" keeps that jitter from
     * burning the rate-limit budget, while a real seek still gets through immediately.
     */
    fun isEquivalentTo(other: DiscordActivity?): Boolean {
        if (other == null) return false
        if (type != other.type) return false
        if (name != other.name) return false
        if (details != other.details) return false
        if (state != other.state) return false
        if (assets != other.assets) return false
        if (buttons != other.buttons) return false
        return timestamps.isEquivalentTo(other.timestamps)
    }
}

private const val TimestampToleranceSeconds = 2L

private fun DiscordActivityTimestamps?.isEquivalentTo(other: DiscordActivityTimestamps?): Boolean {
    if (this == null || other == null) return this == other
    return start.isCloseTo(other.start) && end.isCloseTo(other.end)
}

private fun Long?.isCloseTo(other: Long?): Boolean = when {
    this == null || other == null -> this == other
    else -> kotlin.math.abs(this - other) <= TimestampToleranceSeconds
}

@Serializable
internal data class DiscordActivityTimestamps(
    val start: Long? = null,
    val end: Long? = null,
)

@Serializable
internal data class DiscordActivityAssets(
    @SerialName("large_image") val largeImage: String? = null,
    @SerialName("large_text") val largeText: String? = null,
    @SerialName("small_image") val smallImage: String? = null,
    @SerialName("small_text") val smallText: String? = null,
)

@Serializable
internal data class DiscordActivityButton(
    val label: String,
    val url: String,
)
