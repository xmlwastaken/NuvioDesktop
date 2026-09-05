package com.nuvio.app.features.discordrpc

import co.touchlab.kermit.Logger
import com.nuvio.app.AppScreenTab
import com.nuvio.app.core.ui.AppPresenceState
import com.nuvio.app.core.ui.PresenceSnapshot
import com.nuvio.app.features.settings.DiscordRichPresenceRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import java.net.URLEncoder
import java.nio.charset.StandardCharsets

private class DiscordDisconnected : Exception()

private const val ReconnectDelayMs = 15_000L

private const val NuvioSiteUrl = "https://nuvio-tv.com/"

/** Badge overlaid on the poster. Same paused glyph stremio-shell-ng uses. */
private const val PausedIconUrl = "https://i.imgur.com/eCUJpm9.png"
private const val NuvioIconUrl =
    "https://raw.githubusercontent.com/NuvioMedia/NuvioDesktop/Dev/composeApp/src/desktopMain/resources/icons/nuvio-app-icon-transparent.png"

/**
 * Posters are arbitrary remote images of arbitrary aspect ratio. Discord crops whatever it is
 * given into a square, which decapitates a 2:3 poster. Routing through the weserv image proxy
 * with `fit=contain` letterboxes the poster into a 1024x1024 canvas so the whole artwork survives.
 */
private const val ImageProxyTemplate =
    "https://images.weserv.nl/?url=%s&w=1024&h=1024&fit=contain&cbg=black&output=png"

internal object DiscordPresenceManager {
    private val log = Logger.withTag("DiscordPresenceManager")
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val client = DiscordIpcClient(DiscordConfig.CLIENT_ID)
    private var syncJob: Job? = null
    private var lastActivity: DiscordActivity? = null

    fun start() {
        if (DiscordConfig.CLIENT_ID.isBlank()) return
        DiscordRichPresenceRepository.ensureLoaded()
        scope.launch {
            DiscordRichPresenceRepository.enabled.collectLatest { enabled ->
                if (enabled) startSync() else stopSync()
            }
        }
    }

    fun shutdown() {
        runBlocking { stopSync() }
    }

    private suspend fun startSync() {
        syncJob?.cancel()
        syncJob = scope.launch {
            while (isActive) {
                val connected = client.connect()
                if (connected) {
                    lastActivity = null
                    var hasPushed = false
                    try {
                        activityFlow().collect { activity ->
                            // Skip redundant frames: Discord rate-limits SET_ACTIVITY.
                            val unchanged = if (activity == null) {
                                lastActivity == null
                            } else {
                                activity.isEquivalentTo(lastActivity)
                            }
                            if (hasPushed && unchanged) return@collect
                            if (client.setActivity(activity)) {
                                lastActivity = activity
                                hasPushed = true
                            } else {
                                throw DiscordDisconnected()
                            }
                        }
                    } catch (e: DiscordDisconnected) {
                        log.d { "Discord IPC disconnected, retrying" }
                    }
                }
                delay(ReconnectDelayMs)
            }
        }
    }

    private suspend fun stopSync() {
        syncJob?.cancel()
        syncJob = null
        if (lastActivity != null) client.setActivity(null)
        delay(300L)
        lastActivity = null
        client.disconnect()
    }

    /** The app's presence, folded together with the user's Rich Presence preferences. */
    private fun activityFlow(): Flow<DiscordActivity?> = combine(
        AppPresenceState.current,
        DiscordRichPresenceRepository.showButtons,
        DiscordRichPresenceRepository.hideWhenPaused,
        DiscordRichPresenceRepository.showBrowsing,
        combine(
            DiscordRichPresenceRepository.showSmallImage,
            DiscordRichPresenceRepository.swapNameAndTitle,
        ) { showSmallImage, swapNameAndTitle -> showSmallImage to swapNameAndTitle },
    ) { snapshot, showButtons, hideWhenPaused, showBrowsing, (showSmallImage, swapNameAndTitle) ->
        snapshot.toDiscordActivity(
            showButtons = showButtons,
            hideWhenPaused = hideWhenPaused,
            showBrowsing = showBrowsing,
            showSmallImage = showSmallImage,
            swapNameAndTitle = swapNameAndTitle,
        )
    }
}

private fun PresenceSnapshot?.toDiscordActivity(
    showButtons: Boolean,
    hideWhenPaused: Boolean,
    showBrowsing: Boolean,
    showSmallImage: Boolean,
    swapNameAndTitle: Boolean,
): DiscordActivity? = when (this) {
    null -> browsingActivity(state = null, showBrowsing = showBrowsing)
    is PresenceSnapshot.Tab -> browsingActivity(state = tab.presenceLabel(), showBrowsing = showBrowsing)
    is PresenceSnapshot.Details -> if (showBrowsing) {
        DiscordActivity(
            type = DiscordActivityType.WATCHING,
            name = title,
            details = title,
            state = "Viewing details",
            assets = DiscordActivityAssets(largeImage = NuvioIconUrl, largeText = title),
        )
    } else {
        null
    }

    is PresenceSnapshot.Player -> toPlayerActivity(
        showButtons = showButtons,
        hideWhenPaused = hideWhenPaused,
        showSmallImage = showSmallImage,
        swapNameAndTitle = swapNameAndTitle,
    )
}

private fun browsingActivity(state: String?, showBrowsing: Boolean): DiscordActivity? =
    if (showBrowsing) {
        DiscordActivity(
            type = DiscordActivityType.WATCHING,
            name = "Nuvio",
            details = "Browsing Nuvio",
            state = state,
            assets = DiscordActivityAssets(largeImage = NuvioIconUrl, largeText = "Nuvio"),
        )
    } else {
        null
    }

/**
 * Mirrors the card layout stremio-shell-ng produces.
 *
 * Series: name = show title, details = episode title, state = "S3E9".
 * Movie:  name = details = title, state = release year.
 *
 * `swapNameAndTitle` exchanges the headline and the second line, matching that project's
 * `swap_name_and_title` option.
 */
private fun PresenceSnapshot.Player.toPlayerActivity(
    showButtons: Boolean,
    hideWhenPaused: Boolean,
    showSmallImage: Boolean,
    swapNameAndTitle: Boolean,
): DiscordActivity? {
    if (!isPlaying && hideWhenPaused) return null

    val releaseYear = year?.trim()?.takeIf { it.isNotEmpty() }
    val episode = episodeTitle?.trim()?.takeIf { it.isNotEmpty() }

    var activityName = title
    var details = if (isSeries) episode ?: title else title
    var stateText = if (isSeries) "S${seasonNumber}E${episodeNumber}" else releaseYear

    if (swapNameAndTitle) {
        val previousName = activityName
        activityName = details
        details = previousName
    }

    // With the badge off there is nothing to signal a pause, so fall back to saying it.
    if (!isPlaying && !showSmallImage) {
        stateText = if (stateText.isNullOrBlank()) "Paused" else "$stateText \u2022 Paused"
    }

    val largeText = if (releaseYear != null) "$title ($releaseYear)" else title

    return DiscordActivity(
        type = DiscordActivityType.WATCHING,
        name = activityName,
        details = details,
        state = stateText,
        // Discord renders a live progress bar when both bounds are present, and counts elapsed
        // time when only `start` is. A paused player gets neither, so the bar freezes out of
        // the card instead of racing ahead of the actual playhead.
        timestamps = if (isPlaying) playbackTimestamps() else null,
        assets = DiscordActivityAssets(
            largeImage = posterUrl?.toDiscordImageUrl() ?: NuvioIconUrl,
            largeText = largeText,
            smallImage = if (showSmallImage) {
                if (isPlaying) NuvioIconUrl else PausedIconUrl
            } else {
                null
            },
            smallText = if (showSmallImage) {
                if (isPlaying) "Playing" else "Paused"
            } else {
                null
            },
        ),
        buttons = if (showButtons) buildButtons(metaId, metaType) else null,
    )
}

private fun PresenceSnapshot.Player.playbackTimestamps(): DiscordActivityTimestamps {
    val nowMs = System.currentTimeMillis()
    val position = positionMs.coerceAtLeast(0L)
    val start = (nowMs - position) / 1_000L
    val end = if (durationMs > position) (nowMs + (durationMs - position)) / 1_000L else null
    return DiscordActivityTimestamps(start = start, end = end)
}

/** Discord allows at most two buttons per activity. */
private fun buildButtons(metaId: String?, metaType: String?): List<DiscordActivityButton>? {
    val buttons = mutableListOf<DiscordActivityButton>()
    val id = metaId?.trim().orEmpty()
    val externalId = id.substringBefore(':', missingDelimiterValue = id)

    when {
        id.startsWith("tt") && id.length > 2 && id.drop(2).all(Char::isDigit) -> {
            buttons += DiscordActivityButton("View on IMDb", "https://www.imdb.com/title/$id/")
        }

        id.startsWith("kitsu:") -> {
            id.removePrefix("kitsu:").substringBefore(':').takeIf { it.isNotBlank() }?.let { slug ->
                buttons += DiscordActivityButton("View on Kitsu", "https://kitsu.app/anime/$slug")
            }
        }

        externalId == "tmdb" -> {
            id.removePrefix("tmdb:").substringBefore(':').takeIf { it.isNotBlank() }?.let { slug ->
                val kind = if (metaType == "series") "tv" else "movie"
                buttons += DiscordActivityButton("View on TMDB", "https://www.themoviedb.org/$kind/$slug")
            }
        }
    }

    buttons += DiscordActivityButton("Get Nuvio", NuvioSiteUrl)
    return buttons.take(2).takeIf { it.isNotEmpty() }
}

private fun String.toDiscordImageUrl(): String? {
    val trimmed = trim()
    if (!trimmed.startsWith("http://") && !trimmed.startsWith("https://")) return null
    val withoutScheme = trimmed.substringAfter("://")
    if (withoutScheme.isBlank()) return null
    val encoded = URLEncoder.encode(withoutScheme, StandardCharsets.UTF_8.name()).replace("+", "%20")
    return ImageProxyTemplate.format(encoded)
}

private fun AppScreenTab.presenceLabel(): String = when (this) {
    AppScreenTab.Home -> "Home"
    AppScreenTab.Search -> "Searching"
    AppScreenTab.Library -> "Library"
    AppScreenTab.Settings -> "Settings"
}
