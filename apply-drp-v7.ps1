# =====================================================================
#  Nuvio Discord Rich Presence - v7   <= USE THIS ONE
#
#  WHY v7, AND WHY THE OLD BUILDS KEPT BREAKING
#
#  Old versions shipped a frozen COPY of PlayerScreenRuntimeUi.kt. That is
#  the one file upstream rewrites most often, so the moment they touched it
#  our copy stopped compiling. That is exactly the error you just hit:
#      No value passed for parameter 'playbackGesturesEnabled'
#
#  v7 stops shipping that file. Instead:
#    * 4 files that belong to us alone are copied over wholesale
#    * the player UI is touched by ONE OPTIONAL patch
#    * if that patch no longer matches, the build SKIPS it and carries on
#
#  So an upstream change to the player can never break the build again.
#  Worst case the card loses two extras (see the guide) - it still builds.
#
#  1. Save this into  C:\Users\XML\NuvioDesktop\apply-drp-v7.ps1
#  2. Open PowerShell and run:
#         cd C:\Users\XML\NuvioDesktop
#         powershell -ExecutionPolicy Bypass -File .\apply-drp-v7.ps1
#  3. When it says PUSHED, open GitHub -> Actions ->
#     "Update from upstream and build" -> Run workflow (branch Dev)
# =====================================================================

$ErrorActionPreference = "Continue"
$repo = "C:\Users\XML\NuvioDesktop"

if (-not (Test-Path (Join-Path $repo ".git"))) {
    Write-Host "ERROR: no git repository found at $repo" -ForegroundColor Red
    Write-Host "Fix `$repo at the top of this script if your clone lives elsewhere." -ForegroundColor Red
    exit 1
}

$enc = New-Object System.Text.UTF8Encoding($false)

function Write-RepoFile($relPath, $content) {
    $full = Join-Path $repo $relPath
    $dir = Split-Path $full
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    [System.IO.File]::WriteAllText($full, $content, $enc)
    Write-Host ("  updated  " + $relPath) -ForegroundColor Green
}

# --- wipe the old overlay so nothing stale survives -------------------
$drp = Join-Path $repo "drp"
if (Test-Path $drp) {
    Write-Host "Removing the old drp/ folder so no stale files are left behind ..." -ForegroundColor Yellow
    Remove-Item $drp -Recurse -Force
    Write-Host "  removed  drp\" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Writing the Rich Presence files and the updater workflow ..." -ForegroundColor Cyan
Write-Host ""
Write-RepoFile "drp\composeApp\src\commonMain\kotlin\com\nuvio\app\core\ui\AppPresenceState.kt" @'
package com.nuvio.app.core.ui

import com.nuvio.app.AppScreenTab
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

internal object AppPresenceState {
    private val _current = MutableStateFlow<PresenceSnapshot?>(null)
    val current: StateFlow<PresenceSnapshot?> = _current.asStateFlow()

    fun publish(snapshot: PresenceSnapshot?) {
        _current.value = snapshot
    }
}

internal sealed interface PresenceSnapshot {
    data class Tab(val tab: AppScreenTab) : PresenceSnapshot

    data class Details(val title: String) : PresenceSnapshot

    data class Player(
        val title: String,
        val episodeLabel: String?,
        val posterUrl: String?,
        val isPlaying: Boolean,
        val positionMs: Long,
        val durationMs: Long,
        // Everything below is extra detail the player passes along when it knows it. All of it
        // defaults to null on purpose: if the player stops passing these - it is the file
        // upstream rewrites most often - the build still compiles and presence still works, the
        // manager just falls back to reading `episodeLabel` and drops the detail buttons.
        val seasonNumber: Int? = null,
        val episodeNumber: Int? = null,
        val episodeTitle: String? = null,
        /** Stremio-style catalogue id of the parent item, e.g. `tt0944947` or `kitsu:12345`. */
        val metaId: String? = null,
        /** `movie` or `series`. */
        val metaType: String? = null,
    ) : PresenceSnapshot
}

'@

Write-RepoFile "drp\composeApp\src\desktopMain\kotlin\com\nuvio\app\features\discordrpc\DiscordActivity.kt" @'
package com.nuvio.app.features.discordrpc

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Discord activity types this app emits. 3 ("Watching") makes the client render
 * "Watching <title>" instead of "Playing Nuvio", which is what a media player should report.
 */
internal object DiscordActivityTypes {
    const val WATCHING = 3
}

@Serializable
internal data class DiscordActivity(
    // Discord activity type: 0 = Playing, 2 = Listening, 3 = Watching, 5 = Competing.
    // Sending 3 makes Discord show "Watching …" instead of the default "Playing …".
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

'@

Write-RepoFile "drp\composeApp\src\desktopMain\kotlin\com\nuvio\app\features\discordrpc\DiscordIpcClient.kt" @'
package com.nuvio.app.features.discordrpc

import co.touchlab.kermit.Logger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerialName
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.putJsonObject
import java.io.Closeable
import java.io.EOFException
import java.io.RandomAccessFile
import java.net.StandardProtocolFamily
import java.net.UnixDomainSocketAddress
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.SocketChannel
import java.nio.file.Files
import java.nio.file.Path
import java.util.Locale
import java.util.UUID

private const val OpcodeHandshake = 0
private const val OpcodeFrame = 1

/**
 * `explicitNulls = false` so that unset activity fields (buttons, end timestamp, ...) are
 * omitted from the payload rather than serialized as `null`. Discord's activity validator
 * rejects some explicitly-null fields - notably `buttons` - which would make every
 * SET_ACTIVITY fail and the presence never appear. The clear-presence case is encoded by
 * hand below so it still sends a real `"activity": null`.
 */
private val discordIpcJson = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
}

@Serializable
private data class HandshakePayload(
    val v: Int = 1,
    @SerialName("client_id") val clientId: String,
)

private fun buildSetActivityCommand(pid: Int, nonce: String, activity: DiscordActivity?): String {
    val payload = buildJsonObject {
        put("cmd", JsonPrimitive("SET_ACTIVITY"))
        put("nonce", JsonPrimitive(nonce))
        putJsonObject("args") {
            put("pid", JsonPrimitive(pid))
            // Clearing presence needs an explicit null, not an omitted key.
            put("activity", activity?.let { discordIpcJson.encodeToJsonElement(it) } ?: JsonNull)
        }
    }
    return discordIpcJson.encodeToString(JsonObject.serializer(), payload)
}

private interface DiscordPipe : Closeable {
    fun write(bytes: ByteArray)
    fun readFully(buffer: ByteArray)
}

private class WindowsNamedPipe(private val file: RandomAccessFile) : DiscordPipe {
    override fun write(bytes: ByteArray) = file.write(bytes)
    override fun readFully(buffer: ByteArray) = file.readFully(buffer)
    override fun close() = file.close()
}

private class UnixSocketPipe(private val channel: SocketChannel) : DiscordPipe {
    override fun write(bytes: ByteArray) {
        val buffer = ByteBuffer.wrap(bytes)
        while (buffer.hasRemaining()) channel.write(buffer)
    }

    override fun readFully(buffer: ByteArray) {
        val target = ByteBuffer.wrap(buffer)
        while (target.hasRemaining()) {
            if (channel.read(target) < 0) throw EOFException("discord ipc socket closed")
        }
    }

    override fun close() = channel.close()
}

private fun openWindowsPipe(): DiscordPipe? {
    for (i in 0..9) {
        val file = runCatching { RandomAccessFile("\\\\.\\pipe\\discord-ipc-$i", "rw") }.getOrNull()
        if (file != null) return WindowsNamedPipe(file)
    }
    return null
}

private fun openUnixSocket(): DiscordPipe? {
    val candidateDirs = listOfNotNull(
        System.getenv("XDG_RUNTIME_DIR"),
        System.getenv("TMPDIR"),
        "/tmp",
        "/var/run",
    )
    for (dir in candidateDirs) {
        for (i in 0..9) {
            val path = Path.of(dir, "discord-ipc-$i")
            if (!Files.exists(path)) continue
            val channel = runCatching {
                SocketChannel.open(StandardProtocolFamily.UNIX).apply {
                    connect(UnixDomainSocketAddress.of(path))
                }
            }.getOrNull()
            if (channel != null) return UnixSocketPipe(channel)
        }
    }
    return null
}

private fun openTransport(): DiscordPipe? {
    val osName = System.getProperty("os.name").orEmpty().lowercase(Locale.ROOT)
    return if (osName.contains("win")) openWindowsPipe() else openUnixSocket()
}

private fun writeFrame(pipe: DiscordPipe, opcode: Int, payload: String) {
    val payloadBytes = payload.toByteArray(Charsets.UTF_8)
    val header = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN)
    header.putInt(opcode)
    header.putInt(payloadBytes.size)
    pipe.write(header.array())
    pipe.write(payloadBytes)
}

private fun readFrame(pipe: DiscordPipe): Pair<Int, String> {
    val headerBytes = ByteArray(8)
    pipe.readFully(headerBytes)
    val header = ByteBuffer.wrap(headerBytes).order(ByteOrder.LITTLE_ENDIAN)
    val opcode = header.int
    val length = header.int
    require(length in 0..1_048_576) { "unreasonable discord ipc frame length: $length" }
    val payloadBytes = ByteArray(length)
    if (length > 0) pipe.readFully(payloadBytes)
    return opcode to payloadBytes.toString(Charsets.UTF_8)
}

internal class DiscordIpcClient(private val clientId: String) {
    private val log = Logger.withTag("DiscordIpcClient")
    private val pid = ProcessHandle.current().pid().toInt()
    private var pipe: DiscordPipe? = null

    suspend fun connect(): Boolean = withContext(Dispatchers.IO) {
        if (pipe != null) return@withContext true
        val opened = openTransport() ?: return@withContext false
        try {
            writeFrame(opened, OpcodeHandshake, discordIpcJson.encodeToString(HandshakePayload(clientId = clientId)))
            val (opcode, payload) = readFrame(opened)
            val evt = discordIpcJson.parseToJsonElement(payload).jsonObject["evt"]?.jsonPrimitive?.contentOrNull
            check(opcode == OpcodeFrame && evt == "READY") { "unexpected handshake response: opcode=$opcode evt=$evt" }
            pipe = opened
            true
        } catch (e: CancellationException) {
            runCatching { opened.close() }
            throw e
        } catch (e: Exception) {
            log.d { "handshake failed: ${e.message}" }
            runCatching { opened.close() }
            false
        }
    }

    suspend fun setActivity(activity: DiscordActivity?): Boolean = withContext(Dispatchers.IO) {
        val currentPipe = pipe ?: return@withContext false
        try {
            val nonce = UUID.randomUUID().toString()
            val encodedCommand = buildSetActivityCommand(pid = pid, nonce = nonce, activity = activity)
            writeFrame(currentPipe, OpcodeFrame, encodedCommand)
            val (responseOpcode, responsePayload) = readFrame(currentPipe)
            val response = discordIpcJson.parseToJsonElement(responsePayload).jsonObject
            val responseCommand = response["cmd"]?.jsonPrimitive?.contentOrNull
            val responseEvent = response["evt"]?.jsonPrimitive?.contentOrNull
            val responseNonce = response["nonce"]?.jsonPrimitive?.contentOrNull
            check(responseOpcode == OpcodeFrame) { "unexpected Discord response opcode=$responseOpcode" }
            check(responseCommand == "SET_ACTIVITY" && responseNonce == nonce) {
                "unexpected Discord response cmd=$responseCommand evt=$responseEvent nonce=$responseNonce"
            }
            true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            log.d { "setActivity failed: ${e.message}" }
            disconnect()
            false
        }
    }

    suspend fun disconnect() = withContext(Dispatchers.IO) {
        runCatching { pipe?.close() }
        pipe = null
    }
}

'@

Write-RepoFile "drp\composeApp\src\desktopMain\kotlin\com\nuvio\app\features\discordrpc\DiscordPresenceManager.kt" @'
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

'@

Write-RepoFile "drp\patches\PlayerScreenRuntimeUi.patch" @'
--- a/composeApp/src/commonMain/kotlin/com/nuvio/app/features/player/PlayerScreenRuntimeUi.kt
+++ b/composeApp/src/commonMain/kotlin/com/nuvio/app/features/player/PlayerScreenRuntimeUi.kt
@@ -67,16 +67,27 @@
         } else {
             null
         }
-        AppPresenceState.publish(
-            PresenceSnapshot.Player(
-                title = runtime.title,
-                episodeLabel = episodeLabel,
-                posterUrl = runtime.poster,
-                isPlaying = playbackSnapshot.isPlaying,
-                positionMs = playbackSnapshot.positionMs,
-                durationMs = playbackSnapshot.durationMs,
-            ),
-        )
+        // Re-publish on a timer so the Discord progress bar follows playback and picks up the
+        // catalogue id once it is available. Applied with plain `git apply`, never --3way: if
+        // this hunk stops matching upstream, the build simply carries on without it.
+        while (true) {
+            AppPresenceState.publish(
+                PresenceSnapshot.Player(
+                    title = runtime.title,
+                    episodeLabel = episodeLabel,
+                    posterUrl = runtime.poster,
+                    isPlaying = playbackSnapshot.isPlaying,
+                    positionMs = playbackSnapshot.positionMs,
+                    durationMs = playbackSnapshot.durationMs,
+                    seasonNumber = seasonNumber,
+                    episodeNumber = episodeNumber,
+                    episodeTitle = episodeTitle,
+                    metaId = runtime.parentMetaId,
+                    metaType = runtime.parentMetaType,
+                ),
+            )
+            kotlinx.coroutines.delay(5_000L)
+        }
     }
 
     val currentGestureFeedback = liveGestureFeedback ?: gestureFeedback

'@

Write-RepoFile ".github\workflows\update-drp.yml" @'
name: Update from upstream and build

# One-button updater.
#
# Instead of re-applying a diff (which breaks every time upstream edits the
# same lines), this keeps the Rich Presence files in their own folder, drp/,
# which upstream never touches. Every run:
#
#   1. takes a clean checkout of the LATEST upstream Dev
#   2. copies the drp/ files over it (4 files that are ours alone)
#   3. applies one OPTIONAL patch to the player UI, and skips it if upstream
#      has moved the code it patches
#   4. builds a fresh MSI
#
# Step 3 is the part that used to break. The player UI is the file upstream
# rewrites most often, so shipping a whole frozen copy of it stopped compiling
# as soon as they touched it. It is now a tiny patch, and if it stops matching
# the build carries on without it: presence still works, it just loses the
# IMDb button and the seek-corrected progress bar.
#
# Your branch is never rewritten - the work happens on a throwaway branch
# inside the runner.

on:
  workflow_dispatch:
    inputs:
      publish_release:
        description: Also publish the MSI as a downloadable release
        type: boolean
        default: true

permissions:
  contents: write

jobs:
  build:
    name: Apply Discord RPC onto latest upstream, then build
    runs-on: windows-2022
    env:
      WEBVIEW2_VERSION: 1.0.4078.44

    steps:
      - name: Check out your fork (full history, for the drp/ folder)
        uses: actions/checkout@v6
        with:
          fetch-depth: 0

      - name: Stash the Rich Presence files, then check out clean upstream
        shell: bash
        env:
          BRANCH: ${{ github.ref_name }}
        run: |
          if [[ ! -d drp ]]; then
            echo "::error::No drp/ folder found on branch ${BRANCH}. Add it before running this workflow." >&2
            exit 1
          fi
          echo "--- files sitting in drp/ ---"
          ( cd drp && find . -type f | sort )

          mkdir -p "${RUNNER_TEMP}/overlay"
          cp -r drp/. "${RUNNER_TEMP}/overlay/"

          git remote add upstream https://github.com/NuvioMedia/NuvioDesktop.git
          git fetch --no-tags upstream Dev
          git checkout -B drp-build FETCH_HEAD

          echo "upstream Dev now : $(git rev-parse --short HEAD)"

      - name: Fetch bundled Windows runtime from Git LFS
        shell: bash
        run: |
          git lfs pull upstream \
            --include="composeApp/src/desktopMain/native/windows/runtime/**,composeApp/src/desktopMain/resources/torrserver/windows-amd64/TorrServer.exe" \
            --exclude=""
          runtime_path="composeApp/src/desktopMain/native/windows/runtime/libmpv-2.dll"
          size="$( [[ -f "${runtime_path}" ]] && wc -c < "${runtime_path}" || echo 0 )"
          if (( size < 1000000 )); then
            echo "::error::libmpv-2.dll not materialised from Git LFS (${size} bytes)." >&2
            exit 1
          fi
          echo "libmpv runtime OK (${size} bytes)."

      - name: Lay the Rich Presence files over the upstream code
        shell: bash
        run: |
          # Copy the known files one by one rather than the whole folder. An explicit list means
          # a file left behind in drp/ from an older version can never be copied in by accident
          # and break the build.
          for f in \
            "composeApp/src/commonMain/kotlin/com/nuvio/app/core/ui/AppPresenceState.kt" \
            "composeApp/src/desktopMain/kotlin/com/nuvio/app/features/discordrpc/DiscordActivity.kt" \
            "composeApp/src/desktopMain/kotlin/com/nuvio/app/features/discordrpc/DiscordIpcClient.kt" \
            "composeApp/src/desktopMain/kotlin/com/nuvio/app/features/discordrpc/DiscordPresenceManager.kt" ; do
            src="${RUNNER_TEMP}/overlay/${f}"
            if [[ ! -f "${src}" ]]; then
              echo "::error::Missing from drp/: ${f}" >&2
              exit 1
            fi
            mkdir -p "$(dirname "${f}")"
            cp "${src}" "${f}"
            echo "  applied  ${f}"
          done
          echo "all 4 Rich Presence files in place"
          git status --short

      - name: Apply the optional player patch (skipped safely if it no longer fits)
        shell: bash
        run: |
          # Plain `git apply` only - no --3way. If the hunk no longer matches, git apply fails
          # atomically and leaves the file untouched, so upstream's own player code builds as-is.
          P="drp/patches/PlayerScreenRuntimeUi.patch"
          if [[ ! -f "$P" ]]; then
            echo "::warning::No player patch in drp/patches - continuing without the extras."
            exit 0
          fi
          if git apply --ignore-whitespace "$P"; then
            echo "player patch applied: IMDb button + live progress bar enabled"
          else
            echo "::warning::The player patch no longer matches upstream code. Skipping it."
            echo "::warning::Presence still works - just without the IMDb button, and the"
            echo "::warning::progress bar will not correct itself after a seek."
          fi

      - name: Read the new version
        id: version
        shell: bash
        run: |
          version="$(grep -E '^VERSION_NAME=' composeApp/Configuration/DesktopVersion.properties | cut -d= -f2 | tr -d '[:space:]')"
          echo "version=${version}" >> "$GITHUB_OUTPUT"
          echo "Building Nuvio ${version} with Discord Rich Presence"

      - name: Set up Java
        uses: actions/setup-java@v5
        with:
          distribution: temurin
          java-version: 17

      - name: Set up Gradle
        uses: gradle/actions/setup-gradle@v6

      - name: Provision local.properties
        shell: bash
        env:
          LOCAL_PROPERTIES_BASE64: ${{ secrets.NUVIO_DESKTOP_LOCAL_PROPERTIES_BASE64 }}
        run: |
          if [[ -n "${LOCAL_PROPERTIES_BASE64}" ]]; then
            printf '%s' "${LOCAL_PROPERTIES_BASE64}" | base64 --decode > local.properties
            echo "Using local.properties from repository secret (account sign-in enabled)."
          else
            : > local.properties
            echo "::warning::No NUVIO_DESKTOP_LOCAL_PROPERTIES_BASE64 secret - account sign-in will not work in this build."
          fi
          sed -i -E '/^[[:space:]]*sdk\.dir[[:space:]]*=/d' local.properties
          if ! grep -Eq '^[[:space:]]*NUVIO_DISCORD_CLIENT_ID[[:space:]]*=' local.properties; then
            echo 'NUVIO_DISCORD_CLIENT_ID=1538974392376369212' >> local.properties
          fi
          echo "--- local.properties keys (values hidden) ---"
          sed -E 's/=.*/=<set>/' local.properties || true

      - name: Install WebView2 SDK
        shell: pwsh
        run: |
          nuget install Microsoft.Web.WebView2 `
            -Version $env:WEBVIEW2_VERSION `
            -OutputDirectory "$env:RUNNER_TEMP\nuget" `
            -DirectDownload `
            -NonInteractive `
            -NoCache

          $webView2Root = Join-Path $env:RUNNER_TEMP "nuget\Microsoft.Web.WebView2.$env:WEBVIEW2_VERSION"
          if (-not (Test-Path (Join-Path $webView2Root "build\native\x64\WebView2Loader.dll.lib"))) {
            throw "WebView2 SDK not found at $webView2Root"
          }
          "WEBVIEW2_ROOT=$webView2Root" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append

      - name: Build MSI
        shell: pwsh
        run: |
          & .\gradlew.bat `
            :composeApp:packageReleaseMsi `
            "-Pnuvio.webview2.dir=$env:WEBVIEW2_ROOT" `
            "-Pcompose.desktop.packaging.checkJdkVendor=false" `
            --no-configuration-cache `
            --no-daemon `
            --stacktrace

      - name: Summarise
        id: msi
        shell: pwsh
        run: |
          $msi = Get-ChildItem "composeApp\build\compose\release-msis" -Filter *.msi | Select-Object -First 1
          if ($null -eq $msi) { throw "No MSI was produced." }
          $hash = (Get-FileHash $msi.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
          "path=$($msi.FullName)" | Out-File $env:GITHUB_OUTPUT -Encoding utf8 -Append
          "name=$($msi.Name)"     | Out-File $env:GITHUB_OUTPUT -Encoding utf8 -Append
          "sha=$hash"             | Out-File $env:GITHUB_OUTPUT -Encoding utf8 -Append
          "### Nuvio + Discord RPC`n`n- **MSI:** $($msi.Name)`n- **Size:** $([math]::Round($msi.Length/1MB,1)) MB`n- **SHA256:** ``$hash``" |
            Out-File $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append

      - name: Upload MSI artifact
        uses: actions/upload-artifact@v7
        with:
          name: nuvio-drp-${{ steps.version.outputs.version }}-windows-x64
          path: composeApp/build/compose/release-msis/*.msi
          if-no-files-found: error
          retention-days: 14

      - name: Publish release
        if: ${{ inputs.publish_release }}
        shell: bash
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          tag="drp-${{ steps.version.outputs.version }}"
          msi="${{ steps.msi.outputs.path }}"
          if gh release view "$tag" --repo "${{ github.repository }}" >/dev/null 2>&1; then
            gh release upload "$tag" "$msi" --clobber --repo "${{ github.repository }}"
          else
            gh release create "$tag" "$msi" \
              --repo "${{ github.repository }}" \
              --title "Nuvio ${{ steps.version.outputs.version }} + Discord Rich Presence" \
              --notes "Unofficial build: upstream Nuvio ${{ steps.version.outputs.version }} with the upgraded Discord Rich Presence applied.

          SHA256: \`${{ steps.msi.outputs.sha }}\`

          Unsigned installer - SmartScreen will warn, choose More info then Run anyway.
          Enable under Settings > Advanced > Discord."
          fi
          echo "https://github.com/${{ github.repository }}/releases/tag/$tag" >> "$GITHUB_STEP_SUMMARY"

'@


Write-Host ""
Set-Location $repo

Write-Host "Running: git add -A" -ForegroundColor Cyan
& git add -A

Write-Host "Running: git commit" -ForegroundColor Cyan
& git commit -m "discord: stop shipping the player UI, patch it optionally instead"
if ($LASTEXITCODE -ne 0) {
    Write-Host "  (nothing new to commit - continuing anyway)" -ForegroundColor Yellow
}

Write-Host "Running: git push origin Dev" -ForegroundColor Cyan
& git push origin Dev
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "PUSH FAILED. Copy the red text above and send it over." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host " PUSHED OK" -ForegroundColor Green
Write-Host ""
Write-Host " Next: open the link below, click" -ForegroundColor Green
Write-Host " 'Update from upstream and build', then" -ForegroundColor Green
Write-Host " 'Run workflow' (branch: Dev)." -ForegroundColor Green
Write-Host ""
Write-Host " https://github.com/xmlwastaken/NuvioDesktop/actions/workflows/update-drp.yml" -ForegroundColor Cyan
Write-Host ""
Write-Host " Use 'Run workflow' - NOT 'Re-run jobs'." -ForegroundColor Yellow
Write-Host ""
Write-Host " After installing: Settings > Advanced > Discord >" -ForegroundColor Yellow
Write-Host " Discord Rich Presence  must be ON (it is off by default)." -ForegroundColor Yellow
Write-Host "=============================================" -ForegroundColor Green
