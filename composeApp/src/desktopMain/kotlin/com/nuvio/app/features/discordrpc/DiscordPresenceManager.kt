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

/**
 * Fallback artwork for anything that has no poster of its own: the menu/tab screens, and titles
 * whose addon never returned an image.
 */
private const val NuvioIconUrl =
    "https://raw.githubusercontent.com/NuvioMedia/NuvioDesktop/Dev/composeApp/src/desktopMain/resources/icons/app-icon-graphite-transparent.png"

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

    /** Identity of the context the elapsed timer below is counting from. */
    private var presenceKey: String? = null
    private var presenceSinceSec = System.currentTimeMillis() / 1_000L

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
        DiscordRichPresenceRepository.swapNameAndTitle,
    ) { snapshot, showButtons, hideWhenPaused, showBrowsing, swapNameAndTitle ->
        // Restart the elapsed timer whenever the user actually moves somewhere else. The player
        // refreshes its snapshot every few seconds, so this keys on identity rather than equality.
        val key = snapshot?.presenceKey
        if (key != presenceKey) {
            presenceKey = key
            presenceSinceSec = System.currentTimeMillis() / 1_000L
        }
        snapshot.toDiscordActivity(
            showButtons = showButtons,
            hideWhenPaused = hideWhenPaused,
            showBrowsing = showBrowsing,
            swapNameAndTitle = swapNameAndTitle,
            browsingSinceSec = presenceSinceSec,
        )
    }
}

private fun PresenceSnapshot?.toDiscordActivity(
    showButtons: Boolean,
    hideWhenPaused: Boolean,
    showBrowsing: Boolean,
    swapNameAndTitle: Boolean,
    browsingSinceSec: Long,
): DiscordActivity? = when (this) {
    null -> browsingActivity(tab = null, query = null, showBrowsing = showBrowsing, sinceSec = browsingSinceSec)
    is PresenceSnapshot.Tab -> browsingActivity(
        tab = tab,
        query = searchQuery,
        showBrowsing = showBrowsing,
        sinceSec = browsingSinceSec,
    )

    is PresenceSnapshot.Details -> detailsActivity(showBrowsing = showBrowsing, sinceSec = browsingSinceSec)

    is PresenceSnapshot.Player -> toPlayerActivity(
        showButtons = showButtons,
        hideWhenPaused = hideWhenPaused,
        swapNameAndTitle = swapNameAndTitle,
    )
}

/**
 * Menu presence: the headline stays "Watching Nuvio" and the second line says what is actually
 * being done, matching the wording stremio-shell-ng uses for its own menu states.
 */
private fun browsingActivity(
    tab: AppScreenTab?,
    query: String?,
    showBrowsing: Boolean,
    sinceSec: Long,
): DiscordActivity? {
    if (!showBrowsing) return null

    val trimmedQuery = query?.trim().orEmpty()
    val (state, details) = when (tab) {
        AppScreenTab.Home -> "Home" to "Browsing"
        AppScreenTab.Search -> (if (trimmedQuery.isEmpty()) "Search" else trimmedQuery) to "Searching"
        AppScreenTab.Library -> "Library" to "Browsing library"
        AppScreenTab.Settings -> "Settings" to "Changing configuration"
        else -> "Nuvio" to "Browsing"
    }

    return DiscordActivity(
        type = DiscordActivityType.WATCHING,
        name = "Nuvio",
        details = details,
        state = state,
        timestamps = DiscordActivityTimestamps(start = sinceSec),
        assets = DiscordActivityAssets(largeImage = NuvioIconUrl, largeText = "Nuvio"),
    )
}

/**
 * Presence for a title's details page: the title leads the card and its poster becomes the
 * artwork, so Discord shows what is being looked at rather than the app logo.
 */
private fun PresenceSnapshot.Details.detailsActivity(
    showBrowsing: Boolean,
    sinceSec: Long,
): DiscordActivity? {
    if (!showBrowsing) return null

    val releaseYear = year?.trim()?.takeIf { it.isNotEmpty() }
    val largeText = if (releaseYear != null) "$title ($releaseYear)" else title

    return DiscordActivity(
        type = DiscordActivityType.WATCHING,
        name = title,
        details = "Viewing details",
        state = releaseYear,
        timestamps = DiscordActivityTimestamps(start = sinceSec),
        assets = DiscordActivityAssets(
            largeImage = posterUrl?.toDiscordImageUrl() ?: NuvioIconUrl,
            largeText = largeText,
        ),
    )
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

    // A paused player reports no timestamps at all, so Discord shows the word instead of an
    // elapsed counter that would otherwise keep climbing while the video is not moving.
    if (!isPlaying) {
        stateText = if (stateText.isNullOrBlank()) "Paused" else "$stateText \u2022 Paused"
    }

    val largeText = if (releaseYear != null) "$title ($releaseYear)" else title

    return DiscordActivity(
        type = DiscordActivityType.WATCHING,
        name = activityName,
        details = details,
        state = stateText,
        // Discord renders a live progress bar when both bounds are present, and counts elapsed
        // time when only `start` is. A paused player gets neither.
        timestamps = if (isPlaying) playbackTimestamps() else null,
        assets = DiscordActivityAssets(
            largeImage = posterUrl?.toDiscordImageUrl() ?: NuvioIconUrl,
            largeText = largeText,
        ),
        buttons = if (showButtons) buildButtons(metaId) else null,
    )
}

private fun PresenceSnapshot.Player.playbackTimestamps(): DiscordActivityTimestamps {
    val nowMs = System.currentTimeMillis()
    val position = positionMs.coerceAtLeast(0L)
    val start = (nowMs - position) / 1_000L
    val end = if (durationMs > position) (nowMs + (durationMs - position)) / 1_000L else null
    return DiscordActivityTimestamps(start = start, end = end)
}

/** One button only: IMDb for IMDb ids, Kitsu for Kitsu ids. Nothing when the id is unknown. */
private fun buildButtons(metaId: String?): List<DiscordActivityButton>? {
    val id = metaId?.trim().orEmpty()
    return when {
        id.startsWith("tt") && id.length > 2 && id.drop(2).all(Char::isDigit) -> {
            listOf(DiscordActivityButton("View on IMDb", "https://www.imdb.com/title/$id/"))
        }

        id.startsWith("kitsu:") -> {
            id.removePrefix("kitsu:").substringBefore(':').takeIf { it.isNotBlank() }?.let { slug ->
                listOf(DiscordActivityButton("View on Kitsu", "https://kitsu.app/anime/$slug"))
            }
        }

        else -> null
    }
}

private fun String.toDiscordImageUrl(): String? {
    val trimmed = trim()
    if (!trimmed.startsWith("http://") && !trimmed.startsWith("https://")) return null
    val withoutScheme = trimmed.substringAfter("://")
    if (withoutScheme.isBlank()) return null
    val encoded = URLEncoder.encode(withoutScheme, StandardCharsets.UTF_8.name()).replace("+", "%20")
    return ImageProxyTemplate.format(encoded)
}
