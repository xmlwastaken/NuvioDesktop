package com.nuvio.app.features.discordrpc

import co.touchlab.kermit.Logger
import com.nuvio.app.core.ui.AppPresenceState
import com.nuvio.app.core.ui.PresenceSnapshot
import com.nuvio.app.features.settings.DiscordRichPresenceRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import java.net.URLEncoder
import java.nio.charset.StandardCharsets

private class DiscordDisconnected : Exception()

private const val ReconnectDelayMs = 15_000L

/**
 * Fallback artwork for a title whose addon never returned a poster.
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
                    try {
                        AppPresenceState.current.collect { snapshot ->
                            val activity = snapshot.toDiscordActivity()
                            if (activity == null) {
                                // Not watching anything: clear the card once, then stay quiet.
                                if (lastActivity == null) return@collect
                            } else if (activity.isEquivalentTo(lastActivity)) {
                                // The player re-publishes every few seconds; only push real changes.
                                return@collect
                            }
                            if (client.setActivity(activity)) {
                                lastActivity = activity
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
}

/**
 * Presence is reported for playback only. Home, Search, Library, Settings and title details
 * pages all clear the card rather than showing a browsing status.
 */
private fun PresenceSnapshot?.toDiscordActivity(): DiscordActivity? =
    (this as? PresenceSnapshot.Player)?.buildActivity()

/**
 * Mirrors the card layout stremio-shell-ng produces.
 *
 * Series: name = show title, details = episode title, state = "S3E9".
 * Movie:  name = details = title, no state line.
 */
private fun PresenceSnapshot.Player.buildActivity(): DiscordActivity {
    // The player hands over the season/episode numbers directly. If it ever stops doing that -
    // the player UI is the file upstream rewrites most often - fall back to reading the label
    // it has always carried, so the card still shows "S3E9" and the episode title.
    val hasEpisodeNumbers = seasonNumber != null && episodeNumber != null
    val parsedLabel = if (hasEpisodeNumbers) null else episodeLabel?.parseEpisodeLabel()

    val episodeCode = if (hasEpisodeNumbers) "S${seasonNumber}E${episodeNumber}" else parsedLabel?.code
    val episodeName = episodeTitle?.trim()?.takeIf { it.isNotEmpty() }
        ?: parsedLabel?.episodeTitle?.takeIf { it.isNotEmpty() }

    // Series put the episode title here; a movie repeats its own title.
    val details = if (episodeCode != null) episodeName ?: title else title
    var stateText = episodeCode

    // A paused player reports no timestamps at all, so Discord shows the word instead of an
    // elapsed counter that would otherwise keep climbing while the video is not moving.
    if (!isPlaying) {
        stateText = if (stateText.isNullOrBlank()) "Paused" else "$stateText \u2022 Paused"
    }

    return DiscordActivity(
        type = DiscordActivityTypes.WATCHING,
        name = title,
        details = details,
        state = stateText,
        // start + end draws a live progress bar with the time remaining. A paused player gets
        // neither bound.
        timestamps = if (isPlaying) playbackTimestamps() else null,
        assets = DiscordActivityAssets(
            largeImage = posterUrl?.toDiscordImageUrl() ?: NuvioIconUrl,
            largeText = title,
        ),
        buttons = buildButtons(metaId),
    )
}

private fun PresenceSnapshot.Player.playbackTimestamps(): DiscordActivityTimestamps {
    val nowMs = System.currentTimeMillis()
    val position = positionMs.coerceAtLeast(0L)
    val startSecs = (nowMs - position) / 1_000L
    // Discord expects Unix seconds, and only draws a progress bar when both bounds are present.
    val endSecs = if (durationMs > position) (nowMs + (durationMs - position)) / 1_000L else null
    return DiscordActivityTimestamps(start = startSecs, end = endSecs)
}

private data class EpisodeLabel(val code: String, val episodeTitle: String?)

/** Matches the labels the player builds for episodes: `S3E9` and `S3E9 - Episode Title`. */
private fun String.parseEpisodeLabel(): EpisodeLabel? {
    val match = Regex("""S(\d+)E(\d+)(?:\s*-\s*(.*))?""").matchEntire(trim()) ?: return null
    return EpisodeLabel(
        code = "S${match.groupValues[1]}E${match.groupValues[2]}",
        episodeTitle = match.groupValues[3].trim().takeIf { it.isNotEmpty() },
    )
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
