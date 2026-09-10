# =====================================================================
#  Nuvio Discord Rich Presence - v5
#  Playback only, and the payload bug fixed.
#
#  Two fixes in this one:
#
#   1. Presence is now reported ONLY while a video is playing. Home,
#      Search, Library, Settings and title details pages clear the card
#      instead of showing a browsing status.
#
#   2. Found why v4 showed nothing at all: upstream's IPC client
#      serialises with explicitNulls = true, so the "buttons" field we
#      added was being sent as "buttons": null on every update. Discord
#      rejects that, every SET_ACTIVITY failed, and the presence never
#      appeared. The client now omits unset fields and only sends a
#      real null when clearing - which is how the version that worked
#      behaved.
#
#  Run this ONCE from PowerShell. It writes 6 files, commits and pushes
#  to the Dev branch.
#
#  1. Save this file to  C:\Users\XML\NuvioDesktop\apply-drp-v5.ps1
#  2. Open PowerShell and run:
#         cd C:\Users\XML\NuvioDesktop
#         powershell -ExecutionPolicy Bypass -File .\apply-drp-v5.ps1
#  3. When it says PUSHED, go to GitHub -> Actions ->
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
        val seasonNumber: Int? = null,
        val episodeNumber: Int? = null,
        val episodeTitle: String? = null,
        /** Release info as reported by the addon, e.g. `2024` or `2011-2019`. */
        val year: String? = null,
        /** Stremio-style catalogue id of the parent item, e.g. `tt0944947` or `kitsu:12345`. */
        val metaId: String? = null,
        /** `movie` or `series`. */
        val metaType: String? = null,
    ) : PresenceSnapshot {
        val isSeries: Boolean get() = seasonNumber != null && episodeNumber != null
    }
}

'@

Write-RepoFile "drp\composeApp\src\commonMain\kotlin\com\nuvio\app\features\player\PlayerScreenRuntimeUi.kt" @'
package com.nuvio.app.features.player

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onSizeChanged
import co.touchlab.kermit.Logger
import com.nuvio.app.core.format.formatReleaseDateForDisplay
import com.nuvio.app.core.i18n.localizedByteUnit
import com.nuvio.app.core.ui.AppPresenceState
import com.nuvio.app.core.ui.PresenceSnapshot
import com.nuvio.app.core.ui.nuvio
import com.nuvio.app.features.debrid.DebridSettingsRepository
import com.nuvio.app.features.debrid.DirectDebridPlaybackResolver
import com.nuvio.app.features.details.MetaDetailsRepository
import com.nuvio.app.features.details.MetaVideo
import com.nuvio.app.features.p2p.P2pSettingsRepository
import com.nuvio.app.features.p2p.P2pStreamingState
import com.nuvio.app.features.p2p.formatP2pMegabytes
import com.nuvio.app.features.p2p.formatP2pSpeed
import com.nuvio.app.features.player.skip.SkipIntroRepository
import com.nuvio.app.features.streams.AddonStreamGroup
import com.nuvio.app.features.streams.StreamBadgeSettingsRepository
import com.nuvio.app.features.streams.StreamItem
import com.nuvio.app.features.streams.isSelectableForPlayback
import com.nuvio.app.features.watchprogress.buildPlaybackVideoId
import com.nuvio.app.features.watching.application.WatchingState
import com.nuvio.app.isDesktop
import com.nuvio.app.isIos
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.roundToInt
import nuvio.composeapp.generated.resources.*
import org.jetbrains.compose.resources.stringResource

private val playerControlsLog = Logger.withTag("PlayerControls")

/** How often the player re-publishes its presence so a seek reaches the Discord progress bar. */
private const val PresenceRefreshIntervalMs = 5_000L

@Composable
internal fun PlayerScreenRuntime.RenderPlayerRuntimeUi() {
    val runtime = this
    val systemBackRegistration = args.onSystemBackHandlerChanged
    DisposableEffect(runtime, systemBackRegistration) {
        systemBackRegistration { runtime.requestBack() }
        onDispose { systemBackRegistration(null) }
    }
    val isInPip = rememberIsInPictureInPicture()
    val displayedPositionMs = scrubbingPositionMs ?: playbackSnapshot.positionMs
    val seasonNumber = activeSeasonNumber
    val episodeNumber = activeEpisodeNumber
    val episodeTitle = activeEpisodeTitle
    val isEpisode = seasonNumber != null && episodeNumber != null

    LaunchedEffect(runtime.title, runtime.poster, seasonNumber, episodeNumber, episodeTitle, playbackSnapshot.isPlaying) {
        val episodeLabel = if (isEpisode) {
            val base = "S${seasonNumber}E${episodeNumber}"
            if (!episodeTitle.isNullOrBlank()) "$base - $episodeTitle" else base
        } else {
            null
        }
        // Re-publish on a timer as well as on state changes: position and duration cannot be
        // effect keys (they change every frame), but a seek has to reach the Discord progress
        // bar. The presence manager de-duplicates, so an unchanged republish costs nothing.
        while (true) {
            val snapshot = runtime.playbackSnapshot
            AppPresenceState.publish(
                PresenceSnapshot.Player(
                    title = runtime.title,
                    episodeLabel = episodeLabel,
                    posterUrl = runtime.poster,
                    isPlaying = snapshot.isPlaying,
                    positionMs = snapshot.positionMs,
                    durationMs = snapshot.durationMs,
                    seasonNumber = seasonNumber,
                    episodeNumber = episodeNumber,
                    episodeTitle = episodeTitle,
                    year = runtime.metaUiState.meta?.releaseInfo,
                    metaId = runtime.parentMetaId,
                    metaType = runtime.parentMetaType,
                ),
            )
            delay(PresenceRefreshIntervalMs)
        }
    }

    val currentGestureFeedback = liveGestureFeedback ?: gestureFeedback
    val isP2pPlaybackActive = activeTorrentInfoHash != null
    val p2pConnecting = p2pStreamingState as? P2pStreamingState.Connecting
    val p2pStats = p2pStreamingState as? P2pStreamingState.Streaming
    val p2pPeerInfo = p2pStats?.let { stats ->
        org.jetbrains.compose.resources.stringResource(
            nuvio.composeapp.generated.resources.Res.string.player_torrent_peer_info,
            stats.seeds,
            stats.peers,
        )
    }
    val p2pDownloadSpeed = p2pStats?.let { formatP2pSpeed(it.downloadSpeed) }
    val p2pLoadingBytes = p2pStats?.let { maxOf(it.downloadedBytes, it.deliveredBytes) } ?: 0L
    val connectingPeerInfo = p2pConnecting?.let { state ->
        org.jetbrains.compose.resources.stringResource(
            nuvio.composeapp.generated.resources.Res.string.player_torrent_peer_info,
            state.seeds,
            state.peers,
        )
    }
    val p2pInitialLoadingMessage = when {
        !isP2pPlaybackActive || initialLoadCompleted -> null
        p2pConnecting != null -> {
            if (p2pSettingsUiState.hideTorrentStats) {
                p2pConnectingPhaseLabel(p2pConnecting.phase)
            } else {
                org.jetbrains.compose.resources.stringResource(
                    nuvio.composeapp.generated.resources.Res.string.player_torrent_connecting_status,
                    p2pConnectingPhaseLabel(p2pConnecting.phase),
                    connectingPeerInfo.orEmpty(),
                    formatP2pSpeed(p2pConnecting.downloadSpeed),
                )
            }
        }
        p2pStats != null -> {
            if (p2pSettingsUiState.hideTorrentStats) {
                null
            } else {
                org.jetbrains.compose.resources.stringResource(
                    nuvio.composeapp.generated.resources.Res.string.player_torrent_loading_status,
                    formatP2pMegabytes(p2pLoadingBytes),
                    p2pPeerInfo.orEmpty(),
                    p2pDownloadSpeed.orEmpty(),
                )
            }
        }
        else -> org.jetbrains.compose.resources.stringResource(
            nuvio.composeapp.generated.resources.Res.string.player_torrent_starting_engine,
        )
    }
    val bufferedAheadMs = (playbackSnapshot.bufferedPositionMs - playbackSnapshot.positionMs)
        .coerceAtLeast(0L)
    val p2pInitialLoadingProgress = when {
        !isP2pPlaybackActive || initialLoadCompleted || p2pStats == null -> null
        else -> p2pInitialLoadingProgress(
            bufferedAheadMs = bufferedAheadMs,
            downloadedBytes = p2pStats.downloadedBytes,
            deliveredBytes = p2pStats.deliveredBytes,
        )
    }
    val showP2pRebufferStats = isP2pPlaybackActive &&
        initialLoadCompleted &&
        playbackSnapshot.isLoading &&
        p2pStats != null &&
        !p2pSettingsUiState.hideTorrentStats
    val p2pRebufferMessage = when {
        !showP2pRebufferStats -> null
        else -> {
            val bufferedSeconds = ((playbackSnapshot.bufferedPositionMs - playbackSnapshot.positionMs) / 1000L)
                .coerceAtLeast(0L)
            "${bufferedSeconds}s buffered · ${p2pPeerInfo.orEmpty()} · ${p2pDownloadSpeed.orEmpty()}"
        }
    }
    val p2pRebufferProgress = when {
        !showP2pRebufferStats -> null
        else -> {
            val bufferedSeconds = ((playbackSnapshot.bufferedPositionMs - playbackSnapshot.positionMs) / 1000f)
                .coerceAtLeast(0f)
            (bufferedSeconds / 10f).coerceIn(0f, 1f)
        }
    }
    val playerSurfaceSourceUrl = if (isP2pPlaybackActive) p2pResolvedSourceUrl else activeSourceUrl
    val initialPositionRequestKey = currentInitialPositionRequestKey()
    val currentPlayerSurfaceSource = playerSurfaceSourceUrl?.let { sourceUrl ->
        PlayerSurfaceSource(
            sourceUrl = sourceUrl,
            sourceAudioUrl = activeSourceAudioUrl,
            sourceHeaders = activeSourceHeaders,
            sourceResponseHeaders = activeSourceResponseHeaders,
            externalSubtitles = externalSubtitles,
            streamType = activeStreamType,
            initialPositionMs = activeInitialPositionMs.takeIf { it > 0L },
            initialPositionRequestKey = initialPositionRequestKey,
        )
    }
    val renderPlayerSurface = shouldRenderPlayerSurface(
        hasCurrentSource = currentPlayerSurfaceSource != null,
        hasLifecycleController = playerLifecycleController != null,
        releaseInFlight = playerReleaseSurfaceRetention.inFlight,
        desktop = isDesktop,
    )
    val openingOverlayWanted = playerSettingsUiState.showLoadingOverlay &&
        !initialLoadCompleted &&
        errorMessage == null
    val episodeText = if (seasonNumber != null && episodeNumber != null && !episodeTitle.isNullOrBlank()) {
        stringResource(
            Res.string.compose_player_episode_title_format,
            seasonNumber,
            episodeNumber,
            episodeTitle.orEmpty(),
        )
    } else {
        ""
    }
    val allFilterLabel = stringResource(Res.string.collections_tab_all)
    val playingLabel = stringResource(Res.string.compose_player_playing)
    val sourceFilters = buildPlayerControlFilters(
        allLabel = allFilterLabel,
        selectedFilter = null,
    )
    val sourceItems = buildPlayerControlSourceItems()
    val episodeItems = buildPlayerControlEpisodeItems()
    val episodeSeasons = buildPlayerControlSeasonItems(episodeItems)
    val episodeStreamFilters = buildPlayerControlEpisodeStreamFilters(
        allLabel = allFilterLabel,
        selectedFilter = null,
    )
    val episodeStreamItems = buildPlayerControlEpisodeStreamItems()
    val playerControlAddonSubtitles = buildPlayerControlAddonSubtitleItems()
    val playerControlSubtitleSelection = buildPlayerControlSubtitleSelection()
    val playerControlAutoSyncCues = buildPlayerControlSubtitleCueItems()
    val themeColors = MaterialTheme.nuvio.colors
    val selectedEpisodeLabel = episodeStreamsPanelState.selectedEpisode?.let { selected ->
        val selectedCode = selected.playerControlsEpisodeCode()
        buildString {
            append(selectedCode)
            if (selected.title.isNotBlank()) {
                if (isNotEmpty()) append(" • ")
                append(selected.title)
            }
        }
    }.orEmpty()
    val nativeSkipInterval = activeSkipInterval.takeIf {
        initialLoadCompleted && !pausedOverlayVisible && !skipIntervalDismissed
    }
    val nextEpisodeForControls = nextEpisodeInfo.takeIf { 
        isSeries && (showNextEpisodeCard || nextEpisodeAutoPlaySearching || nextEpisodeAutoPlayCountdown != null) 
    }
    val nextEpisodeStatus = when {
        nextEpisodeForControls == null -> ""
        !nextEpisodeForControls.hasAired && !nextEpisodeForControls.unairedMessage.isNullOrBlank() ->
            nextEpisodeForControls.unairedMessage.orEmpty()
        nextEpisodeAutoPlaySearching -> stringResource(Res.string.player_next_episode_finding_source)
        !nextEpisodeAutoPlaySourceName.isNullOrBlank() && nextEpisodeAutoPlayCountdown != null ->
            stringResource(
                Res.string.player_next_episode_playing_via_countdown,
                nextEpisodeAutoPlaySourceName.orEmpty(),
                nextEpisodeAutoPlayCountdown ?: 0,
            )
        else -> ""
    }
    val playerControlsState = PlayerControlsState(
        title = title,
        episodeText = episodeText,
        streamTitle = activeStreamTitle,
        providerName = activeProviderName,
        pauseOverlayWatchingLabel = stringResource(Res.string.compose_player_youre_watching),
        pauseOverlayLogo = logo,
        pauseOverlayEpisodeInfo = if (seasonNumber != null && episodeNumber != null) {
            stringResource(Res.string.compose_player_episode_code_full, seasonNumber, episodeNumber)
        } else {
            activeProviderName
        },
        pauseOverlayEpisodeTitle = activeEpisodeTitle.orEmpty(),
        pauseOverlayDescription = (activePauseDescription ?: activeStreamSubtitle).orEmpty(),
        resizeModeLabel = stringResource(resizeMode.labelRes),
        playbackSpeedLabel = formatPlaybackSpeedLabel(playbackSnapshot.playbackSpeed),
        subtitlesLabel = stringResource(Res.string.compose_player_subs),
        audioLabel = stringResource(Res.string.compose_player_audio),
        sourcesLabel = stringResource(Res.string.compose_player_sources),
        episodesLabel = stringResource(Res.string.compose_player_episodes),
        externalPlayerLabel = stringResource(Res.string.streams_open_external_player),
        playLabel = stringResource(Res.string.detail_btn_play),
        pauseLabel = stringResource(Res.string.compose_action_pause),
        closeLabel = stringResource(Res.string.compose_player_close),
        mutedLabel = stringResource(Res.string.compose_player_muted),
        volumeLevelLabelFormat = stringResource(Res.string.compose_player_volume_level, "%s"),
        lockLabel = stringResource(Res.string.compose_player_lock_controls),
        unlockLabel = stringResource(Res.string.compose_player_unlock_controls),
        submitIntroLabel = stringResource(Res.string.submit_intro_action),
        videoSettingsLabel = stringResource(Res.string.player_action_video_settings),
        tapToUnlockLabel = stringResource(Res.string.compose_player_tap_to_unlock),
        playbackErrorTitle = stringResource(Res.string.compose_player_playback_error),
        playbackErrorMessage = errorMessage.orEmpty(),
        playbackErrorActionLabel = stringResource(Res.string.compose_player_go_back),
        sourcesPanelTitle = stringResource(Res.string.compose_player_panel_sources),
        episodesPanelTitle = stringResource(Res.string.compose_player_panel_episodes),
        streamsPanelTitle = stringResource(Res.string.compose_player_panel_streams),
        allFilterLabel = allFilterLabel,
        reloadLabel = stringResource(Res.string.compose_action_reload),
        backLabel = stringResource(Res.string.action_back),
        panelCloseLabel = stringResource(Res.string.action_close),
        cancelLabel = stringResource(Res.string.action_cancel),
        playingLabel = playingLabel,
        noStreamsLabel = stringResource(Res.string.compose_player_no_streams_found),
        noEpisodesLabel = stringResource(Res.string.compose_player_no_episodes_available),
        submitIntroPanelTitle = stringResource(Res.string.submit_intro_title),
        submitIntroSegmentTypeLabel = stringResource(Res.string.submit_intro_segment_type_label),
        submitIntroSegmentIntroLabel = stringResource(Res.string.submit_intro_segment_intro),
        submitIntroSegmentRecapLabel = stringResource(Res.string.submit_intro_segment_recap),
        submitIntroSegmentOutroLabel = stringResource(Res.string.submit_intro_segment_outro),
        submitIntroStartTimeLabel = stringResource(Res.string.submit_intro_start_time_label),
        submitIntroEndTimeLabel = stringResource(Res.string.submit_intro_end_time_label),
        submitIntroCaptureLabel = stringResource(Res.string.submit_intro_capture_button),
        submitIntroSubmitLabel = stringResource(Res.string.submit_intro_button_submit),
        p2pConsentTitle = stringResource(Res.string.p2p_consent_title),
        p2pConsentBody = stringResource(Res.string.p2p_consent_body),
        p2pConsentEnableLabel = stringResource(Res.string.p2p_consent_enable),
        p2pConsentCancelLabel = stringResource(Res.string.p2p_consent_cancel),
        speedPanelTitle = stringResource(Res.string.compose_player_playback_speed),
        audioTracksPanelTitle = stringResource(Res.string.compose_player_audio_tracks),
        noAudioTracksLabel = stringResource(Res.string.compose_player_no_audio_tracks_available),
        subtitlesPanelTitle = stringResource(Res.string.compose_player_subtitles),
        subtitleLanguagesLabel = stringResource(Res.string.compose_player_languages),
        subtitleBuiltInTabLabel = stringResource(Res.string.compose_player_built_in),
        subtitleAddonsTabLabel = stringResource(Res.string.addon_title),
        subtitleStyleTabLabel = stringResource(Res.string.compose_player_style),
        customSubtitleStyleLabel = stringResource(Res.string.compose_player_use_custom_styling),
        forcedLabel = stringResource(Res.string.settings_playback_option_forced),
        noneLabel = stringResource(Res.string.compose_player_none),
        fetchSubtitlesLabel = stringResource(Res.string.compose_player_fetch_subtitles),
        subtitleDelayLabel = stringResource(Res.string.compose_player_subtitle_delay),
        resetLabel = stringResource(Res.string.compose_player_reset),
        autoSyncLabel = stringResource(Res.string.compose_player_auto_sync),
        reloadSmallLabel = stringResource(Res.string.compose_player_reload),
        captureLineLabel = stringResource(Res.string.compose_player_capture_line),
        selectAddonSubtitleFirstLabel = stringResource(Res.string.compose_player_select_addon_subtitle_first),
        loadingSubtitleLinesLabel = stringResource(Res.string.compose_player_loading_lines),
        fontSizeLabel = stringResource(Res.string.compose_player_font_size),
        outlineLabel = stringResource(Res.string.compose_player_outline),
        boldLabel = stringResource(Res.string.compose_player_bold),
        bottomOffsetLabel = stringResource(Res.string.compose_player_bottom_offset),
        colorLabel = stringResource(Res.string.compose_player_color),
        textOpacityLabel = stringResource(Res.string.compose_player_text_opacity),
        outlineColorLabel = stringResource(Res.string.compose_player_outline_color),
        noSubtitleLinesFoundLabel = stringResource(Res.string.compose_player_no_subtitle_lines_found),
        resetDefaultsLabel = stringResource(Res.string.compose_player_reset_defaults),
        onLabel = stringResource(Res.string.compose_action_on),
        offLabel = stringResource(Res.string.compose_action_off),
        themeAccentColor = themeColors.accent.toCssColorString(),
        themeAccentStrongColor = themeColors.accentStrong.toCssColorString(),
        themeOnAccentColor = themeColors.onAccent.toCssColorString(),
        themeFocusColor = themeColors.focusRing.toCssColorString(),
        themeSelectedSurfaceColor = themeColors.accent.copy(alpha = 0.24f).toCssColorString(),
        themeSelectedSurfaceHoverColor = themeColors.accent.copy(alpha = 0.34f).toCssColorString(),
        themeSelectedRingColor = themeColors.accent.copy(alpha = 0.35f).toCssColorString(),
        themeTimelineFillColor = themeColors.playerTimelineFill.toCssColorString(),
        themeTimelineTrackColor = themeColors.playerTimelineTrack.toCssColorString(),
        themeBufferingColor = themeColors.playerBuffering.toCssColorString(),
        themeBufferingTrackColor = themeColors.playerBuffering.copy(alpha = 0.28f).toCssColorString(),
        themeControlForegroundColor = themeColors.playerControlsForeground.toCssColorString(),
        themeSurfaceElevatedColor = themeColors.surfaceElevated.toCssColorString(),
        themeSurfaceCardColor = themeColors.surfaceCard.toCssColorString(),
        themeSurfacePopoverColor = themeColors.surfacePopover.toCssColorString(),
        themeTextPrimaryColor = themeColors.textPrimary.toCssColorString(),
        themeTextSecondaryColor = themeColors.textSecondary.toCssColorString(),
        themeTextMutedColor = themeColors.textMuted.toCssColorString(),
        themeBorderDefaultColor = themeColors.borderDefault.toCssColorString(),
        isPlaying = playbackSnapshot.isPlaying,
        isLoading = playbackSnapshot.isLoading,
        isLocked = playerControlsLocked,
        lockedOverlayVisible = lockedOverlayVisible,
        controlsVisible = controlsVisible && !playerControlsLocked,
        parentalWarnings = parentalWarnings,
        showParentalGuide = showParentalGuide,
        showSubmitIntro = isSeries &&
            playerSettingsUiState.introSubmitEnabled &&
            playerSettingsUiState.introDbApiKey.isNotBlank() &&
            !activeSubmitIntroImdbId().isNullOrBlank(),
        showVideoSettings = isIos,
        showSources = activeVideoId != null,
        showEpisodes = isSeries,
        showExternalPlayer = args.onOpenInExternalPlayer != null,
        durationMs = playbackSnapshot.durationMs,
        positionMs = displayedPositionMs,
        sourceIsLoading = sourceStreamsState.isAnyLoading,
        sourceFilters = sourceFilters,
        sourceItems = sourceItems,
        episodeItems = episodeItems,
        episodeSeasons = episodeSeasons,
        episodeStreamsVisible = episodeStreamsPanelState.showStreams,
        episodeStreamsIsLoading = episodeStreamsRepoState.isAnyLoading,
        selectedEpisodeLabel = selectedEpisodeLabel,
        episodeStreamFilters = episodeStreamFilters,
        episodeStreamItems = episodeStreamItems,
        blurUnwatchedEpisodes = metaScreenSettingsUiState.blurUnwatchedEpisodes,
        submitIntroSegmentType = submitIntroSegmentType,
        submitIntroContentKey = activeSubmitIntroContentKey(),
        submitIntroStartTime = submitIntroStartTimeStr,
        submitIntroEndTime = submitIntroEndTimeStr,
        isSubmitIntroSubmitting = isSubmitIntroSubmitting,
        submitIntroStatusMessage = submitIntroStatusMessage.orEmpty(),
        showP2pConsent = playerControlsPendingP2pSwitch != null,
        subtitleActiveTab = activeSubtitleTab.name,
        subtitleLanguageItems = playerControlSubtitleSelection.languages,
        subtitleOptionItems = playerControlSubtitleSelection.options,
        selectedSubtitleLanguageKey = playerControlSubtitleSelection.selectedLanguageKey,
        selectedSubtitleOptionId = playerControlSubtitleSelection.selectedOptionId,
        addonSubtitleItems = playerControlAddonSubtitles,
        isLoadingAddonSubtitles = isLoadingAddonSubtitles,
        selectedAddonSubtitleId = selectedAddonSubtitleId.orEmpty(),
        useCustomSubtitles = useCustomSubtitles,
        customSubtitleStylingEnabled = !playerSettingsUiState.useLibass,
        subtitleStyle = subtitleStyle,
        subtitleDelayMs = subtitleDelayMs,
        hasSelectedAddonSubtitle = selectedAddonSubtitle != null,
        subtitleAutoSyncCapturedPositionMs = subtitleAutoSyncState.capturedPositionMs ?: -1L,
        subtitleAutoSyncCues = playerControlAutoSyncCues,
        subtitleAutoSyncIsLoading = subtitleAutoSyncState.isLoading,
        subtitleAutoSyncErrorMessage = subtitleAutoSyncState.errorMessage.orEmpty(),
        closeModalsToken = playerControlsCloseModalsToken,
        submitIntroSuccessToken = playerControlsSubmitIntroSuccessToken,
        notificationMessage = playerNotificationMessage,
        notificationToken = playerNotificationToken,
        showOpeningOverlay = openingOverlayWanted,
        openingArtwork = background ?: poster,
        openingLogo = logo,
        openingTitle = title,
        openingMessage = p2pInitialLoadingMessage,
        openingProgress = p2pInitialLoadingProgress,
        skipPromptVisible = nativeSkipInterval != null && !playerControlsLocked,
        skipPromptLabel = skipPromptLabel(nativeSkipInterval?.type),
        skipPromptStartMs = ((nativeSkipInterval?.startTime ?: 0.0) * 1000).toLong().coerceAtLeast(0L),
        skipPromptEndMs = ((nativeSkipInterval?.endTime ?: 0.0) * 1000).toLong().coerceAtLeast(0L),
        skipPromptDismissed = skipIntervalDismissed,
        nextEpisodeVisible = nextEpisodeForControls != null && !playerControlsLocked,
        nextEpisodeHeaderLabel = stringResource(Res.string.player_next_episode),
        nextEpisodeTitle = nextEpisodeForControls?.let {
            stringResource(
                Res.string.compose_player_episode_title_format,
                it.season,
                it.episode,
                it.title,
            )
        }.orEmpty(),
        nextEpisodeThumbnail = nextEpisodeForControls?.thumbnail.orEmpty(),
        nextEpisodeStatus = nextEpisodeStatus,
        nextEpisodeActionLabel = if (nextEpisodeForControls?.hasAired == true) {
            stringResource(Res.string.detail_btn_play)
        } else {
            stringResource(Res.string.player_next_episode_unaired)
        },
        nextEpisodePlayable = nextEpisodeInfo?.hasAired == true,
    )
    val gestureCallbacks = rememberSurfaceGestureCallbacks()

    Box(
        modifier = Modifier
            .fillMaxSize()
            .onSizeChanged { layoutSize = it }
            .playerSurfaceTapGestures(
                layoutSize = layoutSize,
                playerControlsLockedState = gestureCallbacks.playerControlsLocked,
                onSurfaceTap = gestureCallbacks.onSurfaceTap,
                onSurfaceDoubleTap = gestureCallbacks.onSurfaceDoubleTap,
                activateHoldToSpeedState = gestureCallbacks.activateHoldToSpeed,
                deactivateHoldToSpeedState = gestureCallbacks.deactivateHoldToSpeed,
                revealLockedOverlayState = gestureCallbacks.revealLockedOverlay,
            )
            .playerSurfaceDragGestures(
                gestureController = gestureController,
                layoutSize = layoutSize,
                sideGestureSystemEdgeExclusionPx = sideGestureSystemEdgeExclusionPx,
                playerControlsLockedState = gestureCallbacks.playerControlsLocked,
                touchGesturesEnabledState = gestureCallbacks.touchGesturesEnabled,
                isHoldToSpeedGestureActiveState = gestureCallbacks.isHoldToSpeedGestureActive,
                currentPositionMsState = gestureCallbacks.currentPositionMs,
                currentDurationMsState = gestureCallbacks.currentDurationMs,
                deactivateHoldToSpeedState = gestureCallbacks.deactivateHoldToSpeed,
                showHorizontalSeekPreviewState = gestureCallbacks.showHorizontalSeekPreview,
                showBrightnessFeedbackState = gestureCallbacks.showBrightnessFeedback,
                showVolumeFeedbackState = gestureCallbacks.showVolumeFeedback,
                clearLiveGestureFeedbackState = gestureCallbacks.clearLiveGestureFeedback,
                revealLockedOverlayState = gestureCallbacks.revealLockedOverlay,
                commitHorizontalSeekState = gestureCallbacks.commitHorizontalSeek,
            ),
    ) {
        if (renderPlayerSurface) {
            val surfaceSource = currentPlayerSurfaceSource
            val sourceAvailable = surfaceSource != null
            PlatformPlayerSurface(
                sourceUrl = surfaceSource?.sourceUrl.orEmpty(),
                sourceAvailable = sourceAvailable,
                sourceAudioUrl = surfaceSource?.sourceAudioUrl,
                sourceHeaders = surfaceSource?.sourceHeaders.orEmpty(),
                sourceResponseHeaders = surfaceSource?.sourceResponseHeaders.orEmpty(),
                externalSubtitles = surfaceSource?.externalSubtitles.orEmpty(),
                streamType = surfaceSource?.streamType,
                modifier = Modifier.fillMaxSize(),
                playWhenReady = shouldPlay && sourceAvailable,
                initialPositionMs = surfaceSource?.initialPositionMs,
                initialPositionRequestKey = surfaceSource?.initialPositionRequestKey,
                resizeMode = resizeMode,
                playerControlsState = playerControlsState,
                onPlayerControlsAction = { action -> handlePlayerControlsAction(action) },
                onPlayerControlsEvent = { type, value -> handlePlayerControlsEvent(type, value) },
                onPlayerControlsScrubChange = { positionMs ->
                    handlePlayerControlsScrubChange(positionMs)
                    true
                },
                onPlayerControlsScrubFinished = { positionMs ->
                    handlePlayerControlsScrubFinished(positionMs)
                    true
                },
                onInitialPositionHandled = { key, handled ->
                    if (key == currentInitialPositionRequestKey()) {
                        initialSeekApplied = handled
                    }
                },
                onControllerReady = { controller ->
                    playerController = controller.takeIf { sourceAvailable }
                    playerLifecycleController = controller
                    playerControllerSourceUrl = surfaceSource?.sourceUrl
                },
                onSnapshot = { snapshot ->
                    playbackSnapshot = snapshot
                    refreshAudioTracksIfChanged()
                    if (!snapshot.isLoading) initialLoadCompleted = true
                    if (snapshot.isEnded) {
                        shouldPlay = false
                        controlsVisible = !playerControlsLocked
                    }
                },
                onError = { message ->
                    if (message != null && tryRefreshCredentialedSourceAfterError(message)) {
                        return@PlatformPlayerSurface
                    }
                    errorMessage = message
                    if (message != null) {
                        controlsVisible = !playerControlsLocked
                        removeFailedStreamFromCache()
                    }
                },
            )
        }

        AnimatedVisibility(
            visible = pausedOverlayVisible && !controlsVisible && !playerControlsLocked,
            enter = fadeIn(animationSpec = tween(durationMillis = 220)),
            exit = fadeOut(animationSpec = tween(durationMillis = 180)),
        ) {
            PauseMetadataOverlay(
                title = title,
                logo = logo,
                isEpisode = isEpisode,
                seasonNumber = activeSeasonNumber,
                episodeNumber = activeEpisodeNumber,
                episodeTitle = activeEpisodeTitle,
                pauseDescription = activePauseDescription ?: activeStreamSubtitle,
                providerName = activeProviderName,
                metrics = metrics,
                horizontalSafePadding = horizontalSafePadding,
                modifier = Modifier.fillMaxSize(),
            )
        }

        if (!isDesktop) {
            RenderPlayerControls(displayedPositionMs = displayedPositionMs, isEpisode = isEpisode)
        }
        RenderPlaybackOverlays(
            runtime = runtime,
            displayedPositionMs = displayedPositionMs,
            currentGestureFeedback = currentGestureFeedback,
            p2pInitialLoadingMessage = p2pInitialLoadingMessage,
            p2pInitialLoadingProgress = p2pInitialLoadingProgress,
            showP2pRebufferStats = showP2pRebufferStats,
            p2pRebufferMessage = p2pRebufferMessage,
            p2pRebufferProgress = p2pRebufferProgress,
            suppressOpeningOverlay = isDesktop && playerSurfaceSourceUrl != null,
        )
        RenderPlayerModals(displayedPositionMs = displayedPositionMs)
    }
}

@Composable
private fun p2pConnectingPhaseLabel(phase: String): String = when (phase) {
    "add_magnet" -> org.jetbrains.compose.resources.stringResource(
        nuvio.composeapp.generated.resources.Res.string.player_torrent_fetching_metadata,
    )
    "prepare_stream", "attach_route" -> org.jetbrains.compose.resources.stringResource(
        nuvio.composeapp.generated.resources.Res.string.player_torrent_preparing_stream,
    )
    else -> org.jetbrains.compose.resources.stringResource(
        nuvio.composeapp.generated.resources.Res.string.player_torrent_starting_engine,
    )
}

private fun PlayerScreenRuntime.currentInitialPositionRequestKey(): String? {
    val positionMs = activeInitialPositionMs.takeIf { it > 0L } ?: return null
    return "$activePlaybackIdentity:${activeVideoId.orEmpty()}:$positionMs"
}

@Composable
private fun PlayerScreenRuntime.RenderPlayerControls(displayedPositionMs: Long, isEpisode: Boolean) {
    val isInPip = rememberIsInPictureInPicture()
    AnimatedVisibility(
        visible = (controlsVisible || showParentalGuide) && !playerControlsLocked && !isInPip,
        enter = fadeIn(),
        exit = fadeOut(),
    ) {
        PlayerControlsShell(
            title = title,
            streamTitle = activeStreamTitle,
            providerName = activeProviderName,
            seasonNumber = activeSeasonNumber,
            episodeNumber = activeEpisodeNumber,
            episodeTitle = activeEpisodeTitle,
            playbackSnapshot = playbackSnapshot,
            displayedPositionMs = displayedPositionMs,
            metrics = metrics,
            resizeMode = resizeMode,
            isLocked = playerControlsLocked,
            showPlaybackControls = controlsVisible,
            onLockToggle = {
                if (playerControlsLocked) unlockPlayerControls() else lockPlayerControls()
            },
            onBack = { requestBack() },
            onTogglePlayback = { togglePlayback() },
            onSeekBack = { seekBy(-10_000L) },
            onSeekForward = { seekBy(10_000L) },
            onResizeModeClick = { cycleResizeMode() },
            onSpeedClick = { cyclePlaybackSpeed() },
            onSubtitleClick = {
                refreshTracks()
                showSubtitleModal = true
            },
            onAudioClick = {
                refreshTracks()
                showAudioModal = true
            },
            onVideoSettingsClick = if (isIos) {
                {
                    showVideoSettingsModal = true
                    controlsVisible = true
                }
            } else {
                null
            },
            onSourcesClick = if (activeVideoId != null) { { openSourcesPanel() } } else null,
            onEpisodesClick = if (isSeries) { { openEpisodesPanel() } } else null,
            onOpenInExternalPlayer = args.onOpenInExternalPlayer?.let { openExternal ->
                {
                    val loadedSubtitles = addonSubtitles
                        .takeIf { it.isNotEmpty() }
                        ?.map { sub ->
                            SubtitleInput(
                                url = sub.url,
                                name = buildString {
                                    if (!sub.addonName.isNullOrBlank()) append("[${sub.addonName}] ")
                                    append(sub.display)
                                },
                                lang = sub.language,
                            )
                        }
                    openExternal(
                        ExternalPlayerPlaybackRequest(
                            sourceUrl = activeSourceUrl,
                            title = title,
                            streamTitle = activeStreamTitle,
                            sourceHeaders = activeSourceHeaders,
                            resumePositionMs = playbackSnapshot.positionMs,
                            subtitles = loadedSubtitles,
                            season = activeSeasonNumber,
                            episode = activeEpisodeNumber,
                            episodeTitle = activeEpisodeTitle,
                        ),
                    )
                }
            },
            onSubmitIntroClick = if (
                isSeries &&
                playerSettingsUiState.introSubmitEnabled &&
                playerSettingsUiState.introDbApiKey.isNotBlank()
            ) {
                { showSubmitIntroModal = true }
            } else {
                null
            },
            parentalWarnings = parentalWarnings,
            showParentalGuide = showParentalGuide,
            onParentalGuideAnimationComplete = { showParentalGuide = false },
            onScrubChange = { positionMs ->
                isScrubbingTimeline = true
                scrubbingPositionMs = positionMs
            },
            onScrubFinished = { positionMs ->
                isScrubbingTimeline = false
                scrubbingPositionMs = null
                playerController?.seekTo(positionMs)
                scheduleProgressSyncAfterSeek()
            },
            horizontalSafePadding = horizontalSafePadding,
            modifier = Modifier.fillMaxSize(),
        )
    }
}

internal fun releasePlayerBeforeNavigation(
    releasePlayer: (
        onReleased: () -> Unit,
        onReleaseFailed: (String) -> Unit,
    ) -> Unit,
    navigateBack: () -> Unit,
    onReleaseFailed: (String) -> Unit = {},
) {
    releasePlayer(navigateBack, onReleaseFailed)
}

internal fun releaseRetainedPlayerBeforeNavigation(
    controller: PlayerEngineController?,
    navigateBack: () -> Unit,
    onReleaseFailed: (String) -> Unit = {},
) {
    if (controller == null) {
        navigateBack()
    } else {
        controller.releaseBeforeNavigation(navigateBack, onReleaseFailed)
    }
}

private fun PlayerScreenRuntime.requestBack() {
    flushWatchProgress()
    val exitingController = playerLifecycleController
    args.onBack { afterRelease, releaseFailed ->
        val releaseAttemptId = playerReleaseSurfaceRetention.begin()
        try {
            releaseRetainedPlayerBeforeNavigation(
                controller = exitingController,
                navigateBack = {
                    if (!playerReleaseSurfaceRetention.finish(releaseAttemptId)) {
                        return@releaseRetainedPlayerBeforeNavigation
                    }
                    if (playerLifecycleController === exitingController) {
                        playerLifecycleController = null
                    }
                    if (playerController === exitingController) {
                        playerController = null
                    }
                    afterRelease()
                },
                onReleaseFailed = { message ->
                    if (!playerReleaseSurfaceRetention.finish(releaseAttemptId)) {
                        return@releaseRetainedPlayerBeforeNavigation
                    }
                    errorMessage = message
                    releaseFailed(message)
                },
            )
        } catch (failure: Throwable) {
            playerReleaseSurfaceRetention.finish(releaseAttemptId)
            throw failure
        }
    }
}

private fun PlayerScreenRuntime.handlePlayerControlsAction(action: PlayerControlsAction): Boolean {
    playerControlsLog.d { "action=$action ${playerControlLogContext()}" }
    when (action) {
        PlayerControlsAction.ToggleChrome -> {
            if (playerControlsLocked) {
                revealLockedOverlay()
            } else {
                controlsVisible = !controlsVisible
            }
        }
        PlayerControlsAction.RevealLockedOverlay -> revealLockedOverlay()
        PlayerControlsAction.Back -> requestBack()
        PlayerControlsAction.TogglePlayback -> {
            prepareTogglePlaybackForNativeFallback()
            return false
        }
        PlayerControlsAction.KeyboardTogglePlayback -> {
            prepareTogglePlaybackForNativeFallback(revealControls = false)
            return false
        }
        PlayerControlsAction.SeekBack -> {
            prepareSeekByForNativeFallback(-10_000L)
            return false
        }
        PlayerControlsAction.KeyboardSeekBack -> {
            prepareSeekByForNativeFallback(-10_000L, revealControls = false)
            return false
        }
        PlayerControlsAction.SeekForward -> {
            prepareSeekByForNativeFallback(10_000L)
            return false
        }
        PlayerControlsAction.KeyboardSeekForward -> {
            prepareSeekByForNativeFallback(10_000L, revealControls = false)
            return false
        }
        PlayerControlsAction.KeyboardVolumeDown,
        PlayerControlsAction.KeyboardVolumeUp -> {
            return false
        }
        PlayerControlsAction.ResizeMode -> cycleResizeMode()
        PlayerControlsAction.Speed -> cyclePlaybackSpeed()
        PlayerControlsAction.Subtitles -> {
            refreshTracks()
            showSubtitleModal = true
        }
        PlayerControlsAction.Audio -> {
            refreshTracks()
            showAudioModal = true
        }
        PlayerControlsAction.Sources -> {
            prepareSourcesForPlayerControls()
        }
        PlayerControlsAction.Episodes -> {
            prepareEpisodesForPlayerControls()
        }
        PlayerControlsAction.OpenExternalPlayer -> openInExternalPlayer()
        PlayerControlsAction.SubmitIntro -> {
            submitIntroStatusMessage = null
        }
        PlayerControlsAction.LockToggle -> {
            if (playerControlsLocked) unlockPlayerControls() else lockPlayerControls()
        }
        PlayerControlsAction.VideoSettings -> {
            if (isIos) {
                showVideoSettingsModal = true
                controlsVisible = true
            }
        }
        PlayerControlsAction.DoubleTapSeekBack -> {
            prepareDoubleTapSeekForNativeFallback(PlayerSeekDirection.Backward)
            return false
        }
        PlayerControlsAction.DoubleTapSeekForward -> {
            prepareDoubleTapSeekForNativeFallback(PlayerSeekDirection.Forward)
            return false
        }
    }
    return true
}

private fun PlayerScreenRuntime.handlePlayerControlsEvent(type: String, value: Double): Boolean {
    if (type.shouldLogPlayerControlsEvent()) {
        playerControlsLog.d { "event type=$type value=$value ${playerControlLogContext()}" }
    }
    when (type) {
        "cursorActivity" -> {
            if (!playerControlsLocked) {
                controlsVisible = true
                controlsActivityTick += 1
            }
        }
        "hideChrome" -> {
            controlsVisible = false
        }
        "keepChromeVisible" -> {
            controlsVisible = true
            controlsActivityTick += 1
        }
        "setPlaybackState",
        "setPlaybackStateQuiet" -> {
            shouldPlay = value >= 0.5
            if (type == "setPlaybackState") {
                controlsVisible = true
            }
        }
        "reloadSources" -> {
            prepareSourcesForPlayerControls(forceRefresh = true)
        }
        "selectSource" -> {
            val streams = sourceStreamsState.groups.flatMap { it.streams }
            val stream = streams.getOrNull(value.toInt()) ?: return true
            if (requestP2pConsentForPlayerControls(stream = stream, episode = null)) return true
            switchToSource(stream)
            playerControlsCloseModalsToken += 1
        }
        "selectEpisode" -> {
            val episode = playerMetaVideos.getOrNull(value.toInt()) ?: return true
            if (selectDownloadedEpisodeForPlayback(
                    parentMetaId = parentMetaId,
                    episode = episode,
                    onDownloadedEpisodeSelected = { item, video -> switchToDownloadedEpisode(item, video) },
                )
            ) {
                playerControlsCloseModalsToken += 1
            } else {
                requestEpisodeStreamsForPlayerControls(episode)
            }
        }
        "selectEpisodeStream" -> {
            val episode = episodeStreamsPanelState.selectedEpisode ?: return true
            val stream = episodeStreamsRepoState.groups.flatMap { it.streams }.getOrNull(value.toInt()) ?: return true
            if (requestP2pConsentForPlayerControls(stream = stream, episode = episode)) return true
            switchToEpisodeStream(stream, episode)
            playerControlsCloseModalsToken += 1
        }
        "backToEpisodes" -> {
            episodeStreamsPanelState = EpisodeStreamsPanelState()
            PlayerStreamsRepository.clearEpisodeStreams()
        }
        "reloadEpisodeStreams" -> {
            episodeStreamsPanelState.selectedEpisode?.let { requestEpisodeStreamsForPlayerControls(it, forceRefresh = true) }
        }
        "submitIntroSegment" -> {
            submitIntroSegmentType = when (value.toInt()) {
                1 -> "recap"
                2 -> "outro"
                else -> "intro"
            }
            submitIntroStatusMessage = null
        }
        "submitIntroStart" -> {
            val seconds = value.takeIf { it.isFinite() && it >= 0.0 } ?: 0.0
            submitIntroStartTimeSec = seconds
            submitIntroStartTimeStr = formatPlayerControlsSeconds(seconds)
            submitIntroStatusMessage = null
        }
        "submitIntroEnd" -> {
            val seconds = value.takeIf { it.isFinite() && it >= 0.0 } ?: 0.0
            submitIntroEndTimeSec = seconds
            submitIntroEndTimeStr = formatPlayerControlsSeconds(seconds)
            submitIntroStatusMessage = null
        }
        "submitIntroCommit" -> submitIntroFromPlayerControls()
        "skipInterval" -> {
            val interval = activeSkipInterval ?: return true
            playerController?.seekTo((interval.endTime * 1000).toLong())
            scheduleProgressSyncAfterSeek()
            skipIntervalDismissed = true
        }
        "playNextEpisode" -> {
            if (nextEpisodeInfo?.hasAired == true) {
                nextEpisodeAutoPlayJob?.cancel()
                playNextEpisode()
            }
        }
        "enableP2pForPlayerControls" -> enableP2pForPlayerControls()
        "cancelP2pForPlayerControls" -> {
            playerControlsPendingP2pSwitch = null
        }
        "subtitleTab" -> {
            activeSubtitleTab = when (value.toInt()) {
                1 -> SubtitleTab.Addons
                2 -> SubtitleTab.Style
                else -> SubtitleTab.BuiltIn
            }
        }
        "selectBuiltInSubtitleTrack" -> {
            val index = value.toInt()
            val wasCustom = useCustomSubtitles
            playerControlsLog.d {
                "selectBuiltInSubtitleTrack index=$index wasCustom=$wasCustom tracks=${subtitleTracks.size} ${playerControlLogContext()}"
            }
            selectedSubtitleIndex = index
            selectedAddonSubtitleId = null
            useCustomSubtitles = false
            persistInternalSubtitlePreference(subtitleTracks.firstOrNull { it.index == index })
            if (wasCustom) {
                playerController?.clearExternalSubtitleAndSelect(index)
            } else {
                playerController?.selectSubtitleTrack(index)
            }
        }
        "selectAudioTrack" -> {
            // The controls webview sends the track id (trackIdValue); map it back
            // to the logical index that selectAudioTrack() expects (falling back to
            // treating the value as an index if no id matches).
            val requestedId = value.toInt()
            val index = audioTracks.firstOrNull { it.id == requestedId.toString() }?.index
                ?: audioTracks.firstOrNull { it.index == requestedId }?.index
                ?: requestedId
            playerControlsLog.d {
                "selectAudioTrack id=$requestedId index=$index tracks=${audioTracks.size} ${playerControlLogContext()}"
            }
            selectedAudioIndex = index
            persistAudioPreference(audioTracks.firstOrNull { it.index == index })
            playerController?.selectAudioTrack(index)
        }
        "fetchAddonSubtitles" -> fetchAddonSubtitlesForActiveItem()
        "selectAddonSubtitle" -> {
            val addon = visibleAddonSubtitles.getOrNull(value.toInt()) ?: return true
            playerControlsLog.d {
                "selectAddonSubtitle index=${value.toInt()} addonId=${addon.id} language=${addon.language} ${playerControlLogContext()}"
            }
            selectedAddonSubtitleId = addon.id
            selectedSubtitleIndex = -1
            useCustomSubtitles = true
            persistAddonSubtitlePreference(addon)
            playerController?.setSubtitleUri(addon.url)
        }
        "subtitleDelayDelta" -> setSubtitleDelay((subtitleDelayMs + value.toInt()).coerceIn(SUBTITLE_DELAY_MIN_MS, SUBTITLE_DELAY_MAX_MS))
        "subtitleDelayReset" -> setSubtitleDelay(0)
        "subtitleAutoSyncCapture" -> captureSubtitleAutoSyncTime()
        "subtitleAutoSyncReload" -> loadSubtitleAutoSyncCues(force = true)
        "subtitleAutoSyncCue" -> {
            val cue = playerControlsNearestSubtitleCues().getOrNull(value.toInt()) ?: return true
            applySubtitleAutoSyncCue(cue)
        }
        "subtitleCustomStyleToggle" -> {
            PlayerSettingsRepository.setUseLibass(!playerSettingsUiState.useLibass)
        }
        "subtitleFontSizeDelta" -> {
            PlayerSettingsRepository.setSubtitleStyle(
                subtitleStyle.copy(fontSizeSp = (subtitleStyle.fontSizeSp + value.toInt()).coerceIn(subtitleFontSizeRangeSp)),
            )
        }
        "subtitleOutlineToggle" -> {
            PlayerSettingsRepository.setSubtitleStyle(subtitleStyle.copy(outlineEnabled = !subtitleStyle.outlineEnabled))
        }
        "subtitleBoldToggle" -> {
            PlayerSettingsRepository.setSubtitleStyle(subtitleStyle.copy(bold = !subtitleStyle.bold))
        }
        "subtitleBottomOffsetDelta" -> {
            PlayerSettingsRepository.setSubtitleStyle(
                subtitleStyle.copy(bottomOffset = (subtitleStyle.bottomOffset + value.toInt()).coerceIn(0, 200)),
            )
        }
        "subtitleTextColor" -> {
            SubtitleColorSwatches.getOrNull(value.toInt())?.let { color ->
                PlayerSettingsRepository.setSubtitleStyle(subtitleStyle.copy(textColor = color.copy(alpha = subtitleStyle.textColor.alpha)))
            }
        }
        "subtitleOutlineColor" -> {
            SubtitleOutlineColorSwatches.getOrNull(value.toInt())?.let { color ->
                PlayerSettingsRepository.setSubtitleStyle(
                    subtitleStyle.copy(outlineEnabled = true, outlineColor = color),
                )
            }
        }
        "subtitleTextOpacity" -> {
            val alpha = (value.toFloat() / 100f).coerceIn(0f, 1f)
            PlayerSettingsRepository.setSubtitleStyle(subtitleStyle.copy(textColor = subtitleStyle.textColor.copy(alpha = alpha)))
        }
        "subtitleStyleReset" -> PlayerSettingsRepository.setSubtitleStyle(SubtitleStyleState.DEFAULT)
        "parentalGuideComplete" -> {
            showParentalGuide = false
        }
        else -> return false
    }
    return true
}

private fun PlayerScreenRuntime.requestP2pConsentForPlayerControls(
    stream: StreamItem,
    episode: MetaVideo?,
): Boolean {
    val shouldRequestConsent = shouldRequestP2pConsentForPlayerControls(
        isP2pStream = isP2pStream(stream),
        shouldResolveToPlayableStream = DirectDebridPlaybackResolver.shouldResolveToPlayableStream(stream),
        p2pSettingsVisible = P2pSettingsRepository.isVisible,
        p2pEnabled = P2pSettingsRepository.uiState.value.p2pEnabled,
    )
    if (!shouldRequestConsent) return false
    playerControlsPendingP2pSwitch = PendingPlayerP2pSwitch(
        stream = stream,
        episode = episode,
        isAutoPlay = false,
    )
    return true
}

internal fun shouldRequestP2pConsentForPlayerControls(
    isP2pStream: Boolean,
    shouldResolveToPlayableStream: Boolean,
    p2pSettingsVisible: Boolean,
    p2pEnabled: Boolean,
): Boolean =
    isP2pStream &&
        !shouldResolveToPlayableStream &&
        p2pSettingsVisible &&
        !p2pEnabled

private fun PlayerScreenRuntime.enableP2pForPlayerControls() {
    val pending = playerControlsPendingP2pSwitch ?: return
    playerControlsPendingP2pSwitch = null
    P2pSettingsRepository.setP2pEnabled(true)
    val episode = pending.episode
    if (episode != null) {
        switchToP2pEpisodeStream(pending.stream, episode, pending.isAutoPlay)
    } else {
        switchToP2pSourceStream(pending.stream)
    }
    playerControlsCloseModalsToken += 1
}

private fun PlayerScreenRuntime.prepareSourcesForPlayerControls(forceRefresh: Boolean = false) {
    val vid = activeVideoId
    if (vid == null) {
        return
    }
    val requestType = contentType ?: parentMetaType
    PlayerStreamsRepository.loadSources(
        type = requestType,
        videoId = vid,
        season = activeSeasonNumber,
        episode = activeEpisodeNumber,
        forceRefresh = forceRefresh,
    )
}

private fun Color.toCssColorString(): String {
    val redInt = (red * 255f).roundToInt().coerceIn(0, 255)
    val greenInt = (green * 255f).roundToInt().coerceIn(0, 255)
    val blueInt = (blue * 255f).roundToInt().coerceIn(0, 255)
    val alphaValue = alpha.coerceIn(0f, 1f)
    return "rgba($redInt, $greenInt, $blueInt, ${alphaValue.toCssAlphaString()})"
}

private fun Float.toCssAlphaString(): String {
    val rounded = (this * 1000f).roundToInt() / 1000f
    return rounded.toString().trimEnd('0').trimEnd('.').ifEmpty { "0" }
}

private fun PlayerScreenRuntime.prepareEpisodesForPlayerControls() {
    if (!isSeries) return
    if (playerMetaVideos.isEmpty()) {
        scope.launch {
            playerMetaVideos = MetaDetailsRepository.fetch(parentMetaType, parentMetaId)?.videos ?: emptyList()
        }
    }
}

private fun PlayerScreenRuntime.requestEpisodeStreamsForPlayerControls(
    episode: MetaVideo,
    forceRefresh: Boolean = false,
) {
    PlayerStreamsRepository.loadEpisodeStreams(
        type = contentType ?: parentMetaType,
        videoId = episode.id,
        season = episode.season,
        episode = episode.episode,
        forceRefresh = forceRefresh,
    )
    episodeStreamsPanelState = EpisodeStreamsPanelState(showStreams = true, selectedEpisode = episode)
}

private fun PlayerScreenRuntime.submitIntroFromPlayerControls() {
    if (isSubmitIntroSubmitting) return
    val imdbId = activeSubmitIntroImdbId()
    val season = activeSeasonNumber
    val episode = activeEpisodeNumber
    val start = submitIntroStartTimeSec
    val end = submitIntroEndTimeSec
    if (imdbId.isNullOrBlank() || season == null || episode == null || start == null || end == null || end <= start) {
        submitIntroStatusMessage = "Check the start and end times."
        return
    }
    isSubmitIntroSubmitting = true
    submitIntroStatusMessage = null
    scope.launch {
        val result = SkipIntroRepository.submitIntro(
            imdbId = imdbId,
            season = season,
            episode = episode,
            startSec = start,
            endSec = end,
            segmentType = submitIntroSegmentType,
        )
        isSubmitIntroSubmitting = false
        if (result) {
            submitIntroStartTimeSec = 0.0
            submitIntroEndTimeSec = 0.0
            submitIntroStartTimeStr = "00:00"
            submitIntroEndTimeStr = "00:00"
            submitIntroSegmentType = "intro"
            submitIntroStatusMessage = null
            playerControlsCloseModalsToken += 1
            playerControlsSubmitIntroSuccessToken += 1
        } else {
            submitIntroStatusMessage = "Unable to submit timestamps."
        }
    }
}

private fun PlayerScreenRuntime.activeSubmitIntroContentKey(): String {
    val imdbId = activeSubmitIntroImdbId()?.takeIf { it.isNotBlank() } ?: return ""
    return "$imdbId:$activeSeasonNumber:$activeEpisodeNumber"
}

private fun PlayerScreenRuntime.activeSubmitIntroImdbId(): String? =
    activeVideoId?.split(":")?.firstOrNull()?.takeIf { it.startsWith("tt") }
        ?: parentMetaId.takeIf { it.startsWith("tt") }
        ?: metaUiState.meta?.id?.takeIf { it.startsWith("tt") }

@Composable
private fun skipPromptLabel(type: String?): String =
    when (type?.lowercase()) {
        "intro", "op", "mixed-op" -> stringResource(Res.string.player_skip_intro)
        "outro", "ed", "mixed-ed", "credits" -> stringResource(Res.string.player_skip_outro)
        "recap" -> stringResource(Res.string.player_skip_recap)
        else -> stringResource(Res.string.player_skip)
    }

private fun formatPlayerControlsSeconds(seconds: Double): String {
    val totalSeconds = seconds
        .takeIf { it.isFinite() && it >= 0.0 }
        ?.toLong()
        ?: 0L
    val minutes = totalSeconds / 60L
    val remainder = totalSeconds % 60L
    return "${minutes.toString().padStart(2, '0')}:${remainder.toString().padStart(2, '0')}"
}

private fun PlayerScreenRuntime.handlePlayerControlsScrubChange(positionMs: Long) {
    playerControlsLog.d { "scrubChange positionMs=$positionMs ${playerControlLogContext()}" }
    isScrubbingTimeline = true
    scrubbingPositionMs = positionMs
}

private fun PlayerScreenRuntime.handlePlayerControlsScrubFinished(positionMs: Long) {
    playerControlsLog.d { "scrubFinished positionMs=$positionMs controller=${playerController != null} ${playerControlLogContext()}" }
    isScrubbingTimeline = false
    scrubbingPositionMs = null
    playerController?.seekTo(positionMs)
    scheduleProgressSyncAfterSeek()
}

private fun PlayerScreenRuntime.playerControlLogContext(): String =
    "video=${activeVideoId ?: "none"} s=${activeSeasonNumber ?: "-"} e=${activeEpisodeNumber ?: "-"} " +
        "pos=${playbackSnapshot.positionMs} duration=${playbackSnapshot.durationMs} " +
        "speed=${playbackSnapshot.playbackSpeed} controller=${playerController != null}"

private fun String.shouldLogPlayerControlsEvent(): Boolean {
    val normalized = lowercase()
    return normalized.contains("audio") ||
        normalized.contains("subtitle") ||
        normalized.contains("speed") ||
        normalized.contains("scrub") ||
        normalized.contains("seek") ||
        normalized.contains("episode") ||
        normalized == "resize" ||
        normalized == "toggle"
}

private fun PlayerScreenRuntime.openInExternalPlayer() {
    val openExternal = args.onOpenInExternalPlayer ?: return
    val loadedSubtitles = addonSubtitles
        .takeIf { it.isNotEmpty() }
        ?.map { sub ->
            SubtitleInput(
                url = sub.url,
                name = buildString {
                    if (!sub.addonName.isNullOrBlank()) append("[${sub.addonName}] ")
                    append(sub.display)
                },
                lang = sub.language,
            )
        }
    openExternal(
        ExternalPlayerPlaybackRequest(
            sourceUrl = activeSourceUrl,
            title = title,
            streamTitle = activeStreamTitle,
            sourceHeaders = activeSourceHeaders,
            resumePositionMs = playbackSnapshot.positionMs,
            subtitles = loadedSubtitles,
        ),
    )
}

private fun PlayerScreenRuntime.buildPlayerControlFilters(
    groups: List<AddonStreamGroup> = sourceStreamsState.groups,
    allLabel: String,
    selectedFilter: String?,
): List<PlayerControlFilterItem> {
    if (groups.size <= 1) return emptyList()
    return buildList {
        add(PlayerControlFilterItem(id = "", label = allLabel, isSelected = selectedFilter == null))
        groups.distinctBy { it.addonId }.forEach { group ->
            add(
                PlayerControlFilterItem(
                    id = group.addonId,
                    label = group.addonName,
                    isSelected = selectedFilter == group.addonId,
                    isLoading = group.isLoading,
                    hasError = group.error != null,
                ),
            )
        }
    }
}

private fun PlayerScreenRuntime.buildPlayerControlEpisodeStreamFilters(
    allLabel: String,
    selectedFilter: String?,
): List<PlayerControlFilterItem> =
    buildPlayerControlFilters(
        groups = episodeStreamsRepoState.groups,
        allLabel = allLabel,
        selectedFilter = selectedFilter,
    )

@Composable
private fun PlayerScreenRuntime.buildPlayerControlSourceItems(): List<PlayerControlSourceItem> {
    val canResolveDebrid = DebridSettingsRepository.uiState.value.canResolvePlayableLinks
    val streamBadgeState = StreamBadgeSettingsRepository.uiState.value
    val showFileSizeBadges = streamBadgeState.showFileSizeBadges
    val showAddonLogo = streamBadgeState.showAddonLogo
    val badgePlacement = streamBadgeState.badgePlacement.name
    return sourceStreamsState.groups.flatMap { group ->
        group.streams.map { stream -> group.addonId to stream }
    }.mapIndexed { index, (filterId, stream) ->
        PlayerControlSourceItem(
            index = index,
            filterId = filterId,
            label = stream.streamLabel,
            subtitle = stream.streamSubtitle.orEmpty(),
            addonName = stream.addonName,
            addonLogo = stream.addonLogo.orEmpty(),
            showAddonLogo = showAddonLogo,
            isCurrent = isCurrentPlayerControlStream(stream),
            isEnabled = stream.isSelectableForPlayback(canResolveDebrid),
            badges = stream.badges.map {
                PlayerControlSourceBadgeItem(
                    name = it.name,
                    imageURL = it.imageURL,
                    tagColor = it.tagColor,
                    tagStyle = it.tagStyle,
                    borderColor = it.borderColor,
                )
            },
            formattedSize = if (showFileSizeBadges) formatStreamVideoSize(stream.behaviorHints.videoSize) else "",
            badgePlacement = badgePlacement,
        )
    }
}

@Composable
private fun PlayerScreenRuntime.buildPlayerControlEpisodeStreamItems(): List<PlayerControlSourceItem> {
    val canResolveDebrid = DebridSettingsRepository.uiState.value.canResolvePlayableLinks
    val streamBadgeState = StreamBadgeSettingsRepository.uiState.value
    val showFileSizeBadges = streamBadgeState.showFileSizeBadges
    val showAddonLogo = streamBadgeState.showAddonLogo
    val badgePlacement = streamBadgeState.badgePlacement.name
    return episodeStreamsRepoState.groups.flatMap { group ->
        group.streams.map { stream -> group.addonId to stream }
    }.mapIndexed { index, (filterId, stream) ->
        PlayerControlSourceItem(
            index = index,
            filterId = filterId,
            label = stream.streamLabel,
            subtitle = stream.streamSubtitle.orEmpty(),
            addonName = stream.addonName,
            addonLogo = stream.addonLogo.orEmpty(),
            showAddonLogo = showAddonLogo,
            isCurrent = false,
            isEnabled = stream.isSelectableForPlayback(canResolveDebrid),
            badges = stream.badges.map {
                PlayerControlSourceBadgeItem(
                    name = it.name,
                    imageURL = it.imageURL,
                    tagColor = it.tagColor,
                    tagStyle = it.tagStyle,
                    borderColor = it.borderColor,
                )
            },
            formattedSize = if (showFileSizeBadges) formatStreamVideoSize(stream.behaviorHints.videoSize) else "",
            badgePlacement = badgePlacement,
        )
    }
}

@Composable
private fun formatStreamVideoSize(bytes: Long?): String {
    if (bytes == null || bytes <= 0L) return ""
    val gib = bytes.toDouble() / (1024.0 * 1024.0 * 1024.0)
    val sizeLabel = if (gib >= 1.0) {
        val roundedGiB = kotlin.math.round(gib * 10.0) / 10.0
        "$roundedGiB ${localizedByteUnit("GB")}"
    } else {
        val mib = bytes.toDouble() / (1024.0 * 1024.0)
        "${kotlin.math.round(mib).toInt()} ${localizedByteUnit("MB")}"
    }
    return stringResource(Res.string.streams_size, sizeLabel)
}

private fun PlayerScreenRuntime.isCurrentPlayerControlStream(stream: StreamItem): Boolean {
    val activeKey = activeSourceIdentityKey
    val streamKey = stream.playerSourceIdentityKey()
    if (activeKey != null) {
        return streamKey == activeKey
    }
    val directUrl = stream.playableDirectUrl
    if (directUrl != null && directUrl == activeSourceUrl) return true
    val infoHash = stream.p2pInfoHash
    if (infoHash != null && infoHash == activeTorrentInfoHash) return true
    return false
}

@Composable
private fun PlayerScreenRuntime.buildPlayerControlAddonSubtitleItems(): List<PlayerControlAddonSubtitleItem> =
    visibleAddonSubtitles.mapIndexed { index, subtitle ->
        PlayerControlAddonSubtitleItem(
            index = index,
            id = subtitle.id,
            display = subtitle.display,
            language = subtitle.language,
            languageLabel = languageLabelForCode(subtitle.language),
            addonName = subtitle.addonName.orEmpty(),
            isSelected = subtitle.id == selectedAddonSubtitleId || subtitle.url == selectedAddonSubtitleId,
        )
    }

private data class PlayerControlSubtitleSelection(
    val languages: List<PlayerControlSubtitleLanguageItem>,
    val options: List<PlayerControlSubtitleOptionItem>,
    val selectedLanguageKey: String,
    val selectedOptionId: String,
)

@Composable
private fun PlayerScreenRuntime.buildPlayerControlSubtitleSelection(): PlayerControlSubtitleSelection {
    val selectedAddon = selectedAddonSubtitle
    val selectedLanguageKey = selectedSubtitleLanguageKey(
        subtitleTracks = subtitleTracks,
        selectedSubtitleIndex = selectedSubtitleIndex,
        selectedAddonSubtitle = selectedAddon,
    )
    val selectedOptionId = selectedSubtitleOptionId(
        subtitleTracks = subtitleTracks,
        selectedSubtitleIndex = selectedSubtitleIndex,
        selectedAddonSubtitle = selectedAddon,
    ).orEmpty()
    val languageItems = buildSubtitleLanguageItems(
        subtitleTracks = subtitleTracks,
        addonSubtitles = visibleAddonSubtitles,
        preferredLanguage = playerSettingsUiState.preferredSubtitleLanguage,
        secondaryPreferredLanguage = playerSettingsUiState.secondaryPreferredSubtitleLanguage,
        showOnlyPreferredLanguages = subtitleStyle.showOnlyPreferredLanguages,
        selectedLanguageKey = selectedLanguageKey,
    )
    val noneLabel = stringResource(Res.string.compose_player_none)
    val unknownLabel = stringResource(Res.string.subtitle_language_unknown)
    val builtInLabel = stringResource(Res.string.compose_player_built_in)
    val addonLabel = stringResource(Res.string.addon_title)
    val forcedLabel = stringResource(Res.string.settings_playback_option_forced)
    val languages = languageItems.map { item ->
        PlayerControlSubtitleLanguageItem(
            key = item.key,
            label = when (item.key) {
                SubtitleOffLanguageKey -> noneLabel
                SubtitleUnknownLanguageKey -> unknownLabel
                else -> languageLabelForCode(item.key)
            },
            count = item.count,
            isSelected = item.key == selectedLanguageKey,
        )
    }
    val options = languageItems.flatMap { language ->
        buildSubtitleSelectionOptions(
            languageKey = language.key,
            subtitleTracks = subtitleTracks,
            addonSubtitles = visibleAddonSubtitles,
        ).map { option ->
            when (option) {
                is SubtitleSelectionOption.BuiltIn -> PlayerControlSubtitleOptionItem(
                    id = option.id,
                    languageKey = language.key,
                    kind = "builtIn",
                    index = option.track.index,
                    sourceLabel = builtInLabel,
                    title = localizedTrackDisplayName(
                        option.track.label,
                        option.track.language,
                        option.track.index,
                    ),
                    metadata = forcedLabel.takeIf { option.track.isForced }.orEmpty(),
                    isSelected = option.id == selectedOptionId,
                )

                is SubtitleSelectionOption.Addon -> {
                    val title = languageLabelForCode(option.subtitle.language)
                    PlayerControlSubtitleOptionItem(
                        id = option.id,
                        languageKey = language.key,
                        kind = "addon",
                        index = visibleAddonSubtitles.indexOf(option.subtitle).coerceAtLeast(0),
                        sourceLabel = option.subtitle.addonName ?: addonLabel,
                        title = title,
                        metadata = option.subtitle.display.takeIf {
                            it.isNotBlank() && it != title
                        }.orEmpty(),
                        isSelected = option.id == selectedOptionId,
                    )
                }
            }
        }
    }
    return PlayerControlSubtitleSelection(
        languages = languages,
        options = options,
        selectedLanguageKey = selectedLanguageKey,
        selectedOptionId = selectedOptionId,
    )
}

private fun PlayerScreenRuntime.buildPlayerControlSubtitleCueItems(): List<PlayerControlSubtitleCueItem> =
    playerControlsNearestSubtitleCues().mapIndexed { index, cue ->
        PlayerControlSubtitleCueItem(
            index = index,
            timeMs = cue.startTimeMs,
            timeLabel = formatPlayerControlsCueTimestamp(cue.startTimeMs),
            text = cue.text,
        )
    }

private fun PlayerScreenRuntime.playerControlsNearestSubtitleCues(): List<SubtitleSyncCue> {
    val capturedPositionMs = subtitleAutoSyncState.capturedPositionMs ?: return emptyList()
    return subtitleAutoSyncState.cues
        .sortedBy { abs(it.startTimeMs - capturedPositionMs) }
        .take(5)
}

private fun formatPlayerControlsCueTimestamp(timeMs: Long): String {
    val totalSeconds = (timeMs / 1000L).coerceAtLeast(0L)
    val minutes = totalSeconds / 60L
    val seconds = totalSeconds % 60L
    return "${minutes}:${seconds.toString().padStart(2, '0')}"
}

@Composable
private fun PlayerScreenRuntime.buildPlayerControlEpisodeItems(): List<PlayerControlEpisodeItem> {
    val items = mutableListOf<PlayerControlEpisodeItem>()
    for ((index, video) in playerMetaVideos.withIndex()) {
        if (video.season == null && video.episode == null) continue
        val episodeVideoId = buildPlaybackVideoId(
            parentMetaId = parentMetaId,
            seasonNumber = video.season,
            episodeNumber = video.episode,
            fallbackVideoId = video.id,
        )
        val isWatched = watchProgressUiState.byVideoId[episodeVideoId]?.isEffectivelyCompleted == true ||
            WatchingState.isEpisodeWatched(
                watchedKeys = watchedUiState.watchedKeys,
                metaType = parentMetaType,
                metaId = parentMetaId,
                episode = video,
            )
        items.add(
            PlayerControlEpisodeItem(
                index = index,
                id = video.id,
                title = video.title,
                code = video.playerControlsEpisodeCode(),
                overview = video.overview.orEmpty(),
                thumbnail = video.thumbnail.orEmpty(),
                released = video.released
                    ?.takeIf { it.isNotBlank() }
                    ?.let(::formatReleaseDateForDisplay)
                    .orEmpty(),
                season = video.season?.coerceAtLeast(0) ?: 0,
                episode = video.episode ?: 0,
                isCurrent = video.season == activeSeasonNumber && video.episode == activeEpisodeNumber,
                isWatched = isWatched,
            ),
        )
    }
    return items
}

@Composable
private fun PlayerScreenRuntime.buildPlayerControlSeasonItems(
    episodes: List<PlayerControlEpisodeItem>,
): List<PlayerControlSeasonItem> {
    val availableSeasons = episodes
        .map { it.season }
        .distinct()
        .let { seasons ->
            seasons.filter { it > 0 }.sorted() + seasons.filter { it == 0 }
        }
    val items = mutableListOf<PlayerControlSeasonItem>()
    for (season in availableSeasons) {
        val label = if (season == 0) {
            stringResource(Res.string.episodes_specials)
        } else {
            stringResource(Res.string.episodes_season, season)
        }
        items.add(
            PlayerControlSeasonItem(
                season = season,
                label = label,
                isSelected = activeSeasonNumber == season,
            ),
        )
    }
    return items
}

@Composable
private fun MetaVideo.playerControlsEpisodeCode(): String =
    when {
        season != null && episode != null -> stringResource(Res.string.compose_player_episode_code_full, season, episode)
        episode != null -> stringResource(Res.string.compose_player_episode_code_episode_only, episode)
        else -> ""
    }

@Composable
private fun BoxScope.RenderPlaybackOverlays(
    runtime: PlayerScreenRuntime,
    displayedPositionMs: Long,
    currentGestureFeedback: GestureFeedbackState?,
    p2pInitialLoadingMessage: String?,
    p2pInitialLoadingProgress: Float?,
    showP2pRebufferStats: Boolean,
    p2pRebufferMessage: String?,
    p2pRebufferProgress: Float?,
    suppressOpeningOverlay: Boolean,
) {
    runtime.run {
        PlayerPlaybackOverlays(
            playerControlsLocked = playerControlsLocked,
            lockedOverlayVisible = lockedOverlayVisible,
            playbackSnapshot = playbackSnapshot,
            displayedPositionMs = displayedPositionMs,
            metrics = metrics,
            horizontalSafePadding = horizontalSafePadding,
            onUnlock = { unlockPlayerControls() },
            showOpeningOverlay = playerSettingsUiState.showLoadingOverlay &&
                !initialLoadCompleted &&
                errorMessage == null &&
                !suppressOpeningOverlay,
            backdropArtwork = background ?: poster,
            logo = logo,
            title = title,
            onBackWithProgress = { requestBack() },
            p2pInitialLoadingMessage = p2pInitialLoadingMessage,
            p2pInitialLoadingProgress = p2pInitialLoadingProgress,
            showP2pRebufferStats = showP2pRebufferStats,
            p2pRebufferMessage = p2pRebufferMessage,
            p2pRebufferProgress = p2pRebufferProgress,
            currentGestureFeedback = currentGestureFeedback,
            renderedGestureFeedback = renderedGestureFeedback,
            initialLoadCompleted = initialLoadCompleted,
            pausedOverlayVisible = pausedOverlayVisible,
            activeSkipInterval = activeSkipInterval.takeUnless { isDesktop },
            skipIntervalDismissed = skipIntervalDismissed,
            controlsVisible = controlsVisible,
            onSkipInterval = { interval ->
                val rawMs = (interval.endTime * 1000.0).toLong()
                val durationMs = playbackSnapshot.durationMs
                val seekMs = if (durationMs > 0L) rawMs.coerceAtMost(durationMs - 1) else rawMs
                playerController?.seekTo(seekMs)
                scheduleProgressSyncAfterSeek()
                skipIntervalDismissed = true
            },
            onDismissSkipInterval = { skipIntervalDismissed = true },
            sliderEdgePadding = sliderEdgePadding,
            overlayBottomPadding = overlayBottomPadding,
            isSeries = isSeries,
            nextEpisodeInfo = nextEpisodeInfo,
            showNextEpisodeCard = showNextEpisodeCard && !isDesktop,
            nextEpisodeAutoPlaySearching = nextEpisodeAutoPlaySearching,
            nextEpisodeAutoPlaySourceName = nextEpisodeAutoPlaySourceName,
            nextEpisodeAutoPlayCountdown = nextEpisodeAutoPlayCountdown,
            blurUnwatchedEpisodes = metaScreenSettingsUiState.blurUnwatchedEpisodes,
            onPlayNextEpisode = {
                nextEpisodeAutoPlayJob?.cancel()
                playNextEpisode()
            },
            onDismissNextEpisode = {
                nextEpisodeAutoPlayJob?.cancel()
                nextEpisodeCardDismissed = true
                showNextEpisodeCard = false
                nextEpisodeAutoPlaySearching = false
                nextEpisodeAutoPlaySourceName = null
                nextEpisodeAutoPlayCountdown = null
            },
            errorMessage = errorMessage,
            onDismissError = { requestBack() },
        )
    }
}

@Composable
private fun PlayerScreenRuntime.RenderPlayerModals(displayedPositionMs: Long) {
    PlayerScreenModalHosts(
        pendingP2pSwitch = pendingP2pSwitch,
        onPendingP2pSwitchChanged = { pendingP2pSwitch = it },
        onP2pEpisodeStreamSelected = { stream, episode, isAutoPlay ->
            switchToP2pEpisodeStream(stream, episode, isAutoPlay)
        },
        onP2pSourceStreamSelected = { stream -> switchToP2pSourceStream(stream) },
        onNextEpisodeAutoPlaySearchingChanged = { nextEpisodeAutoPlaySearching = it },
        onNextEpisodeAutoPlayCountdownChanged = { nextEpisodeAutoPlayCountdown = it },
        onNextEpisodeAutoPlaySourceNameChanged = { nextEpisodeAutoPlaySourceName = it },
        showAudioModal = showAudioModal,
        audioTracks = audioTracks,
        selectedAudioIndex = selectedAudioIndex,
        onAudioTrackSelected = { index ->
            selectedAudioIndex = index
            persistAudioPreference(audioTracks.firstOrNull { it.index == index })
            playerController?.selectAudioTrack(index)
            scope.launch {
                kotlinx.coroutines.delay(200)
                showAudioModal = false
            }
        },
        onAudioModalDismissed = { showAudioModal = false },
        showSubtitleModal = showSubtitleModal,
        subtitleTracks = subtitleTracks,
        selectedSubtitleIndex = selectedSubtitleIndex,
        addonSubtitles = visibleAddonSubtitles,
        selectedAddonSubtitleId = selectedAddonSubtitleId,
        isLoadingAddonSubtitles = isLoadingAddonSubtitles,
        subtitleStyle = subtitleStyle,
        subtitleDelayMs = subtitleDelayMs,
        selectedAddonSubtitle = selectedAddonSubtitle,
        subtitleAutoSyncState = subtitleAutoSyncState,
        onBuiltInSubtitleTrackSelected = { index ->
            val wasCustom = useCustomSubtitles
            isUserExplicitSubtitleSelection = true
            preferredSubtitleSelectionApplied = true
            selectedSubtitleIndex = index
            selectedAddonSubtitleId = null
            useCustomSubtitles = false
            persistInternalSubtitlePreference(subtitleTracks.firstOrNull { it.index == index })
            if (wasCustom) {
                playerController?.clearExternalSubtitleAndSelect(index)
            } else {
                playerController?.selectSubtitleTrack(index)
            }
        },
        onAddonSubtitleSelected = { addon ->
            isUserExplicitSubtitleSelection = true
            selectedAddonSubtitleId = addon.selectionKey
            selectedSubtitleIndex = -1
            useCustomSubtitles = true
            preferredSubtitleSelectionApplied = true
            persistAddonSubtitlePreference(addon)
            playerController?.setSubtitleUri(addon.url)
        },
        onFetchAddonSubtitles = { fetchAddonSubtitlesForActiveItem() },
        onSubtitleStyleChanged = PlayerSettingsRepository::setSubtitleStyle,
        onSubtitleDelayChanged = { delayMs -> setSubtitleDelay(delayMs) },
        onSubtitleDelayReset = { setSubtitleDelay(0) },
        onAutoSyncCapture = { captureSubtitleAutoSyncTime() },
        onAutoSyncCueSelected = { cue -> applySubtitleAutoSyncCue(cue) },
        onAutoSyncReload = { loadSubtitleAutoSyncCues(force = true) },
        onSubtitleModalDismissed = { showSubtitleModal = false },
        showVideoSettingsModal = showVideoSettingsModal,
        playerSettings = playerSettingsUiState,
        onVideoSettingsChanged = {
            playerController?.configureIosVideoOutput(PlayerSettingsRepository.uiState.value)
        },
        onVideoSettingsModalDismissed = { showVideoSettingsModal = false },
        showSourcesPanel = showSourcesPanel,
        sourceStreamsState = sourceStreamsState,
        contentTitle = title,
        activeEpisodeTitle = activeEpisodeTitle,
        activeSourceUrl = activeSourceUrl,
        activeStreamTitle = activeStreamTitle,
        onSourceFilterSelected = PlayerStreamsRepository::selectSourceFilter,
        onSourceStreamSelected = { stream -> switchToSource(stream) },
        onReloadSources = {
            val vid = activeVideoId
            if (vid != null) {
                PlayerStreamsRepository.loadSources(
                    type = contentType ?: parentMetaType,
                    videoId = vid,
                    season = activeSeasonNumber,
                    episode = activeEpisodeNumber,
                    forceRefresh = true,
                )
            }
        },
        onSourcesPanelDismissed = {
            showSourcesPanel = false
            controlsVisible = true
        },
        isSeries = isSeries,
        showEpisodesPanel = showEpisodesPanel,
        allEpisodes = playerMetaVideos,
        parentMetaType = parentMetaType,
        parentMetaId = parentMetaId,
        activeSeasonNumber = activeSeasonNumber,
        activeEpisodeNumber = activeEpisodeNumber,
        watchProgressByVideoId = watchProgressUiState.byVideoIdForContent(parentMetaId),
        watchedKeys = watchedUiState.watchedKeys,
        blurUnwatchedEpisodes = metaScreenSettingsUiState.blurUnwatchedEpisodes,
        episodeStreamsPanelState = episodeStreamsPanelState,
        episodeStreamsRepoState = episodeStreamsRepoState,
        onEpisodeSelectedForDownload = { episode ->
            selectDownloadedEpisodeForPlayback(
                parentMetaId = parentMetaId,
                episode = episode,
                onDownloadedEpisodeSelected = { item, video -> switchToDownloadedEpisode(item, video) },
            )
        },
        onEpisodeStreamsRequested = { episode ->
            PlayerStreamsRepository.loadEpisodeStreams(
                type = contentType ?: parentMetaType,
                videoId = episode.id,
                season = episode.season,
                episode = episode.episode,
            )
            episodeStreamsPanelState = EpisodeStreamsPanelState(showStreams = true, selectedEpisode = episode)
        },
        onEpisodeStreamFilterSelected = PlayerStreamsRepository::selectEpisodeStreamsFilter,
        onEpisodeStreamSelected = { stream, episode -> switchToEpisodeStream(stream, episode) },
        onBackToEpisodes = {
            episodeStreamsPanelState = EpisodeStreamsPanelState()
            PlayerStreamsRepository.clearEpisodeStreams()
        },
        onReloadEpisodeStreams = {
            val episode = episodeStreamsPanelState.selectedEpisode
            if (episode != null) {
                PlayerStreamsRepository.loadEpisodeStreams(
                    type = contentType ?: parentMetaType,
                    videoId = episode.id,
                    season = episode.season,
                    episode = episode.episode,
                    forceRefresh = true,
                )
            }
        },
        onEpisodesPanelDismissed = {
            showEpisodesPanel = false
            episodeStreamsPanelState = EpisodeStreamsPanelState()
            PlayerStreamsRepository.clearEpisodeStreams()
            controlsVisible = true
        },
        showSubmitIntroModal = showSubmitIntroModal,
        activeVideoId = activeVideoId,
        metaUiState = metaUiState,
        displayedPositionMs = displayedPositionMs,
        submitIntroSegmentType = submitIntroSegmentType,
        onSubmitIntroSegmentTypeChanged = { submitIntroSegmentType = it },
        submitIntroStartTimeStr = submitIntroStartTimeStr,
        onSubmitIntroStartTimeChanged = { submitIntroStartTimeStr = it },
        submitIntroEndTimeStr = submitIntroEndTimeStr,
        onSubmitIntroEndTimeChanged = { submitIntroEndTimeStr = it },
        onSubmitIntroDismissed = { showSubmitIntroModal = false },
        onSubmitIntroSuccess = {
            submitIntroStartTimeSec = 0.0
            submitIntroEndTimeSec = 0.0
            submitIntroStatusMessage = null
            submitIntroStartTimeStr = "00:00"
            submitIntroEndTimeStr = "00:00"
            submitIntroSegmentType = "intro"
            showSubmitIntroModal = false
        },
    )
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
                                // Browsing: nothing to show, so clear the card once and idle.
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
 * Movie:  name = details = title, state = release year.
 */
private fun PresenceSnapshot.Player.buildActivity(): DiscordActivity {
    val releaseYear = year?.trim()?.takeIf { it.isNotEmpty() }
    val episode = episodeTitle?.trim()?.takeIf { it.isNotEmpty() }

    var activityName = title
    var details = if (isSeries) episode ?: title else title
    var stateText = if (isSeries) "S${seasonNumber}E${episodeNumber}" else releaseYear

    // A paused player reports no timestamps at all, so Discord shows the word instead of an
    // elapsed counter that would otherwise keep climbing while the video is not moving.
    if (!isPlaying) {
        stateText = if (stateText.isNullOrBlank()) "Paused" else "$stateText \u2022 Paused"
    }

    val largeText = if (releaseYear != null) "$title ($releaseYear)" else title

    return DiscordActivity(
        type = DiscordActivityTypes.WATCHING,
        name = activityName,
        details = details,
        state = stateText,
        // start + end draws a live progress bar with the time remaining. A paused player gets
        // neither bound.
        timestamps = if (isPlaying) playbackTimestamps() else null,
        assets = DiscordActivityAssets(
            largeImage = posterUrl?.toDiscordImageUrl() ?: NuvioIconUrl,
            largeText = largeText,
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

Write-RepoFile ".github\workflows\update-drp.yml" @'
name: Update from upstream and build

# One-button updater.
#
# Instead of re-applying a diff (which breaks every time upstream edits the
# same lines), this keeps the Rich Presence files in their own folder, drp/,
# which upstream never touches. Every run:
#
#   1. takes a clean checkout of the LATEST upstream Dev
#   2. copies the drp/ files over it
#   3. builds a fresh MSI
#
# That cannot conflict, and it always builds against current upstream.
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
          echo "--- Rich Presence files found in drp/ ---"
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
          cp -r "${RUNNER_TEMP}/overlay/." .
          echo "--- Rich Presence files now in place ---"
          for f in \
            "composeApp/src/commonMain/kotlin/com/nuvio/app/core/ui/AppPresenceState.kt" \
            "composeApp/src/commonMain/kotlin/com/nuvio/app/features/player/PlayerScreenRuntimeUi.kt" \
            "composeApp/src/desktopMain/kotlin/com/nuvio/app/features/discordrpc/DiscordActivity.kt" \
            "composeApp/src/desktopMain/kotlin/com/nuvio/app/features/discordrpc/DiscordIpcClient.kt" \
            "composeApp/src/desktopMain/kotlin/com/nuvio/app/features/discordrpc/DiscordPresenceManager.kt" ; do
            if [[ ! -f "${f}" ]]; then
              echo "::error::Missing after overlay: ${f}" >&2
              exit 1
            fi
          done
          echo "all 5 files present"
          git status --short

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
& git commit -m "discord: playback-only presence, fix null buttons payload"
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
