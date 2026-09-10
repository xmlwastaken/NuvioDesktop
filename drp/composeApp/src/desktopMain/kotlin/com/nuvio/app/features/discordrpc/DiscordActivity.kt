package com.nuvio.app.features.discordrpc

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Discord activity types this app emits. The type is what picks the verb on the first line of
 * the card - there is no "Browsing" or "Viewing" type, so menus have to borrow one:
 *
 *   PLAYING  (0) -> "Playing Nuvio"    used while browsing, where nothing is being watched
 *   WATCHING (3) -> "Watching <title>" used only during actual playback
 */
internal object DiscordActivityTypes {
    const val PLAYING = 0
    const val WATCHING = 3
}

@Serializable
internal data class DiscordActivity(
    // Discord activity type: 0 = Playing, 2 = Listening, 3 = Watching, 5 = Competing.
    // Sending 3 makes Discord show "Watching â€¦" instead of the default "Playing â€¦".
    val type: Int = 0,
    // Top line rendered under the username ("<verb> <name>"). When omitted, Discord uses the
    // name of the application registered to the client id ("Nuvio"). Recent Discord clients honor
    // a custom name here so the media title shows directly under the pseudo; older clients ignore
    // it and fall back to the app name (that is why the title is also kept in `details`).
    val name: String? = null,
    val details: String? = null,
    val state: String? = null,
    val timestamps: DiscordActivityTimestamps? = null,
    val assets: DiscordActivityAssets? = null,
    val buttons: List<DiscordActivityButton>? = null,
) {
    /**
     * Discord rate-limits SET_ACTIVITY, so only push a frame when something the user can see has
     * actually changed. Timestamps are derived from the wall clock, so during uninterrupted
     * playback they stay nominally constant but drift by a second whenever the seconds roll over.
     * Treating a drift of at most [TimestampToleranceSeconds] as unchanged keeps that jitter from
     * burning the rate-limit budget, while a real seek still gets through straight away.
     */
    fun isEquivalentTo(other: DiscordActivity?): Boolean {
        if (other == null) return false
        return type == other.type &&
            name == other.name &&
            details == other.details &&
            state == other.state &&
            assets == other.assets &&
            buttons == other.buttons &&
            timestamps.isEquivalentTo(other.timestamps)
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
internal data class DiscordActivityButton(
    val label: String,
    val url: String,
)

@Serializable
internal data class DiscordActivityTimestamps(
    val start: Long? = null,
    // When both start and end are set, Discord renders a live progress bar with time remaining.
    val end: Long? = null,
)

@Serializable
internal data class DiscordActivityAssets(
    @SerialName("large_image") val largeImage: String? = null,
    @SerialName("large_text") val largeText: String? = null,
)
