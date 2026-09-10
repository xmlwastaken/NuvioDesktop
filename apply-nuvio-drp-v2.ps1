# =====================================================================
#  Nuvio Discord Rich Presence - v2 changes
#  Run this ONCE from PowerShell. It overwrites 7 files in your local
#  NuvioDesktop clone, commits them, and pushes to the Dev branch.
#
#  1. Save this file to  C:\Users\XML\NuvioDesktop\apply-nuvio-drp-v2.ps1
#  2. Open PowerShell and run:
#         cd C:\Users\XML\NuvioDesktop
#         powershell -ExecutionPolicy Bypass -File .\apply-nuvio-drp-v2.ps1
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
Write-Host "Writing 7 files into $repo ..." -ForegroundColor Cyan
Write-Host ""
Write-RepoFile "composeApp\src\commonMain\kotlin\com\nuvio\app\core\ui\AppPresenceState.kt" @'
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

    /**
     * What is currently typed into the search box.
     *
     * This lives outside [PresenceSnapshot] on purpose: the search screen owns the text field but
     * the app shell owns presence publishing, and the two fall out of sync every time a details
     * page is pushed on top of the search tab. Keeping the query here means the shell can always
     * rebuild a correct snapshot, including when the user navigates back to a still-filled search.
     */
    private val _searchQuery = MutableStateFlow("")
    val searchQuery: StateFlow<String> = _searchQuery.asStateFlow()

    fun publishSearchQuery(query: String) {
        _searchQuery.value = query
    }
}

internal sealed interface PresenceSnapshot {
    /**
     * Identity of "what the user is looking at", ignoring volatile fields such as the playback
     * position. Lets a consumer tell a real context switch (different tab, different title) apart
     * from a routine refresh of the same context, so an elapsed timer can start at the right time.
     */
    val presenceKey: String

    data class Tab(
        val tab: AppScreenTab,
        /** Text typed into the search box; only meaningful for [AppScreenTab.Search]. */
        val searchQuery: String = "",
    ) : PresenceSnapshot {
        override val presenceKey: String get() = "tab:${tab.name}:$searchQuery"
    }

    data class Details(
        val title: String,
        val posterUrl: String? = null,
        /** Release info as reported by the addon, e.g. `2024` or `2011-2019`. */
        val year: String? = null,
        /** Stremio-style catalogue id of the item being viewed, e.g. `tt0944947`. */
        val metaId: String? = null,
        val metaType: String? = null,
    ) : PresenceSnapshot {
        override val presenceKey: String get() = "details:${metaId ?: title}"
    }

    data class Player(
        /** Series or movie name - the headline of the Discord card. */
        val title: String,
        val seasonNumber: Int? = null,
        val episodeNumber: Int? = null,
        val episodeTitle: String? = null,
        /** Release info as reported by the addon, e.g. `2024` or `2011-2019`. */
        val year: String? = null,
        val posterUrl: String?,
        val isPlaying: Boolean,
        val positionMs: Long,
        /** Total runtime of the current item, or 0 when unknown (live streams, still loading). */
        val durationMs: Long = 0L,
        /** Stremio-style catalogue id of the parent item, e.g. `tt0944947` or `kitsu:12345`. */
        val metaId: String? = null,
        /** `movie` or `series`. */
        val metaType: String? = null,
    ) : PresenceSnapshot {
        val isSeries: Boolean get() = seasonNumber != null && episodeNumber != null

        override val presenceKey: String
            get() = "player:${metaId ?: title}:$seasonNumber:$episodeNumber"
    }
}

'@

Write-RepoFile "composeApp\src\commonMain\kotlin\com\nuvio\app\MainAppContent.kt" @'
package com.nuvio.app

import androidx.compose.animation.ExperimentalSharedTransitionApi
import androidx.compose.animation.SharedTransitionLayout
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.CheckCircleOutline
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.zIndex
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation3.runtime.NavKey
import androidx.navigation3.runtime.entryProvider
import androidx.navigation3.runtime.rememberNavBackStack
import androidx.navigation3.runtime.rememberSaveableStateHolderNavEntryDecorator
import androidx.navigation3.ui.LocalNavAnimatedContentScope
import androidx.navigation3.ui.NavDisplay
import com.nuvio.app.core.auth.AuthRepository
import com.nuvio.app.core.auth.AuthState
import com.nuvio.app.core.auth.DeviceSessionRegistration
import com.nuvio.app.core.build.AppFeaturePolicy
import com.nuvio.app.core.deeplink.AppDeepLink
import com.nuvio.app.core.deeplink.AppDeepLinkRepository
import com.nuvio.app.core.format.formatReleaseDateForDisplay
import com.nuvio.app.core.network.NetworkCondition
import com.nuvio.app.core.network.NetworkStatusRepository
import com.nuvio.app.core.sync.AppForegroundMonitor
import com.nuvio.app.core.sync.AppVisibility
import com.nuvio.app.core.sync.ProfileSettingsSync
import com.nuvio.app.core.sync.SyncManager
import com.nuvio.app.core.ui.DisintegrationRequestController
import com.nuvio.app.core.ui.NativeTabBridge
import com.nuvio.app.core.ui.NuvioCardDepthSurface
import com.nuvio.app.core.ui.NuvioContinueWatchingActionSheet
import com.nuvio.app.core.ui.NuvioFloatingPrompt
import com.nuvio.app.core.ui.NuvioPosterZoomActionOverlay
import com.nuvio.app.core.ui.NuvioStatusModal
import com.nuvio.app.core.ui.NuvioToastController
import com.nuvio.app.core.ui.NuvioToastHost
import com.nuvio.app.core.ui.PosterZoomAnchor
import com.nuvio.app.core.ui.PosterZoomAnchorHolder
import com.nuvio.app.core.ui.PosterZoomOverlayAction
import com.nuvio.app.core.ui.PosterZoomOverlayExitAnimation
import com.nuvio.app.core.ui.TrackingListPickerDialog
import com.nuvio.app.core.ui.isLiquidGlassNativeTabBarSupported
import com.nuvio.app.core.ui.localizedContinueWatchingSubtitle
import com.nuvio.app.core.ui.nuvio
import com.nuvio.app.core.ui.platformExitApp
import com.nuvio.app.features.addons.AddAddonResult
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.addons.enabledAddons
import com.nuvio.app.features.addons.isWaitingForFirstEnabledManifest
import com.nuvio.app.features.catalog.CatalogTarget
import com.nuvio.app.features.cloud.CloudLibraryContentType
import com.nuvio.app.features.cloud.CloudLibraryFile
import com.nuvio.app.features.cloud.CloudLibraryItem
import com.nuvio.app.features.cloud.CloudLibraryPlaybackResult
import com.nuvio.app.features.cloud.CloudLibraryPlaybackTargetLookupResult
import com.nuvio.app.features.cloud.CloudLibraryRepository
import com.nuvio.app.features.cloud.cloudLibraryDisplayArtworkUrl
import com.nuvio.app.features.cloud.playbackVideoId
import com.nuvio.app.features.cloud.providerPosterUrl
import com.nuvio.app.features.collection.CollectionRepository
import com.nuvio.app.features.collection.CollectionSyncService
import com.nuvio.app.features.details.MetaDetailsRepository
import com.nuvio.app.features.downloads.DownloadItem
import com.nuvio.app.features.downloads.DownloadsRepository
import com.nuvio.app.features.home.HomeCatalogSection
import com.nuvio.app.features.home.HomeCatalogSettingsRepository
import com.nuvio.app.features.home.HomeRepository
import com.nuvio.app.features.home.buildAddonCatalogRefreshSignature
import com.nuvio.app.features.home.components.shouldBlurContinueWatchingArtwork
import com.nuvio.app.features.library.LibraryItem
import com.nuvio.app.features.library.LibraryRepository
import com.nuvio.app.features.library.LibrarySection
import com.nuvio.app.features.library.LibrarySortOption
import com.nuvio.app.features.library.LibrarySourceMode
import com.nuvio.app.features.library.PendingTrackingMembershipRemoval
import com.nuvio.app.features.library.TrackingMembershipRemovalConfirmationHost
import com.nuvio.app.features.library.executeTrackingMembershipOperation
import com.nuvio.app.features.library.librarySectionItemKey
import com.nuvio.app.features.library.showTrackingMembershipRewriteFeedback
import com.nuvio.app.features.library.toLibraryItem
import com.nuvio.app.features.library.toMetaPreview
import com.nuvio.app.features.membership.MemberAccessRepository
import com.nuvio.app.features.notifications.EpisodeReleaseNotificationsRepository
import com.nuvio.app.features.p2p.P2pSettingsRepository
import com.nuvio.app.features.player.ExternalPlayerIntentResult
import com.nuvio.app.features.player.ExternalPlayerPlatform
import com.nuvio.app.features.player.PlayerLaunch
import com.nuvio.app.features.player.PlayerLaunchStore
import com.nuvio.app.features.player.PlayerPlaybackSnapshot
import com.nuvio.app.features.player.PlayerSettingsRepository
import com.nuvio.app.features.player.SubtitleLanguageOption
import com.nuvio.app.features.player.prepareExternalPlayerLaunch
import com.nuvio.app.features.player.rememberExternalPlayerLauncher
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.features.settings.AccountSettingsScreen
import com.nuvio.app.features.settings.AddonsSettingsScreen
import com.nuvio.app.features.settings.ContinueWatchingSettingsScreen
import com.nuvio.app.features.settings.HomescreenSettingsScreen
import com.nuvio.app.features.settings.LicensesAttributionsSettingsScreen
import com.nuvio.app.features.settings.MetaScreenSettingsScreen
import com.nuvio.app.features.settings.PluginsSettingsScreen
import com.nuvio.app.features.settings.SupportersContributorsSettingsScreen
import com.nuvio.app.features.settings.ThemeSettingsRepository
import com.nuvio.app.features.streams.BingeGroupCacheRepository
import com.nuvio.app.features.streams.StreamAutoPlayPolicy
import com.nuvio.app.features.streams.StreamLaunch
import com.nuvio.app.features.streams.StreamLaunchStore
import com.nuvio.app.features.streams.StreamsRepository
import com.nuvio.app.features.tracking.TrackingLibraryTab
import com.nuvio.app.features.tracking.TrackingMembershipApplyResult
import com.nuvio.app.features.tracking.TrackingProviderId
import com.nuvio.app.features.tracking.TrackingScrobbleAction
import com.nuvio.app.features.tracking.TrackingScrobbleCoordinator
import com.nuvio.app.features.tracking.TrackingScrobbleEvent
import com.nuvio.app.features.tracking.buildTrackingMediaReference
import com.nuvio.app.features.tracking.toggleTrackingLibraryMembership
import com.nuvio.app.features.updater.AppUpdaterHost
import com.nuvio.app.features.updater.AppUpdaterPlatform
import com.nuvio.app.features.updater.rememberAppUpdaterController
import com.nuvio.app.features.watched.WatchedRepository
import com.nuvio.app.features.watching.application.WatchingActions
import com.nuvio.app.features.watching.application.WatchingState
import com.nuvio.app.features.watching.domain.isShortPlaceholderDuration
import com.nuvio.app.features.watchprogress.ContinueWatchingItem
import com.nuvio.app.features.watchprogress.ContinueWatchingPreferencesRepository
import com.nuvio.app.features.watchprogress.ResumePromptRepository
import com.nuvio.app.features.watchprogress.WatchProgressPlaybackSession
import com.nuvio.app.features.watchprogress.WatchProgressRepository
import com.nuvio.app.features.watchprogress.WatchProgressSourceCoordinator
import com.nuvio.app.features.watchprogress.continueWatchingItemKey
import com.nuvio.app.features.watchprogress.nextUpDismissKey
import com.nuvio.app.features.watchprogress.toContinueWatchingItem
import com.nuvio.app.navigation.*
import dev.chrisbanes.haze.hazeSource
import dev.chrisbanes.haze.rememberHazeState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import nuvio.composeapp.generated.resources.*
import org.jetbrains.compose.resources.getString
import org.jetbrains.compose.resources.stringResource
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.input.pointer.PointerButton
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.pointerInput
import com.nuvio.app.core.ui.AppPresenceState
import com.nuvio.app.core.ui.PresenceSnapshot
import androidx.compose.ui.ExperimentalComposeUiApi
import com.nuvio.app.features.player.dispatchNavigationBack

@OptIn(ExperimentalSharedTransitionApi::class, ExperimentalComposeUiApi::class)
@Composable
internal fun MainAppContent(
    initialTab: AppScreenTab = AppScreenTab.Home,
    initialRoute: AppRoute = TabsRoute,
    useNativeNavigation: Boolean = false,
    useNativeTabBar: Boolean = false,
    useTabletFloatingTabBar: Boolean = false,
    ownsAppRuntime: Boolean = true,
    showLaunchOverlay: Boolean = true,
    onNavigate: ((AppRoute, launchSingleTop: Boolean) -> Unit)? = null,
    onGoBack: (() -> Unit)? = null,
    onReplace: ((AppRoute) -> Unit)? = null,
    onActivate: ((AppScreenTab) -> Unit)? = null,
    onTabTitles: ((home: String, search: String, library: String, profile: String, switchProfile: String, addProfile: String) -> Unit)? = null,
    appGateController: AppGateController? = null,
    onRootContentReady: ((Boolean) -> Unit)? = null,
    onSwitchProfile: () -> Unit = {},
) {
        val navBackStack = rememberNavBackStack(navigationSavedStateConfiguration, initialRoute)
        val routeDisposalDecorator = remember {
            RouteDisposalNavEntryDecorator<NavKey> { key ->
                if (key is AppRoute) disposeRoute(key)
            }
        }
        val navController = remember(navBackStack, onNavigate, onGoBack, onReplace) {
            NuvioNavigator(
                backStack = navBackStack,
                onExternalNavigate = onNavigate,
                onExternalBack = onGoBack,
                onExternalReplace = onReplace,
            )
        }
        val appUpdaterController = rememberAppUpdaterController()
        val hapticFeedback = LocalHapticFeedback.current
        val focusManager = LocalFocusManager.current
        val uriHandler = LocalUriHandler.current
        val coroutineScope = rememberCoroutineScope()
        var selectedTab by rememberSaveable(initialTab) { mutableStateOf(initialTab) }
        var searchFocusRequestCount by remember { mutableStateOf(0) }
        val homeScrollToTopRequests = remember { MutableSharedFlow<Unit>(extraBufferCapacity = 1) }
        val searchScrollToTopRequests = remember { MutableSharedFlow<Unit>(extraBufferCapacity = 1) }
        val searchListState = rememberLazyListState()
        val libraryScrollToTopRequests = remember { MutableSharedFlow<Unit>(extraBufferCapacity = 1) }
        val settingsRootActionRequests = remember { MutableSharedFlow<Unit>(extraBufferCapacity = 1) }

        LaunchedEffect(ownsAppRuntime) {
            if (!ownsAppRuntime) return@LaunchedEffect
            warmProfileBoundRepositories()
        }
        val currentRoute = navBackStack.lastOrNull() as? AppRoute
        var registeredPlayerSystemBack by remember {
            mutableStateOf<Pair<PlayerRoute, () -> Unit>?>(null)
        }
        val liquidGlassNativeTabBarEnabled by remember {
            ThemeSettingsRepository.liquidGlassNativeTabBarEnabled
        }.collectAsStateWithLifecycle()
        val desktopNavigationLayout by remember {
            ThemeSettingsRepository.desktopNavigationLayout
        }.collectAsStateWithLifecycle()
        val liquidGlassNativeTabBarSupported = remember { isLiquidGlassNativeTabBarSupported() }
        var showExitConfirmation by rememberSaveable { mutableStateOf(false) }
        var selectedPosterActionTarget by remember { mutableStateOf<PosterActionTarget?>(null) }
        var selectedPosterAnchor by remember { mutableStateOf<PosterZoomAnchor?>(null) }
        val posterOverlayHazeState = rememberHazeState()
        var selectedContinueWatchingForActions by remember { mutableStateOf<ContinueWatchingItem?>(null) }
        var selectedContinueWatchingZoomAnchor by remember { mutableStateOf<PosterZoomAnchor?>(null) }
        val libraryDisintegrationRequests = remember { DisintegrationRequestController<String>() }
        val continueWatchingDisintegrationRequests = remember { DisintegrationRequestController<String>() }
        var requestedSettingsPageName by rememberSaveable { mutableStateOf<String?>(null) }
        var showLibraryListPicker by remember { mutableStateOf(false) }
        var pickerItem by remember { mutableStateOf<LibraryItem?>(null) }
        var pickerTitle by remember { mutableStateOf("") }
        var pickerTabs by remember { mutableStateOf<List<TrackingLibraryTab>>(emptyList()) }
        var pickerMembership by remember { mutableStateOf<Map<String, Boolean>>(emptyMap()) }
        var pickerPending by remember { mutableStateOf(false) }
        var pickerError by remember { mutableStateOf<String?>(null) }
        var pendingTrackingRemoval by remember { mutableStateOf<PendingTrackingMembershipRemoval?>(null) }
        val trackingListsUpdateFailedMessage = stringResource(Res.string.tracking_lists_update_failed)
        val addonsUiState by remember {
            AddonRepository.initialize()
            AddonRepository.uiState
        }.collectAsStateWithLifecycle()
        val libraryUiState by remember {
            LibraryRepository.ensureLoaded()
            LibraryRepository.uiState
        }.collectAsStateWithLifecycle()
        val authState by AuthRepository.state.collectAsStateWithLifecycle()
        val openPosterActions: (PosterActionTarget) -> Unit = { target ->
            hapticFeedback.performHapticFeedback(HapticFeedbackType.LongPress)
            focusManager.clearFocus(force = true)
            selectedPosterAnchor = PosterZoomAnchorHolder.consume()
            coroutineScope.launch {
                withFrameNanos { }
                selectedPosterActionTarget = target
            }
        }
        val profileState by ProfileRepository.state.collectAsStateWithLifecycle()
        val launchOverlayProfile = profileState.activeProfile ?: profileState.profiles.firstOrNull()
    val playerSettingsUiState by remember {
        PlayerSettingsRepository.ensureLoaded()
        PlayerSettingsRepository.uiState
    }.collectAsStateWithLifecycle()
    val p2pSettingsUiState by remember {
        P2pSettingsRepository.ensureLoaded()
        P2pSettingsRepository.uiState
    }.collectAsStateWithLifecycle()
    val watchedUiState by remember {
        WatchedRepository.ensureLoaded()
        WatchedRepository.uiState
    }.collectAsStateWithLifecycle()
    val fullyWatchedSeriesKeys by WatchedRepository.fullyWatchedSeriesKeys.collectAsStateWithLifecycle()
    val downloadsUiState by remember {
        DownloadsRepository.ensureLoaded()
        DownloadsRepository.uiState
    }.collectAsStateWithLifecycle()
    val networkStatusUiState by remember {
        NetworkStatusRepository.uiState
    }.collectAsStateWithLifecycle()
    val downloadedProviderLabel = stringResource(Res.string.provider_downloaded)
    val externalPlayerNotConfiguredText = stringResource(Res.string.external_player_not_configured)
    val externalPlayerUnavailableText = stringResource(Res.string.external_player_unavailable)
    val externalPlayerFailedText = stringResource(Res.string.external_player_failed)
    val failedOpenBrowserText = stringResource(Res.string.settings_trakt_failed_open_browser)
    val cloudLibraryPlayFailedText = stringResource(Res.string.cloud_library_play_failed)
    val cloudLibraryPlayDisabledText = stringResource(Res.string.cloud_library_play_disabled)
    val cloudLibraryPlayNotConnectedText = stringResource(Res.string.cloud_library_play_not_connected)
    val nativeTabHomeTitle = stringResource(Res.string.compose_nav_home)
    val nativeTabSearchTitle = stringResource(Res.string.compose_nav_search)
    val nativeTabLibraryTitle = stringResource(Res.string.compose_nav_library)
    val nativeTabProfileTitle = stringResource(Res.string.compose_nav_profile)
    val nativeSwitchProfileTitle = stringResource(Res.string.compose_settings_root_switch_profile_title)
    val nativeAddProfileTitle = stringResource(Res.string.compose_profile_add_profile)
    val homescreenSettingsTitle = stringResource(Res.string.compose_settings_page_homescreen)
    val metaScreenSettingsTitle = stringResource(Res.string.compose_settings_page_meta_screen)
    val continueWatchingSettingsTitle = stringResource(Res.string.compose_settings_page_continue_watching)
    val debridSettingsTitle = stringResource(Res.string.compose_settings_page_debrid)
    val downloadsSettingsTitle = stringResource(Res.string.compose_settings_root_downloads_title)
    val addonsSettingsTitle = stringResource(Res.string.compose_settings_page_addons)
    val pluginsSettingsTitle = stringResource(Res.string.compose_settings_page_plugins)
    val accountSettingsTitle = stringResource(Res.string.compose_settings_page_account)
    val supportersSettingsTitle = stringResource(Res.string.compose_settings_page_supporters_contributors)
    val licensesSettingsTitle = stringResource(Res.string.compose_settings_page_licenses_attributions)
    val collectionsTitle = stringResource(Res.string.collections_header)
    val newCollectionTitle = stringResource(Res.string.collections_new)
    val detailsFallbackTitle = stringResource(Res.string.meta_section_details_title)
    val isRemoteLibrarySource = libraryUiState.sourceMode != LibrarySourceMode.LOCAL
    val appContentGeneration = if (ownsAppRuntime && appGateController != null) {
        val generation by appGateController.contentGeneration.collectAsStateWithLifecycle()
        generation
    } else {
        0
    }
    var initialHomeReady by rememberSaveable(ownsAppRuntime, appContentGeneration) {
        mutableStateOf(!ownsAppRuntime)
    }
    var offlineLaunchRouteHandled by rememberSaveable { mutableStateOf(false) }
    var networkToastBaselineReady by rememberSaveable { mutableStateOf(false) }
    var lastNetworkToastCondition by rememberSaveable { mutableStateOf(NetworkCondition.Unknown.name) }
    var watchSourceReconnectPending by remember { mutableStateOf(false) }
    val homeCatalogRefreshKey = remember(addonsUiState.addons) {
        buildAddonCatalogRefreshSignature(addonsUiState.addons)
    }

    LaunchedEffect(appContentGeneration, homeCatalogRefreshKey) {
        if (!ownsAppRuntime) return@LaunchedEffect
        val enabledAddons = addonsUiState.addons.enabledAddons()
        if (enabledAddons.isWaitingForFirstEnabledManifest()) return@LaunchedEffect
        HomeCatalogSettingsRepository.syncCatalogs(enabledAddons)
        HomeRepository.refresh(enabledAddons)
    }

    fun activateTab(tab: AppScreenTab) {
        if (useNativeNavigation && onActivate != null) {
            onActivate(tab)
        } else {
            selectedTab = tab
        }
    }

    fun handleRootTabClick(tab: AppScreenTab) {
        if (selectedTab != tab) {
            activateTab(tab)
            return
        }

        when (tab) {
            AppScreenTab.Home -> homeScrollToTopRequests.tryEmit(Unit)
            AppScreenTab.Search -> {
                searchFocusRequestCount++
                searchScrollToTopRequests.tryEmit(Unit)
            }
            AppScreenTab.Library -> libraryScrollToTopRequests.tryEmit(Unit)
            AppScreenTab.Settings -> settingsRootActionRequests.tryEmit(Unit)
        }
    }

    LaunchedEffect(
        liquidGlassNativeTabBarSupported,
        liquidGlassNativeTabBarEnabled,
        useNativeNavigation,
        currentRoute,
        selectedTab,
    ) {
        NativeTabBridge.requestedTabs.collectLatest { requestedTab ->
            val requestedAppTab = requestedTab.toAppScreenTab()
            if (
                useNativeNavigation &&
                currentRoute is TabsRoute &&
                requestedAppTab == selectedTab
            ) {
                handleRootTabClick(requestedAppTab)
            } else if (
                !useNativeNavigation &&
                liquidGlassNativeTabBarSupported &&
                liquidGlassNativeTabBarEnabled
            ) {
                handleRootTabClick(requestedAppTab)
            }
        }
    }

    LaunchedEffect(
        nativeTabHomeTitle,
        nativeTabSearchTitle,
        nativeTabLibraryTitle,
        nativeTabProfileTitle,
        nativeSwitchProfileTitle,
        nativeAddProfileTitle,
        onTabTitles,
    ) {
        NativeTabBridge.publishTabTitles(
            home = nativeTabHomeTitle,
            search = nativeTabSearchTitle,
            library = nativeTabLibraryTitle,
            profile = nativeTabProfileTitle,
        )
        onTabTitles?.invoke(
            nativeTabHomeTitle,
            nativeTabSearchTitle,
            nativeTabLibraryTitle,
            nativeTabProfileTitle,
            nativeSwitchProfileTitle,
            nativeAddProfileTitle,
        )
    }

    LaunchedEffect(selectedTab) {
        NativeTabBridge.publishSelectedTab(selectedTab.toNativeNavigationTab())
        if (selectedTab != AppScreenTab.Search) {
            searchFocusRequestCount = 0
        }
    }

    val presenceSearchQuery by AppPresenceState.searchQuery.collectAsStateWithLifecycle()

    LaunchedEffect(selectedTab, navBackStack.lastOrNull(), presenceSearchQuery) {
        val topRoute = navBackStack.lastOrNull()
        if (topRoute is PlayerRoute) return@LaunchedEffect
        val detailRoute = topRoute as? DetailRoute
        val detailTitle = detailRoute?.title
        AppPresenceState.publish(
            if (!detailTitle.isNullOrBlank()) {
                // No poster yet - it is not known until the details screen has loaded its meta.
                // That screen re-publishes this snapshot with the artwork as soon as it arrives.
                PresenceSnapshot.Details(
                    title = detailTitle,
                    metaId = detailRoute?.id,
                    metaType = detailRoute?.type,
                )
            } else {
                PresenceSnapshot.Tab(selectedTab, presenceSearchQuery)
            },
        )
    }

    var profileSwitchLoading by remember { mutableStateOf(false) }

    val rootContentReady = !ownsAppRuntime || (initialHomeReady && !profileSwitchLoading)
    val launchOverlayVisible = ownsAppRuntime && showLaunchOverlay && !rootContentReady
    val launchOverlayState = remember(ownsAppRuntime, showLaunchOverlay) {
        MutableTransitionState(
            launchOverlayVisible,
        )
    }
    launchOverlayState.targetState = launchOverlayVisible

    LaunchedEffect(
        rootContentReady,
        ownsAppRuntime,
        onRootContentReady,
    ) {
        if (ownsAppRuntime) {
            onRootContentReady?.invoke(rootContentReady)
        }
    }

    LaunchedEffect(
        currentRoute,
        liquidGlassNativeTabBarSupported,
        liquidGlassNativeTabBarEnabled,
        initialHomeReady,
        profileSwitchLoading,
        useNativeNavigation,
    ) {
        val visible = !useNativeNavigation &&
            liquidGlassNativeTabBarSupported &&
            liquidGlassNativeTabBarEnabled &&
            initialHomeReady &&
            !profileSwitchLoading &&
            currentRoute is TabsRoute
        NativeTabBridge.publishTabBarVisible(visible)
    }

    DisposableEffect(Unit) {
        onDispose {
            NativeTabBridge.publishTabBarVisible(false)
        }
    }

    LaunchedEffect(appContentGeneration) {
        if (!ownsAppRuntime) return@LaunchedEffect
        NetworkStatusRepository.ensureStarted()
        EpisodeReleaseNotificationsRepository.refreshAsync()
        kotlinx.coroutines.delay(5_000)
        initialHomeReady = true
    }

    LaunchedEffect(networkStatusUiState.condition) {
        if (!ownsAppRuntime) return@LaunchedEffect
        val condition = networkStatusUiState.condition
        if (!networkToastBaselineReady) {
            networkToastBaselineReady = true
            lastNetworkToastCondition = condition.name
            return@LaunchedEffect
        }

        val previousConditionName = lastNetworkToastCondition
        if (previousConditionName == condition.name) return@LaunchedEffect

        when (condition) {
            NetworkCondition.NoInternet -> {
                NuvioToastController.show(getString(Res.string.network_no_internet_connection))
            }

            NetworkCondition.ServersUnreachable -> {
                NuvioToastController.show(getString(Res.string.network_cannot_reach_servers))
            }

            NetworkCondition.Online -> {
                if (
                    previousConditionName == NetworkCondition.NoInternet.name ||
                    previousConditionName == NetworkCondition.ServersUnreachable.name
                ) {
                    MemberAccessRepository.refresh()
                    NuvioToastController.show(getString(Res.string.network_back_online))
                }
            }

            NetworkCondition.Unknown,
            NetworkCondition.Checking,
            -> Unit
        }

        lastNetworkToastCondition = condition.name
    }

    LaunchedEffect(
        networkStatusUiState.condition,
        (authState as? AuthState.Authenticated)?.userId,
        profileState.activeProfile?.profileIndex,
    ) {
        if (!ownsAppRuntime) return@LaunchedEffect
        when (networkStatusUiState.condition) {
            NetworkCondition.NoInternet,
            NetworkCondition.ServersUnreachable,
            -> watchSourceReconnectPending = true

            NetworkCondition.Online -> {
                if (!watchSourceReconnectPending) return@LaunchedEffect

                val profileId = profileState.activeProfile?.profileIndex
                    ?: ProfileRepository.activeProfileId
                val authenticatedState = authState as? AuthState.Authenticated
                if (authenticatedState != null && !authenticatedState.isAnonymous) {
                    SyncManager.requestForegroundPull(profileId = profileId)
                    watchSourceReconnectPending = false
                } else {
                    val result = WatchProgressSourceCoordinator.refreshActiveSource(
                        profileId = profileId,
                        force = true,
                    )
                    if (result.succeeded) {
                        watchSourceReconnectPending = false
                    }
                }
            }

            NetworkCondition.Unknown,
            NetworkCondition.Checking,
            -> Unit
        }
    }

    LaunchedEffect(
        initialHomeReady,
        offlineLaunchRouteHandled,
        networkStatusUiState.condition,
        downloadsUiState.completedItems,
    ) {
        if (!ownsAppRuntime) return@LaunchedEffect
        if (!initialHomeReady || offlineLaunchRouteHandled) return@LaunchedEffect

        when (networkStatusUiState.condition) {
            NetworkCondition.Unknown,
            NetworkCondition.Checking,
            -> return@LaunchedEffect

            NetworkCondition.Online -> {
                offlineLaunchRouteHandled = true
            }

            NetworkCondition.NoInternet,
            NetworkCondition.ServersUnreachable,
            -> {
                offlineLaunchRouteHandled = true
                if (!AppFeaturePolicy.downloadsEnabled) return@LaunchedEffect
                val hasPlayableDownload = downloadsUiState.completedItems.any {
                    DownloadsRepository.playableLocalFileUri(it) != null
                }
                if (hasPlayableDownload) {
                    activateTab(AppScreenTab.Settings)
                    navController.navigate(DownloadsSettingsRoute(downloadsSettingsTitle)) {
                        launchSingleTop = true
                    }
                }
            }
        }
    }

    LaunchedEffect(authState, profileState.activeProfile?.profileIndex) {
        if (!ownsAppRuntime) return@LaunchedEffect
        val authenticatedState = authState as? AuthState.Authenticated
        val activeProfileId = profileState.activeProfile?.profileIndex
        val syncProfileId = activeProfileId?.takeIf {
            authenticatedState != null && !authenticatedState.isAnonymous
        }
        if (syncProfileId != null) {
            withContext(Dispatchers.Default) {
                SyncManager.pullAllForProfile(syncProfileId)
            }
        }
        try {
            AppForegroundMonitor.events().collect { visibility ->
                when (visibility) {
                    AppVisibility.Foreground -> {
                        NetworkStatusRepository.requestForegroundRefresh()
                        DeviceSessionRegistration.registerIfAuthenticated()
                        MemberAccessRepository.refreshIfStale()
                        if (syncProfileId != null) {
                            SyncManager.startPeriodicNuvioSyncPull(syncProfileId)
                            SyncManager.requestForegroundPull(syncProfileId)
                        } else {
                            SyncManager.stopPeriodicNuvioSyncPull()
                        }
                    }
                    AppVisibility.Background -> SyncManager.stopPeriodicNuvioSyncPull()
                }
            }
        } finally {
            SyncManager.stopPeriodicNuvioSyncPull()
        }
    }
    var resumePromptItem by remember { mutableStateOf<ContinueWatchingItem?>(null) }
    var lastExternalPlayerLaunch by remember { mutableStateOf<PlayerLaunch?>(null) }
    val activePlaybackProfileId = profileState.activeProfile?.profileIndex ?: ProfileRepository.activeProfileId
    val launchExternalPlayer = rememberExternalPlayerLauncher { result ->
        if (result != null && result.positionMs > 0L) {
            coroutineScope.launch {
                val durationMs = result.durationMs
                // Guard: debrid cache-sync placeholders and error clips report a short
                // duration reaching completion. Skip scrobble + progress for those.
                if (durationMs != null && isShortPlaceholderDuration(durationMs)) return@launch
                val progressPercent = if (durationMs != null && durationMs > 0L) {
                    (result.positionMs.toFloat() / durationMs.toFloat() * 100f).coerceIn(0f, 100f)
                } else {
                    null
                }
                val playerLaunch = lastExternalPlayerLaunch
                if (progressPercent != null && playerLaunch != null) {
                    val trackingMedia = buildTrackingMediaReference(
                        contentType = playerLaunch.parentMetaType,
                        parentMetaId = playerLaunch.parentMetaId,
                        videoId = playerLaunch.videoId,
                        title = playerLaunch.title,
                        seasonNumber = playerLaunch.seasonNumber,
                        episodeNumber = playerLaunch.episodeNumber,
                        episodeTitle = playerLaunch.episodeTitle,
                    )
                    if (trackingMedia.hasResolvableIdentity) {
                        runCatching {
                            TrackingScrobbleCoordinator.scrobble(
                                profileId = playerLaunch.profileId,
                                action = TrackingScrobbleAction.STOP,
                                event = TrackingScrobbleEvent(
                                    media = trackingMedia,
                                    progressPercent = progressPercent.toDouble(),
                                ),
                            )
                        }
                    }
                }
                playerLaunch?.let { playerLaunch ->
                    val session = WatchProgressPlaybackSession(
                        profileId = playerLaunch.profileId,
                        contentType = playerLaunch.contentType ?: playerLaunch.parentMetaType,
                        parentMetaId = playerLaunch.parentMetaId,
                        parentMetaType = playerLaunch.parentMetaType,
                        videoId = playerLaunch.videoId ?: playerLaunch.parentMetaId,
                        title = playerLaunch.title,
                        logo = playerLaunch.logo,
                        poster = playerLaunch.poster,
                        background = playerLaunch.background,
                        seasonNumber = playerLaunch.seasonNumber,
                        episodeNumber = playerLaunch.episodeNumber,
                        episodeTitle = playerLaunch.episodeTitle,
                        episodeThumbnail = playerLaunch.episodeThumbnail,
                        providerName = playerLaunch.providerName,
                        providerAddonId = playerLaunch.providerAddonId,
                        lastStreamTitle = playerLaunch.streamTitle,
                        lastSourceUrl = playerLaunch.sourceUrl,
                    )
                    val snapshot = PlayerPlaybackSnapshot(
                        isLoading = false,
                        isPlaying = false,
                        isEnded = !result.endedByUser,
                        durationMs = durationMs ?: 0L,
                        positionMs = result.positionMs,
                    )
                    WatchProgressRepository.upsertPlaybackProgress(
                        session = session,
                        snapshot = snapshot,
                    )
                }
            }
        }
    }
    val continueWatchingPreferencesUiState by ContinueWatchingPreferencesRepository.uiState.collectAsStateWithLifecycle()

    LaunchedEffect(
        initialHomeReady,
        profileSwitchLoading,
        profileState.activeProfile?.profileIndex,
        continueWatchingPreferencesUiState.showResumePromptOnLaunch,
    ) {
        if (!ownsAppRuntime) return@LaunchedEffect
        if (!initialHomeReady || profileSwitchLoading) return@LaunchedEffect
        if (resumePromptItem != null) return@LaunchedEffect
        if (continueWatchingPreferencesUiState.showResumePromptOnLaunch) {
            resumePromptItem = ResumePromptRepository.consumeResumePrompt()
        }
    }

    LaunchedEffect(currentRoute) {
        val inPlaybackFlow = currentRoute is StreamRoute || currentRoute is PlayerRoute
        if (inPlaybackFlow) {
            resumePromptItem = null
        }
    }

        LaunchedEffect(navController) {
            if (!ownsAppRuntime) return@LaunchedEffect
            AppDeepLinkRepository.pendingDeepLink.collectLatest { deepLink ->
                when (deepLink) {
                    is AppDeepLink.Meta -> {
                        activateTab(AppScreenTab.Home)
                        val routeTitle = runCatching {
                            MetaDetailsRepository.fetch(deepLink.type, deepLink.id)?.name
                        }.getOrNull().orEmpty().ifBlank { detailsFallbackTitle }
                        navController.navigate(
                            DetailRoute(
                                type = deepLink.type,
                                id = deepLink.id,
                                title = routeTitle,
                            )
                        ) {
                            launchSingleTop = true
                        }
                        AppDeepLinkRepository.markConsumed(deepLink)
                    }

                    is AppDeepLink.AddonInstall -> {
                        activateTab(AppScreenTab.Settings)
                        navController.navigate(AddonsSettingsRoute(addonsSettingsTitle)) {
                            launchSingleTop = true
                        }
                        NuvioToastController.show(getString(Res.string.addons_modal_checking_title))
                        AddonRepository.initialize()
                        when (val result = AddonRepository.addAddon(deepLink.manifestUrl)) {
                            is AddAddonResult.Success -> {
                                NuvioToastController.show(
                                    getString(Res.string.addons_modal_success_message, result.manifest.name),
                                )
                            }

                            is AddAddonResult.Error -> {
                                NuvioToastController.show(result.message)
                            }
                        }
                        AppDeepLinkRepository.markConsumed(deepLink)
                    }

                    AppDeepLink.Downloads -> {
                        if (AppFeaturePolicy.downloadsEnabled) {
                            activateTab(AppScreenTab.Settings)
                            navController.navigate(DownloadsSettingsRoute(downloadsSettingsTitle)) {
                                launchSingleTop = true
                            }
                        }
                        AppDeepLinkRepository.markConsumed(deepLink)
                    }

                    null -> Unit
                }
            }
        }

        suspend fun openExternalPlayback(launch: PlayerLaunch): Boolean {
            if (!externalPlayerSupported) return false

            lastExternalPlayerLaunch = launch

            val bingeGroup = launch.bingeGroup
            if (bingeGroup != null && launch.parentMetaId.isNotBlank()) {
                BingeGroupCacheRepository.save(launch.parentMetaId, bingeGroup)
            }

            val baseRequest = launch.toExternalPlayerPlaybackRequest()
            val shouldForwardSubtitles = playerSettingsUiState.externalPlayerForwardSubtitles &&
                !playerSettingsUiState.preferredSubtitleLanguage.equals(SubtitleLanguageOption.NONE, ignoreCase = true)
            val shouldSendSkipSegments = playerSettingsUiState.externalPlayerSendSkipSegments
            if (shouldForwardSubtitles) {
                StreamsRepository.setOverlayVisible(true, getString(Res.string.streams_loading_subtitles))
            } else if (shouldSendSkipSegments) {
                StreamsRepository.setOverlayVisible(true, getString(Res.string.streams_loading_skip_segments))
            }
            val enrichedRequest = prepareExternalPlayerLaunch(
                request = baseRequest,
                type = launch.contentType ?: launch.parentMetaType,
                videoId = launch.videoId ?: launch.parentMetaId,
                contentId = launch.parentMetaId,
                forwardSubtitles = playerSettingsUiState.externalPlayerForwardSubtitles,
                sendSkipSegments = shouldSendSkipSegments,
                preferredLanguage = playerSettingsUiState.preferredSubtitleLanguage,
                secondaryLanguage = playerSettingsUiState.secondaryPreferredSubtitleLanguage,
                onOverlayMessage = { _ -> },
            )
            StreamsRepository.setOverlayVisible(false)
            return when (
                val intentResult = ExternalPlayerPlatform.buildIntent(
                    request = enrichedRequest,
                    playerId = playerSettingsUiState.externalPlayerId,
                )
            ) {
                is ExternalPlayerIntentResult.Success -> {
                    val launched = launchExternalPlayer(intentResult)
                    if (!launched) {
                        NuvioToastController.show(externalPlayerFailedText)
                    }
                    launched
                }
                ExternalPlayerIntentResult.NotConfigured -> {
                    NuvioToastController.show(externalPlayerNotConfiguredText)
                    false
                }
                ExternalPlayerIntentResult.Failed -> {
                    NuvioToastController.show(externalPlayerFailedText)
                    false
                }
            }
        }

        fun openDownloadedItem(item: DownloadItem) {
            val sourceUrl = DownloadsRepository.playableLocalFileUri(item) ?: return
            val resumeEntry = item.videoId
                .takeIf { it.isNotBlank() }
                ?.let(WatchProgressRepository::progressForVideo)
                ?.takeIf { it.isResumable }

            val playerLaunch = PlayerLaunch(
                profileId = activePlaybackProfileId,
                title = item.title,
                sourceUrl = sourceUrl,
                sourceHeaders = emptyMap(),
                sourceResponseHeaders = emptyMap(),
                externalSubtitles = emptyList(),
                streamType = null,
                logo = item.logo,
                poster = item.poster,
                background = item.background,
                seasonNumber = item.seasonNumber,
                episodeNumber = item.episodeNumber,
                episodeTitle = item.episodeTitle,
                episodeThumbnail = item.episodeThumbnail,
                streamTitle = item.streamTitle,
                streamSubtitle = item.streamSubtitle,
                providerName = item.providerName,
                providerAddonId = item.providerAddonId,
                contentType = item.contentType,
                videoId = item.videoId,
                parentMetaId = item.parentMetaId,
                parentMetaType = item.parentMetaType,
                initialPositionMs = resumeEntry?.lastPositionMs?.takeIf { it > 0L } ?: 0L,
                initialProgressFraction = resumeEntry?.progressFraction?.takeIf { it > 0f },
            )
            if (playerSettingsUiState.externalPlayerEnabled) {
                coroutineScope.launch { openExternalPlayback(playerLaunch) }
                return
            }
            val launchId = PlayerLaunchStore.put(playerLaunch)
            navController.navigate(PlayerRoute(launchId = launchId, title = playerLaunch.title))
        }

        fun openExternalStreamUrl(url: String): Boolean {
            val opened = runCatching {
                uriHandler.openUri(url)
            }.isSuccess
            if (!opened) {
                NuvioToastController.show(failedOpenBrowserText)
            }
            return opened
        }

        suspend fun launchCloudLibraryFile(
            item: CloudLibraryItem,
            file: CloudLibraryFile,
            resumePositionMs: Long? = null,
            resumeProgressFraction: Float? = null,
            startFromBeginning: Boolean = false,
        ): Boolean {
            return when (
                val resolved = CloudLibraryRepository.resolvePlayback(
                    item = item,
                    file = file,
                )
            ) {
                is CloudLibraryPlaybackResult.Success -> {
                    val playbackTitle = resolved.filename
                        ?.takeIf { it.isNotBlank() }
                        ?: file.name.ifBlank { item.name }
                    val playerLaunch = PlayerLaunch(
                        profileId = activePlaybackProfileId,
                        title = playbackTitle,
                        sourceUrl = resolved.url,
                        streamTitle = playbackTitle,
                        streamSubtitle = item.name.takeIf { it != playbackTitle },
                        providerName = item.providerName,
                        providerAddonId = "cloud:${item.providerId}",
                        poster = item.providerPosterUrl(),
                        contentType = CloudLibraryContentType,
                        videoId = item.playbackVideoId(file),
                        parentMetaId = item.stableKey,
                        parentMetaType = CloudLibraryContentType,
                        initialPositionMs = if (startFromBeginning) 0L else (resumePositionMs ?: 0L),
                        initialProgressFraction = if (startFromBeginning) null else resumeProgressFraction,
                    )
                    if (externalPlayerSupported && playerSettingsUiState.externalPlayerEnabled) {
                        openExternalPlayback(playerLaunch)
                        true
                    } else {
                        val launchId = PlayerLaunchStore.put(playerLaunch)
                        navController.navigate(PlayerRoute(launchId = launchId, title = playerLaunch.title))
                        true
                    }
                }

                else -> false
            }
        }

        fun launchPlaybackWithDownloadPreference(
            type: String,
            videoId: String,
            parentMetaId: String,
            parentMetaType: String,
            title: String,
            logo: String?,
            poster: String?,
            background: String?,
            seasonNumber: Int?,
            episodeNumber: Int?,
            episodeTitle: String?,
            episodeThumbnail: String?,
            pauseDescription: String?,
            resumePositionMs: Long?,
            resumeProgressFraction: Float?,
            manualSelection: Boolean,
            startFromBeginning: Boolean,
        ) {
            val targetResumePositionMs = if (startFromBeginning) 0L else (resumePositionMs ?: 0L)
            val targetResumeProgressFraction = if (startFromBeginning) null else resumeProgressFraction

            if (!manualSelection && AppFeaturePolicy.downloadsEnabled) {
                val downloadedItem = DownloadsRepository.findPlayableDownload(
                    parentMetaId = parentMetaId,
                    seasonNumber = seasonNumber,
                    episodeNumber = episodeNumber,
                    videoId = videoId,
                )
                val localSourceUrl = downloadedItem?.let(DownloadsRepository::playableLocalFileUri)
                if (!localSourceUrl.isNullOrBlank()) {
                    val playerLaunch = PlayerLaunch(
                        profileId = activePlaybackProfileId,
                        title = title,
                        sourceUrl = localSourceUrl,
                        sourceHeaders = emptyMap(),
                        sourceResponseHeaders = emptyMap(),
                        externalSubtitles = emptyList(),
                        logo = logo,
                        poster = poster,
                        background = background,
                        seasonNumber = seasonNumber,
                        episodeNumber = episodeNumber,
                        episodeTitle = episodeTitle,
                        episodeThumbnail = episodeThumbnail,
                        streamTitle = downloadedItem.streamTitle.ifBlank { title },
                        streamSubtitle = downloadedItem.streamSubtitle,
                        pauseDescription = pauseDescription,
                        providerName = downloadedItem.providerName.ifBlank { downloadedProviderLabel },
                        providerAddonId = downloadedItem.providerAddonId,
                        contentType = type,
                        videoId = videoId,
                        parentMetaId = parentMetaId,
                        parentMetaType = parentMetaType,
                        initialPositionMs = targetResumePositionMs,
                        initialProgressFraction = targetResumeProgressFraction,
                    )
                    if (externalPlayerSupported && playerSettingsUiState.externalPlayerEnabled) {
                        coroutineScope.launch { openExternalPlayback(playerLaunch) }
                        return
                    }
                    val launchId = PlayerLaunchStore.put(playerLaunch)
                    navController.navigate(PlayerRoute(launchId = launchId, title = playerLaunch.title))
                    return
                }
            }

            val streamLaunchId = StreamLaunchStore.put(
                StreamLaunch(
                    profileId = activePlaybackProfileId,
                    type = type,
                    videoId = videoId,
                    parentMetaId = parentMetaId,
                    parentMetaType = parentMetaType,
                    title = title,
                    logo = logo,
                    poster = poster,
                    background = background,
                    seasonNumber = seasonNumber,
                    episodeNumber = episodeNumber,
                    episodeTitle = episodeTitle,
                    episodeThumbnail = episodeThumbnail,
                    pauseDescription = pauseDescription,
                    resumePositionMs = if (startFromBeginning) 0L else resumePositionMs,
                    resumeProgressFraction = targetResumeProgressFraction,
                    manualSelection = manualSelection,
                    startFromBeginning = startFromBeginning,
                ),
            )
            navController.navigate(
                StreamRoute(launchId = streamLaunchId, title = title),
            )
        }

        val onPlay: ContentPlayAction =
            { type, videoId, parentMetaId, parentMetaType, title, logo, poster, background, seasonNumber, episodeNumber, episodeTitle, episodeThumbnail, pauseDescription, resumePositionMs ->
                launchPlaybackWithDownloadPreference(
                    type = type,
                    videoId = videoId,
                    parentMetaId = parentMetaId,
                    parentMetaType = parentMetaType,
                    title = title,
                    logo = logo,
                    poster = poster,
                    background = background,
                    seasonNumber = seasonNumber,
                    episodeNumber = episodeNumber,
                    episodeTitle = episodeTitle,
                    episodeThumbnail = episodeThumbnail,
                    pauseDescription = pauseDescription,
                    resumePositionMs = resumePositionMs,
                    resumeProgressFraction = null,
                    manualSelection = false,
                    startFromBeginning = false,
                )
            }

        val onPlayManually: ContentPlayAction =
            { type, videoId, parentMetaId, parentMetaType, title, logo, poster, background, seasonNumber, episodeNumber, episodeTitle, episodeThumbnail, pauseDescription, resumePositionMs ->
                launchPlaybackWithDownloadPreference(
                    type = type,
                    videoId = videoId,
                    parentMetaId = parentMetaId,
                    parentMetaType = parentMetaType,
                    title = title,
                    logo = logo,
                    poster = poster,
                    background = background,
                    seasonNumber = seasonNumber,
                    episodeNumber = episodeNumber,
                    episodeTitle = episodeTitle,
                    episodeThumbnail = episodeThumbnail,
                    pauseDescription = pauseDescription,
                    resumePositionMs = resumePositionMs,
                    resumeProgressFraction = null,
                    manualSelection = true,
                    startFromBeginning = false,
                )
            }

        val onCatalogClick: (HomeCatalogSection) -> Unit = { section ->
            val launchId = CatalogLaunchStore.put(
                CatalogLaunch(
                    title = section.title,
                    subtitle = section.subtitle,
                    target = section.target,
                ),
            )
            navController.navigate(
                CatalogRoute(
                    launchId = launchId,
                    title = section.title,
                    subtitle = section.subtitle,
                ),
            )
        }

        val librarySectionSubtitle = when (libraryUiState.sourceMode) {
            LibrarySourceMode.LOCAL -> stringResource(Res.string.compose_catalog_subtitle_library)
            LibrarySourceMode.TRAKT -> stringResource(Res.string.compose_catalog_subtitle_trakt_library)
            LibrarySourceMode.SIMKL -> stringResource(Res.string.compose_catalog_subtitle_simkl_library)
        }

        val onLibrarySectionViewAllClick: (LibrarySection, LibrarySortOption) -> Unit = { section, sortOption ->
            val launchId = CatalogLaunchStore.put(
                CatalogLaunch(
                    title = section.displayTitle,
                    subtitle = librarySectionSubtitle,
                    target = CatalogTarget.Library(
                        contentType = section.items.firstOrNull()?.type ?: "movie",
                        sectionType = section.type,
                        sortOption = sortOption,
                    ),
                ),
            )
            navController.navigate(
                CatalogRoute(
                    launchId = launchId,
                    title = section.displayTitle,
                    subtitle = librarySectionSubtitle,
                ),
            )
        }

        val openContinueWatching: (ContinueWatchingItem, Boolean, Boolean) -> Unit = { item, manualSelection, startFromBeginning ->
            resumePromptItem = null
            if (item.isCloudLibraryContinueWatchingItem()) {
                coroutineScope.launch {
                    when (
                        val lookup = CloudLibraryRepository.findPlaybackTargetForProgressResult(
                            contentId = item.parentMetaId,
                            videoId = item.videoId,
                        )
                    ) {
                        is CloudLibraryPlaybackTargetLookupResult.Found -> {
                            val launched = launchCloudLibraryFile(
                                item = lookup.target.item,
                                file = lookup.target.file,
                                resumePositionMs = item.resumePositionMs,
                                resumeProgressFraction = item.resumeProgressFraction,
                                startFromBeginning = startFromBeginning,
                            )
                            if (!launched) {
                                NuvioToastController.show(cloudLibraryPlayFailedText)
                            }
                        }

                        CloudLibraryPlaybackTargetLookupResult.Disabled -> {
                            NuvioToastController.show(cloudLibraryPlayDisabledText)
                        }

                        is CloudLibraryPlaybackTargetLookupResult.NotConnected -> {
                            val providerName = lookup.providerName?.takeIf { it.isNotBlank() }
                            NuvioToastController.show(
                                providerName?.let { name ->
                                    getString(Res.string.cloud_library_play_provider_not_connected, name)
                                }
                                    ?: cloudLibraryPlayNotConnectedText,
                            )
                        }

                        CloudLibraryPlaybackTargetLookupResult.NotFound -> {
                            NuvioToastController.show(cloudLibraryPlayFailedText)
                        }
                    }
                }
            } else {
                launchPlaybackWithDownloadPreference(
                    type = item.parentMetaType,
                    videoId = item.videoId,
                    parentMetaId = item.parentMetaId,
                    parentMetaType = item.parentMetaType,
                    title = item.title,
                    logo = item.logo,
                    poster = item.poster,
                    background = item.background,
                    seasonNumber = item.seasonNumber,
                    episodeNumber = item.episodeNumber,
                    episodeTitle = item.episodeTitle,
                    episodeThumbnail = item.episodeThumbnail,
                    pauseDescription = item.pauseDescription,
                    resumePositionMs = item.resumePositionMs,
                    resumeProgressFraction = item.resumeProgressFraction,
                    manualSelection = manualSelection,
                    startFromBeginning = startFromBeginning,
                )
            }
        }

        val onContinueWatchingClick: (ContinueWatchingItem) -> Unit = { item ->
            openContinueWatching(item, false, false)
        }

        val onContinueWatchingStartFromBeginning: (ContinueWatchingItem) -> Unit = { item ->
            openContinueWatching(item, false, true)
        }

        val onContinueWatchingPlayManually: (ContinueWatchingItem) -> Unit = { item ->
            openContinueWatching(item, true, false)
        }

        val onContinueWatchingRemove: (ContinueWatchingItem) -> Unit = { item ->
            continueWatchingDisintegrationRequests.arm(continueWatchingItemKey(item))
            if (item.isNextUp) {
                ContinueWatchingPreferencesRepository.addDismissedNextUpKey(
                    nextUpDismissKey(
                        item.parentMetaId,
                        item.nextUpSeedSeasonNumber,
                        item.nextUpSeedEpisodeNumber,
                    ),
                )
            } else {
                WatchProgressRepository.removeProgress(contentId = item.parentMetaId)
            }
        }

        val onContinueWatchingLongPress: (ContinueWatchingItem) -> Unit = { item ->
            hapticFeedback.performHapticFeedback(HapticFeedbackType.LongPress)
            val zoomAnchor = PosterZoomAnchorHolder.consume()
            selectedContinueWatchingZoomAnchor = zoomAnchor
            selectedContinueWatchingForActions = item
        }

        AppUpdaterHost(
            controller = appUpdaterController,
            modifier = Modifier.fillMaxSize(),
        ) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(MaterialTheme.nuvio.colors.background)
                    .pointerInput(Unit) {
                        awaitPointerEventScope {
                            while (true) {
                                val event = awaitPointerEvent()
                                if (event.type == PointerEventType.Press) {
                                    if (!event.changes.any { it.isConsumed }) {
                                        if (event.button == PointerButton.Back) {
                                            event.changes.forEach { it.consume() }
                                            navController.popBackStack()
                                        }
                                    }
                                }
                            }
                        }
                    },
            ) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .then(
                        if (selectedPosterActionTarget != null || selectedContinueWatchingZoomAnchor != null) {
                            Modifier.hazeSource(state = posterOverlayHazeState)
                        } else {
                            Modifier
                        },
                    )
                    .background(MaterialTheme.nuvio.colors.background),
            ) {
            SharedTransitionLayout {
                CompositionLocalProvider(
                    LocalUseNativeNavigation provides useNativeNavigation,
                    LocalNativeNavigationBarHidden provides (currentRoute?.hidesNavigationBar == true),
                ) {
                NavDisplay(
                    backStack = navBackStack,
                    modifier = Modifier.fillMaxSize(),
                    onBack = {
                        val routeAtRequest = navController.currentRoute
                        dispatchNavigationBack(
                            isPlayerRoute = routeAtRequest is PlayerRoute,
                            playerBack = registeredPlayerSystemBack
                                ?.takeIf { (route, _) -> route == routeAtRequest }
                                ?.second,
                            pop = { navController.popBackStack() },
                        )
                    },
                    entryDecorators = listOf(
                        rememberSaveableStateHolderNavEntryDecorator<NavKey>(),
                        routeDisposalDecorator,
                    ),
                    sharedTransitionScope = this@SharedTransitionLayout,
                    entryProvider = entryProvider<NavKey> {
                entry<TabsRoute> {
                    MainTabsDestination(
                        selectedTab = selectedTab,
                        initialHomeReady = initialHomeReady,
                        rootRouteActive = currentRoute is TabsRoute,
                        useTabletFloatingTabBar = useTabletFloatingTabBar,
                        useNativeNavigation = useNativeNavigation,
                        useNativeTabBar = useNativeTabBar,
                        liquidGlassNativeTabBarSupported = liquidGlassNativeTabBarSupported,
                        liquidGlassNativeTabBarEnabled = liquidGlassNativeTabBarEnabled,
                        desktopNavigationLayout = desktopNavigationLayout,
                        requests = AppTabRequests(
                            homeScrollToTopRequests = homeScrollToTopRequests,
                            searchScrollToTopRequests = searchScrollToTopRequests,
                            libraryScrollToTopRequests = libraryScrollToTopRequests,
                            settingsRootActionRequests = settingsRootActionRequests,
                        ),
                        state = AppTabState(
                            searchListState = searchListState,
                            homeContentGeneration = appContentGeneration,
                            searchFocusRequestCount = searchFocusRequestCount,
                            tabsRouteActiveState = rememberUpdatedState(currentRoute is TabsRoute),
                            libraryDisintegrationRequest = libraryDisintegrationRequests.current,
                            continueWatchingDisintegrationRequest = continueWatchingDisintegrationRequests.current,
                            requestedSettingsPageName = requestedSettingsPageName,
                        ),
                        actions = { isTabletLayout ->
                            AppTabActions(
                                onCatalogClick = onCatalogClick,
                                onPosterClick = { meta ->
                                    navController.navigate(
                                        DetailRoute(type = meta.type, id = meta.id, title = meta.name),
                                    )
                                },
                                onPosterLongClick = { meta ->
                                    openPosterActions(PosterActionTarget(preview = meta))
                                },
                                onLibraryPosterClick = { item ->
                                    navController.navigate(
                                        DetailRoute(type = item.type, id = item.id, title = item.name),
                                    )
                                },
                                onLibraryPosterLongClick = { item, section ->
                                    openPosterActions(
                                        PosterActionTarget(
                                            preview = item.toMetaPreview(),
                                            libraryItem = item,
                                            libraryListKey = section.type,
                                        ),
                                    )
                                },
                                onLibrarySectionViewAllClick = onLibrarySectionViewAllClick,
                                onCloudFilePlay = { item, file ->
                                    coroutineScope.launch {
                                        val resumeItem = WatchProgressRepository
                                            .progressForVideo(
                                                videoId = item.playbackVideoId(file),
                                                parentMetaId = item.id,
                                            )
                                            ?.takeIf { it.isResumable }
                                            ?.toContinueWatchingItem()
                                        if (
                                            !launchCloudLibraryFile(
                                                item = item,
                                                file = file,
                                                resumePositionMs = resumeItem?.resumePositionMs,
                                                resumeProgressFraction = resumeItem?.resumeProgressFraction,
                                            )
                                        ) {
                                            NuvioToastController.show(cloudLibraryPlayFailedText)
                                        }
                                    }
                                },
                                onConnectCloudClick = {
                                    if (useNativeNavigation && !isTabletLayout) {
                                        activateTab(AppScreenTab.Settings)
                                        navController.navigate(
                                            SettingsPageRoute(
                                                pageName = "Debrid",
                                                title = debridSettingsTitle,
                                            )
                                        )
                                    } else {
                                        requestedSettingsPageName = "Debrid"
                                        activateTab(AppScreenTab.Settings)
                                    }
                                },
                                onContinueWatchingClick = onContinueWatchingClick,
                                onContinueWatchingLongPress = onContinueWatchingLongPress,
                                onSwitchProfile = onSwitchProfile,
                                onSettingsPageClick = if (useNativeNavigation && !isTabletLayout) {
                                    { pageName, title ->
                                        navController.navigate(SettingsPageRoute(pageName, title))
                                    }
                                } else {
                                    null
                                },
                                onHomescreenSettingsClick = { navController.navigate(HomescreenSettingsRoute(homescreenSettingsTitle)) },
                                onMetaScreenSettingsClick = { navController.navigate(MetaScreenSettingsRoute(metaScreenSettingsTitle)) },
                                onContinueWatchingSettingsClick = { navController.navigate(ContinueWatchingSettingsRoute(continueWatchingSettingsTitle)) },
                                onDownloadsSettingsClick = { navController.navigate(DownloadsSettingsRoute(downloadsSettingsTitle)) },
                                onAddonsSettingsClick = { navController.navigate(AddonsSettingsRoute(addonsSettingsTitle)) },
                                onPluginsSettingsClick = {
                                    if (AppFeaturePolicy.pluginsEnabled) {
                                        navController.navigate(PluginsSettingsRoute(pluginsSettingsTitle))
                                    }
                                },
                                onAccountSettingsClick = { navController.navigate(AccountSettingsRoute(accountSettingsTitle)) },
                                onSupportersContributorsSettingsClick = {
                                    if (AppFeaturePolicy.supportersContributorsPageEnabled) {
                                        navController.navigate(SupportersContributorsSettingsRoute(supportersSettingsTitle))
                                    }
                                },
                                onLicensesAttributionsSettingsClick = {
                                    navController.navigate(LicensesAttributionsSettingsRoute(licensesSettingsTitle))
                                },
                                onCheckForUpdatesClick = if (AppFeaturePolicy.inAppUpdaterEnabled) {
                                    {
                                        appUpdaterController.checkForUpdates(
                                            force = true,
                                            showNoUpdateFeedback = true,
                                        )
                                    }
                                } else {
                                    null
                                },
                                onTestUpdateBannerClick = if (
                                    AppFeaturePolicy.inAppUpdaterEnabled && AppUpdaterPlatform.isDebugBuild
                                ) {
                                    appUpdaterController::showDebugTestUpdate
                                } else {
                                    null
                                },
                                onCollectionsSettingsClick = { navController.navigate(CollectionsRoute(collectionsTitle)) },
                                onFolderClick = { collectionId, folderId ->
                                    val folderTitle = CollectionRepository.collections.value
                                        .firstOrNull { it.id == collectionId }
                                        ?.folders
                                        ?.firstOrNull { it.id == folderId }
                                        ?.title
                                        .orEmpty()
                                    navController.navigate(
                                        FolderDetailRoute(
                                            collectionId = collectionId,
                                            folderId = folderId,
                                            title = folderTitle.ifBlank { collectionsTitle },
                                        )
                                    )
                                },
                                onRequestedSettingsPageConsumed = {
                                    requestedSettingsPageName = null
                                },
                                onInitialHomeContentRendered = { initialHomeReady = true },
                            )
                        },
                        onBack = {
                            if (selectedTab != AppScreenTab.Home) {
                                activateTab(AppScreenTab.Home)
                            } else {
                                showExitConfirmation = !showExitConfirmation
                            }
                        },
                        onTabSelected = ::handleRootTabClick,
                        onProfileSelected = { profile ->
                            profileSwitchLoading = true
                            NativeTabBridge.publishTabBarVisible(false)
                            activateTab(AppScreenTab.Home)
                            coroutineScope.launch {
                                try {
                                    ProfileRepository.switchToProfile(profile.profileIndex)
                                    warmProfileBoundRepositories()
                                    withContext(Dispatchers.Default) {
                                        SyncManager.pullAllForProfile(profile.profileIndex)
                                    }
                                    delay(300)
                                } finally {
                                    profileSwitchLoading = false
                                }
                            }
                        },
                        onAddProfileRequested = onSwitchProfile,
                    )
                }
                entry<DetailRoute> { route ->
                    DetailsDestination(
                        route = route,
                        navController = navController,
                        onPlay = onPlay,
                        onPlayManually = onPlayManually,
                        sharedTransitionScope = this@SharedTransitionLayout,
                        animatedVisibilityScope = LocalNavAnimatedContentScope.current,
                    )
                }
                entry<PersonDetailRoute> { route ->
                    PersonDestination(
                        route = route,
                        navController = navController,
                        sharedTransitionScope = this@SharedTransitionLayout,
                        animatedVisibilityScope = LocalNavAnimatedContentScope.current,
                    )
                }
                entry<EntityBrowseRoute> { route ->
                    EntityDestination(route = route, navController = navController)
                }
                entry<StreamRoute>(
                    metadata = if (isDesktop) {
                        NavDisplay.transitionSpec {
                            fadeIn(animationSpec = tween(160)) togetherWith
                                fadeOut(animationSpec = tween(160))
                        } + NavDisplay.popTransitionSpec {
                            fadeIn(animationSpec = tween(160)) togetherWith
                                fadeOut(animationSpec = tween(160))
                        }
                    } else {
                        emptyMap()
                    },
                ) { route ->
                    StreamDestination(
                        route = route,
                        navController = navController,
                        p2pEnabled = p2pSettingsUiState.p2pEnabled,
                        openExternalPlayback = ::openExternalPlayback,
                        openExternalStreamUrl = ::openExternalStreamUrl,
                    )
                }
                entry<PlayerRoute>(
                    metadata = if (isIos) {
                        NavDisplay.transitionSpec {
                            fadeIn(animationSpec = tween(220)) togetherWith
                                fadeOut(animationSpec = tween(220))
                        } + NavDisplay.popTransitionSpec {
                            fadeIn(animationSpec = tween(220)) togetherWith
                                fadeOut(animationSpec = tween(220))
                        }
                    } else {
                        emptyMap()
                    },
                ) { route ->
                    PlayerDestination(
                        route = route,
                        navController = navController,
                        externalPlayerId = playerSettingsUiState.externalPlayerId,
                        externalPlayerNotConfiguredText = externalPlayerNotConfiguredText,
                        externalPlayerFailedText = externalPlayerFailedText,
                        onExternalPlayerLaunch = { launch -> lastExternalPlayerLaunch = launch },
                        launchExternalPlayer = launchExternalPlayer,
                        openExternalStreamUrl = ::openExternalStreamUrl,
                        onSystemBackHandlerChanged = { playerRoute, handler ->
                            if (handler == null) {
                                if (registeredPlayerSystemBack?.first == playerRoute) {
                                    registeredPlayerSystemBack = null
                                }
                            } else {
                                registeredPlayerSystemBack = playerRoute to handler
                            }
                        },
                    )
                }
                entry<CatalogRoute> { route ->
                    CatalogDestination(
                        route = route,
                        navController = navController,
                        onPosterLongClick = openPosterActions,
                    )
                }
                entry<HomescreenSettingsRoute> { route ->
                    SettingsDestination(route, navController) { onBack ->
                        HomescreenSettingsScreen(onBack = onBack)
                    }
                }
                entry<MetaScreenSettingsRoute> { route ->
                    SettingsDestination(route, navController) { onBack ->
                        MetaScreenSettingsScreen(onBack = onBack)
                    }
                }
                entry<ContinueWatchingSettingsRoute> { route ->
                    SettingsDestination(route, navController) { onBack ->
                        ContinueWatchingSettingsScreen(onBack = onBack)
                    }
                }
                entry<SettingsPageRoute> { route ->
                    SettingsRootDestination(
                        route = route,
                        navController = navController,
                        useNativeNavigation = useNativeNavigation,
                        downloadsTitle = downloadsSettingsTitle,
                        collectionsTitle = collectionsTitle,
                        onCheckForUpdates = if (AppFeaturePolicy.inAppUpdaterEnabled) {
                            { appUpdaterController.checkForUpdates(force = true, showNoUpdateFeedback = true) }
                        } else null,
                        onTestUpdateBanner = if (
                            AppFeaturePolicy.inAppUpdaterEnabled && AppUpdaterPlatform.isDebugBuild
                        ) appUpdaterController::showDebugTestUpdate else null,
                    )
                }
                entry<DownloadsSettingsRoute> { route ->
                    DownloadsDestination(
                        route = route,
                        navController = navController,
                        useNativeNavigation = useNativeNavigation,
                        onOpenDownload = ::openDownloadedItem,
                    )
                }
                entry<DownloadShowRoute> { route ->
                    DownloadShowDestination(
                        route = route,
                        navController = navController,
                        onOpenDownload = ::openDownloadedItem,
                    )
                }
                entry<AddonsSettingsRoute> { route ->
                    SettingsDestination(route, navController) { onBack ->
                        AddonsSettingsScreen(onBack = onBack)
                    }
                }
                if (AppFeaturePolicy.pluginsEnabled) {
                    entry<PluginsSettingsRoute> { route ->
                        SettingsDestination(route, navController) { onBack ->
                            PluginsSettingsScreen(onBack = onBack)
                        }
                    }
                }
                entry<AccountSettingsRoute> { route ->
                    SettingsDestination(route, navController) { onBack ->
                        AccountSettingsScreen(onBack = onBack)
                    }
                }
                entry<SupportersContributorsSettingsRoute> { route ->
                    SettingsDestination(route, navController) { onBack ->
                        if (AppFeaturePolicy.supportersContributorsPageEnabled) {
                            SupportersContributorsSettingsScreen(onBack = onBack)
                        } else {
                            LaunchedEffect(Unit) { onBack() }
                        }
                    }
                }
                entry<LicensesAttributionsSettingsRoute> { route ->
                    SettingsDestination(route, navController) { onBack ->
                        LicensesAttributionsSettingsScreen(onBack = onBack)
                    }
                }
                entry<CollectionsRoute> { route ->
                    CollectionsDestination(
                        route = route,
                        navController = navController,
                        newCollectionTitle = newCollectionTitle,
                    )
                }
                entry<CollectionEditorRoute> { route ->
                    CollectionEditorDestination(
                        route = route,
                        navController = navController,
                        useNativeNavigation = useNativeNavigation,
                    )
                }
                entry<CollectionEditorPageRoute> { route ->
                    CollectionEditorPageDestination(
                        route = route,
                        navController = navController,
                    )
                }
                entry<FolderDetailRoute> { route ->
                    FolderDestination(
                        route = route,
                        navController = navController,
                        onCatalogClick = onCatalogClick,
                    )
                }
                    }.let { provider ->
                        { key ->
                            routeDisposalDecorator.register(
                                key = key,
                                entry = provider(key),
                            )
                        }
                    },
                )
                }
            }
            }

            selectedPosterActionTarget?.let { posterActionTarget ->
                key(posterActionTarget) {
                    val preview = posterActionTarget.preview
                    val isSaved = LibraryRepository.isSaved(preview.id, preview.type)
                    val isWatched = WatchingState.isPosterWatched(
                        watchedKeys = watchedUiState.watchedKeys,
                        item = preview,
                        fullyWatchedSeriesKeys = fullyWatchedSeriesKeys,
                    )
                    val removesFromLibrary = isSaved &&
                        (posterActionTarget.libraryItem != null || !isRemoteLibrarySource)
                    NuvioPosterZoomActionOverlay(
                        imageUrl = selectedPosterAnchor?.imageUrl ?: preview.poster,
                        title = preview.name,
                        subtitle = preview.releaseInfo
                            ?.takeIf { it.isNotBlank() }
                            ?.let { formatReleaseDateForDisplay(it) }
                            ?: preview.type.replaceFirstChar { char ->
                                if (char.isLowerCase()) char.titlecase() else char.toString()
                            },
                        isWatched = isWatched,
                        anchor = selectedPosterAnchor,
                        actions = listOf(
                            PosterZoomOverlayAction(
                                icon = if (isSaved) Icons.Default.DeleteOutline else Icons.Default.Add,
                                label = if (isSaved) {
                                    stringResource(Res.string.hero_remove_from_library)
                                } else {
                                    stringResource(Res.string.hero_add_to_library)
                                },
                                isDestructive = removesFromLibrary,
                                exitAnimation = if (removesFromLibrary && !isRemoteLibrarySource) {
                                    PosterZoomOverlayExitAnimation.DISINTEGRATE
                                } else {
                                    PosterZoomOverlayExitAnimation.COLLAPSE
                                },
                                onSelected = {
                                    val libraryItem = posterActionTarget.libraryItem
                                        ?: preview.toLibraryItem(savedAtEpochMs = 0L)
                                    if (posterActionTarget.libraryItem != null) {
                                        val animationKey = posterActionTarget.libraryListKey
                                            ?.let { listKey -> librarySectionItemKey(listKey, libraryItem) }
                                        if (isRemoteLibrarySource) {
                                            coroutineScope.launch {
                                                val listKey = posterActionTarget.libraryListKey
                                                val removeMembership: suspend (Set<TrackingProviderId>) ->
                                                    TrackingMembershipApplyResult = { confirmedProviders ->
                                                    if (listKey.isNullOrBlank()) {
                                                        val currentMembership = LibraryRepository.getMembershipSnapshot(libraryItem)
                                                        LibraryRepository.applyMembershipChanges(
                                                            item = libraryItem,
                                                            desiredMembership = currentMembership.mapValues { false },
                                                            confirmedRemovalProviders = confirmedProviders,
                                                        )
                                                    } else {
                                                        LibraryRepository.removeFromList(
                                                            item = libraryItem,
                                                            listKey = listKey,
                                                            confirmedRemovalProviders = confirmedProviders,
                                                        )
                                                    }
                                                }
                                                val removeMembershipWithAnimation:
                                                    suspend (Set<TrackingProviderId>) -> TrackingMembershipApplyResult =
                                                    { confirmedProviders ->
                                                        val request = if (removesFromLibrary) {
                                                            animationKey?.let(libraryDisintegrationRequests::arm)
                                                        } else {
                                                            null
                                                        }
                                                        try {
                                                            removeMembership(confirmedProviders).also { result ->
                                                                if (result.requiresRemovalConfirmation && request != null) {
                                                                    libraryDisintegrationRequests.cancel(request)
                                                                }
                                                            }
                                                        } catch (error: Throwable) {
                                                            request?.let(libraryDisintegrationRequests::cancel)
                                                            throw error
                                                        }
                                                    }
                                                executeTrackingMembershipOperation(
                                                    operation = { removeMembershipWithAnimation(emptySet()) },
                                                    onSuccess = { result ->
                                                        if (result.requiresRemovalConfirmation) {
                                                            pendingTrackingRemoval = PendingTrackingMembershipRemoval(
                                                                itemTitle = libraryItem.name,
                                                                confirmations = result.requiredRemovalConfirmations,
                                                                retry = removeMembershipWithAnimation,
                                                                onApplied = {},
                                                                onFailure = { error ->
                                                                    NuvioToastController.show(
                                                                        error.message
                                                                            ?: trackingListsUpdateFailedMessage,
                                                                    )
                                                                },
                                                            )
                                                        }
                                                    },
                                                    onFailure = { error ->
                                                        NuvioToastController.show(
                                                            error.message ?: trackingListsUpdateFailedMessage,
                                                        )
                                                    },
                                                )
                                            }
                                        } else {
                                            if (removesFromLibrary) {
                                                animationKey?.let(libraryDisintegrationRequests::arm)
                                            }
                                            LibraryRepository.remove(libraryItem.id)
                                        }
                                    } else {
                                        if (!isRemoteLibrarySource) {
                                            LibraryRepository.toggleLocalSaved(libraryItem)
                                        } else {
                                            pickerItem = libraryItem
                                            pickerTitle = preview.name
                                            pickerTabs = LibraryRepository.libraryListTabs(libraryItem)
                                            pickerMembership = pickerTabs.associate { it.key to false }
                                            pickerPending = true
                                            pickerError = null
                                            showLibraryListPicker = true
                                            coroutineScope.launch {
                                                runCatching {
                                                    val snapshot = LibraryRepository.getMembershipSnapshot(libraryItem)
                                                    val tabs = LibraryRepository.libraryListTabs(libraryItem)
                                                    pickerTabs = tabs
                                                    pickerMembership = tabs.associate { tab ->
                                                        tab.key to (snapshot[tab.key] == true)
                                                    }
                                                }.onFailure { error ->
                                                    pickerError = error.message ?: getString(Res.string.trakt_lists_load_failed)
                                                }
                                                pickerPending = false
                                            }
                                        }
                                    }
                                },
                            ),
                            PosterZoomOverlayAction(
                                icon = if (isWatched) Icons.Default.CheckCircle else Icons.Default.CheckCircleOutline,
                                label = if (isWatched) {
                                    stringResource(Res.string.hero_mark_unwatched)
                                } else {
                                    stringResource(Res.string.hero_mark_watched)
                                },
                                onSelected = {
                                    coroutineScope.launch {
                                        WatchingActions.togglePosterWatched(preview)
                                    }
                                },
                            ),
                        ),
                        hazeState = posterOverlayHazeState,
                        onDismissed = {
                            selectedPosterActionTarget = null
                            selectedPosterAnchor = null
                        },
                    )
                }
            }

            selectedContinueWatchingForActions?.let { item ->
                selectedContinueWatchingZoomAnchor?.let { anchor ->
                    key(item.videoId, anchor) {
                        val showManualPlayOption = StreamAutoPlayPolicy.isEffectivelyEnabled(playerSettingsUiState)
                        val showDetailsOption = !item.isCloudLibraryContinueWatchingItem()
                        NuvioPosterZoomActionOverlay(
                            imageUrl = cloudLibraryDisplayArtworkUrl(anchor.imageUrl ?: item.poster ?: item.imageUrl),
                            title = item.title,
                            subtitle = localizedContinueWatchingSubtitle(item),
                            blurred = item.shouldBlurContinueWatchingArtwork(
                                blurUnwatchedEpisodes = continueWatchingPreferencesUiState.blurNextUp,
                                useEpisodeThumbnails = continueWatchingPreferencesUiState.useEpisodeThumbnails,
                                artworkUrl = anchor.imageUrl ?: item.poster ?: item.imageUrl,
                            ),
                            depthSurface = NuvioCardDepthSurface.ContinueWatching,
                            anchor = anchor,
                            actions = buildList {
                                if (showDetailsOption) {
                                    add(
                                        PosterZoomOverlayAction(
                                            icon = Icons.Default.Info,
                                            label = stringResource(Res.string.cw_action_go_to_details),
                                            onSelected = {
                                                navController.navigate(
                                                    DetailRoute(
                                                        type = item.parentMetaType,
                                                        id = item.parentMetaId,
                                                        title = item.title,
                                                    ),
                                                )
                                            },
                                        ),
                                    )
                                }
                                if (showManualPlayOption) {
                                    add(
                                        PosterZoomOverlayAction(
                                            icon = Icons.Default.PlayArrow,
                                            label = stringResource(Res.string.play_manually),
                                            onSelected = { onContinueWatchingPlayManually(item) },
                                        ),
                                    )
                                }
                                if (!item.isNextUp) {
                                    add(
                                        PosterZoomOverlayAction(
                                            icon = Icons.Default.Replay,
                                            label = stringResource(Res.string.cw_action_start_from_beginning),
                                            onSelected = { onContinueWatchingStartFromBeginning(item) },
                                        ),
                                    )
                                }
                                add(
                                    PosterZoomOverlayAction(
                                        icon = Icons.Default.DeleteOutline,
                                        label = stringResource(Res.string.cw_action_remove),
                                        isDestructive = true,
                                        onSelected = { onContinueWatchingRemove(item) },
                                    ),
                                )
                            },
                            hazeState = posterOverlayHazeState,
                            onDismissed = {
                                selectedContinueWatchingForActions = null
                                selectedContinueWatchingZoomAnchor = null
                            },
                        )
                    }
                }
            }

            NuvioContinueWatchingActionSheet(
                item = selectedContinueWatchingForActions.takeIf { selectedContinueWatchingZoomAnchor == null },
                showManualPlayOption = StreamAutoPlayPolicy.isEffectivelyEnabled(playerSettingsUiState),
                showDetailsOption = selectedContinueWatchingForActions?.isCloudLibraryContinueWatchingItem() != true,
                onDismiss = { selectedContinueWatchingForActions = null },
                onOpenDetails = {
                    selectedContinueWatchingForActions?.let { item ->
                        navController.navigate(
                            DetailRoute(
                                type = item.parentMetaType,
                                id = item.parentMetaId,
                                title = item.title,
                            ),
                        )
                    }
                },
                onStartFromBeginning = selectedContinueWatchingForActions
                    ?.takeIf { !it.isNextUp }
                    ?.let { item -> { onContinueWatchingStartFromBeginning(item) } },
                onPlayManually = selectedContinueWatchingForActions
                    ?.let { item -> { onContinueWatchingPlayManually(item) } },
                onRemove = {
                    selectedContinueWatchingForActions?.let(onContinueWatchingRemove)
                },
            )

            TrackingListPickerDialog(
                visible = showLibraryListPicker,
                title = pickerTitle,
                tabs = pickerTabs,
                membership = pickerMembership,
                isPending = pickerPending,
                errorMessage = pickerError,
                onToggle = { listKey ->
                    pickerMembership = toggleTrackingLibraryMembership(
                        tabs = pickerTabs,
                        membership = pickerMembership,
                        key = listKey,
                    )
                },
                onDismiss = {
                    if (!pickerPending) {
                        showLibraryListPicker = false
                        pickerItem = null
                        pickerError = null
                    }
                },
                onSave = {
                    val item = pickerItem ?: return@TrackingListPickerDialog
                    coroutineScope.launch {
                        pickerPending = true
                        pickerError = null
                        val desiredMembership = pickerMembership.toMap()
                        val applyMembership: suspend (Set<TrackingProviderId>) ->
                            TrackingMembershipApplyResult = { confirmedProviders ->
                            LibraryRepository.applyMembershipChanges(
                                item = item,
                                desiredMembership = desiredMembership,
                                confirmedRemovalProviders = confirmedProviders,
                            )
                        }
                        val completeMembershipUpdate: suspend (TrackingMembershipApplyResult) -> Unit = { result ->
                            showTrackingMembershipRewriteFeedback(result)
                            showLibraryListPicker = false
                            pickerItem = null
                            pickerError = null
                        }
                        executeTrackingMembershipOperation(
                            operation = { applyMembership(emptySet()) },
                            onSuccess = { result ->
                                if (result.requiresRemovalConfirmation) {
                                    pendingTrackingRemoval = PendingTrackingMembershipRemoval(
                                        itemTitle = item.name,
                                        confirmations = result.requiredRemovalConfirmations,
                                        retry = applyMembership,
                                        onApplied = completeMembershipUpdate,
                                        onFailure = { error ->
                                            pickerError = error.message ?: trackingListsUpdateFailedMessage
                                        },
                                    )
                                } else {
                                    completeMembershipUpdate(result)
                                }
                            },
                            onFailure = { error ->
                                pickerError = error.message ?: trackingListsUpdateFailedMessage
                            },
                        )
                        pickerPending = false
                    }
                },
            )

            TrackingMembershipRemovalConfirmationHost(
                pending = pendingTrackingRemoval,
                onPendingChange = { pendingTrackingRemoval = it },
            )

            NuvioStatusModal(
                title = stringResource(Res.string.app_exit_title),
                message = stringResource(Res.string.app_exit_message),
                isVisible = showExitConfirmation,
                confirmText = stringResource(Res.string.action_yes),
                dismissText = stringResource(Res.string.action_no),
                onConfirm = {
                    showExitConfirmation = false
                    platformExitApp()
                },
                onDismiss = {
                    showExitConfirmation = false
                },
            )

            androidx.compose.animation.AnimatedVisibility(
                visibleState = launchOverlayState,
                enter = fadeIn(),
                exit = fadeOut(androidx.compose.animation.core.tween(400)),
            ) {
                AppLaunchOverlay(
                    profile = launchOverlayProfile,
                    modifier = Modifier.fillMaxSize(),
                )
            }

            NuvioFloatingPrompt(
                visible = resumePromptItem != null,
                imageUrl = resumePromptItem?.poster ?: resumePromptItem?.imageUrl,
                title = resumePromptItem?.title.orEmpty(),
                subtitle = resumePromptItem?.let { localizedContinueWatchingSubtitle(it) }.orEmpty(),
                progressFraction = resumePromptItem?.progressFraction ?: 0f,
                actionLabel = stringResource(Res.string.resume_prompt_action),
                onAction = {
                    val item = resumePromptItem ?: return@NuvioFloatingPrompt
                    resumePromptItem = null
                    openContinueWatching(item, false, false)
                },
                onDismiss = { resumePromptItem = null },
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .zIndex(15f),
            )

            NuvioToastHost(
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .zIndex(20f),
            )

            }
        }
}

'@

Write-RepoFile "composeApp\src\commonMain\kotlin\com\nuvio\app\features\details\MetaDetailsScreen.kt" @'
package com.nuvio.app.features.details

import androidx.compose.animation.AnimatedVisibilityScope
import androidx.compose.animation.Crossfade
import androidx.compose.animation.ExperimentalSharedTransitionApi
import androidx.compose.animation.SharedTransitionScope
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.CheckCircleOutline
import androidx.compose.material.icons.filled.DoneAll
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.PlaylistAddCheckCircle
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import com.nuvio.app.core.ui.NuvioLoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.nuvio.app.core.ui.NuvioAsyncImage as AsyncImage
import co.touchlab.kermit.Logger
import com.nuvio.app.core.build.AppFeaturePolicy
import com.nuvio.app.core.build.TrailerPlaybackMode
import com.nuvio.app.core.format.formatReleaseDateForDisplay
import com.nuvio.app.core.network.NetworkCondition
import com.nuvio.app.core.network.NetworkStatusRepository
import com.nuvio.app.core.i18n.localizedSeasonEpisodeCode
import com.nuvio.app.core.ui.NuvioBackButton
import com.nuvio.app.core.ui.NuvioDesktopVerticalScrollbar
import com.nuvio.app.core.ui.NuvioCardDepthSurface
import com.nuvio.app.core.ui.NuvioPosterZoomActionOverlay
import com.nuvio.app.core.ui.NuvioToastController
import com.nuvio.app.core.ui.PosterZoomAnchor
import com.nuvio.app.core.ui.PosterZoomAnchorHolder
import com.nuvio.app.core.ui.PosterZoomOverlayAction
import com.nuvio.app.core.ui.desktopPageHorizontalPaddingForWidth
import com.nuvio.app.core.ui.nuvioDesktopDragScroll
import com.nuvio.app.core.ui.TrackingListPickerDialog
import com.nuvio.app.core.ui.nuvioSafeBottomPadding
import com.nuvio.app.core.ui.AppPresenceState
import com.nuvio.app.core.ui.PresenceSnapshot
import com.nuvio.app.core.ui.rememberHeroStretchState
import dev.chrisbanes.haze.hazeSource
import dev.chrisbanes.haze.rememberHazeState
import com.nuvio.app.features.details.components.DetailActionButtons
import com.nuvio.app.features.details.components.DetailSecondaryAction
import com.nuvio.app.features.details.components.CommentDetailSheet
import com.nuvio.app.features.details.components.DetailAdditionalInfoSection
import com.nuvio.app.features.details.components.DetailCastSection
import com.nuvio.app.features.details.components.DetailCommentsSection
import com.nuvio.app.features.details.components.DetailFloatingHeader
import com.nuvio.app.features.details.components.DetailHero
import com.nuvio.app.features.details.components.DetailMetaInfo
import com.nuvio.app.features.details.components.DetailPosterRailSection
import com.nuvio.app.features.details.components.DetailProductionSection
import com.nuvio.app.features.details.components.DetailSeriesContent
import com.nuvio.app.features.details.components.DesktopDetailBackdrop
import com.nuvio.app.features.details.components.DesktopDetailHero
import com.nuvio.app.features.details.components.DetailSeriesListEpisode
import com.nuvio.app.features.details.components.DetailSeriesListHeader
import com.nuvio.app.features.details.components.DetailTrailersSection
import com.nuvio.app.features.details.components.EpisodeWatchedActionSheet
import com.nuvio.app.features.details.components.SeasonWatchedActionSheet
import com.nuvio.app.features.details.components.TrailerPlayerPopup
import com.nuvio.app.features.home.MetaPreview
import com.nuvio.app.features.library.LibraryRepository
import com.nuvio.app.features.library.PendingTrackingMembershipRemoval
import com.nuvio.app.features.library.TrackingMembershipRemovalConfirmationHost
import com.nuvio.app.features.library.executeTrackingMembershipOperation
import com.nuvio.app.features.library.showTrackingMembershipRewriteFeedback
import com.nuvio.app.features.library.toLibraryItem
import com.nuvio.app.features.player.PlayerSettingsRepository
import com.nuvio.app.features.streams.StreamAutoPlayPolicy
import com.nuvio.app.features.tmdb.TmdbSettingsRepository
import com.nuvio.app.features.tmdb.TmdbService
import com.nuvio.app.features.tmdb.originalTmdbImageUrl
import com.nuvio.app.features.trakt.TraktAuthRepository
import com.nuvio.app.features.trakt.TraktCommentReview
import com.nuvio.app.features.trakt.TraktCommentsRepository
import com.nuvio.app.features.trakt.TraktCommentsSettings
import com.nuvio.app.features.trakt.TraktConnectionMode
import com.nuvio.app.features.tracking.TrackingLibraryTab
import com.nuvio.app.features.tracking.TrackingMembershipApplyResult
import com.nuvio.app.features.tracking.toggleTrackingLibraryMembership
import com.nuvio.app.features.tracking.TrackingSettingsRepository
import com.nuvio.app.features.tracking.TrackingProviderId
import com.nuvio.app.features.trailer.TrailerPlaybackResolver
import com.nuvio.app.features.trailer.TrailerPlaybackSource
import com.nuvio.app.features.watched.WatchedRepository
import com.nuvio.app.features.watched.previousReleasedEpisodesBefore
import com.nuvio.app.features.watched.releasedPlayableEpisodes
import com.nuvio.app.features.watched.releasedEpisodesForSeason
import com.nuvio.app.features.watched.watchedItemKey
import com.nuvio.app.features.watchprogress.CurrentDateProvider
import com.nuvio.app.features.watchprogress.WatchProgressEntry
import com.nuvio.app.features.watchprogress.WatchProgressRepository
import com.nuvio.app.features.watchprogress.buildPlaybackVideoId
import com.nuvio.app.features.watchprogress.ContinueWatchingPreferencesRepository
import com.nuvio.app.features.watching.application.WatchingActions
import com.nuvio.app.features.watching.application.WatchingState
import com.nuvio.app.isDesktop
import com.kmpalette.rememberDominantColorState
import com.kmpalette.extensions.painter.rememberPainterDominantColorState
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import nuvio.composeapp.generated.resources.*
import org.jetbrains.compose.resources.getString
import org.jetbrains.compose.resources.stringResource

private val watchedMarkerDiagnosticLog = Logger.withTag("WatchedMarkerDiag")
private const val DetailScrolledBackgroundDefaultMaxAlpha = 0.86f
private const val DetailScrolledBackgroundCinematicMaxAlpha = 0.36f
private const val DetailScrolledBackgroundFadeHeroFraction = 0.75f

internal fun detailScrolledBackgroundProgress(scrollOffsetPx: Float, heroHeightPx: Int): Float {
    if (scrollOffsetPx <= 0f || heroHeightPx <= 0) return 0f
    val fadeDistancePx = heroHeightPx * DetailScrolledBackgroundFadeHeroFraction
    return (scrollOffsetPx / fadeDistancePx).coerceIn(0f, 1f)
}

internal fun detailScrolledBackgroundAlpha(
    scrollOffsetPx: Float,
    heroHeightPx: Int,
    maxAlpha: Float = DetailScrolledBackgroundDefaultMaxAlpha,
): Float {
    return detailScrolledBackgroundProgress(scrollOffsetPx, heroHeightPx) * maxAlpha.coerceIn(0f, 1f)
}

@Composable
@OptIn(ExperimentalSharedTransitionApi::class)
fun MetaDetailsScreen(
    type: String,
    id: String,
    onBack: () -> Unit,
    onPlay: ((type: String, videoId: String, parentMetaId: String, parentMetaType: String, title: String, logo: String?, poster: String?, background: String?, seasonNumber: Int?, episodeNumber: Int?, episodeTitle: String?, episodeThumbnail: String?, pauseDescription: String?, resumePositionMs: Long?) -> Unit)? = null,
    onPlayManually: ((type: String, videoId: String, parentMetaId: String, parentMetaType: String, title: String, logo: String?, poster: String?, background: String?, seasonNumber: Int?, episodeNumber: Int?, episodeTitle: String?, episodeThumbnail: String?, pauseDescription: String?, resumePositionMs: Long?) -> Unit)? = null,
    onOpenMeta: ((MetaPreview) -> Unit)? = null,
    onCastClick: ((MetaPerson, String?) -> Unit)? = null,
    onCompanyClick: ((MetaCompany, String) -> Unit)? = null,
    sharedTransitionScope: SharedTransitionScope? = null,
    animatedVisibilityScope: AnimatedVisibilityScope? = null,
    modifier: Modifier = Modifier,
) {
    val uiState by MetaDetailsRepository.uiState.collectAsStateWithLifecycle()
    val displayedMeta = uiState.meta?.takeIf { it.type == type && it.id == id }
        ?: MetaDetailsRepository.peek(type, id)
    val metaScreenSettingsUiState by remember {
        MetaScreenSettingsRepository.ensureLoaded()
        MetaScreenSettingsRepository.uiState
    }.collectAsStateWithLifecycle()
    val traktAuthUiState by remember {
        TraktAuthRepository.ensureLoaded()
        TraktAuthRepository.uiState
    }.collectAsStateWithLifecycle()
    val trackingSettingsUiState by remember {
        TrackingSettingsRepository.ensureLoaded()
        TrackingSettingsRepository.uiState
    }.collectAsStateWithLifecycle()
    val tmdbSettingsUiState by remember {
        TmdbSettingsRepository.ensureLoaded()
        TmdbSettingsRepository.uiState
    }.collectAsStateWithLifecycle()
    val libraryUiState by remember {
        LibraryRepository.ensureLoaded()
        LibraryRepository.uiState
    }.collectAsStateWithLifecycle()
    val watchedUiState by remember {
        WatchedRepository.ensureLoaded()
        WatchedRepository.uiState
    }.collectAsStateWithLifecycle()
    val fullyWatchedSeriesKeys by WatchedRepository.fullyWatchedSeriesKeys.collectAsStateWithLifecycle()
    val watchProgressUiState by remember {
        WatchProgressRepository.ensureLoaded()
        WatchProgressRepository.uiState
    }.collectAsStateWithLifecycle()
    val progressByVideoId = remember(watchProgressUiState.entries, id) {
        watchProgressUiState.byVideoIdForContent(id)
    }
    val playerSettingsUiState by remember {
        PlayerSettingsRepository.ensureLoaded()
        PlayerSettingsRepository.uiState
    }.collectAsStateWithLifecycle()
    val networkStatusUiState by NetworkStatusRepository.uiState.collectAsStateWithLifecycle()
    var autoLoadAttempted by remember(type, id) { mutableStateOf(false) }
    var observedOfflineState by remember(type, id) { mutableStateOf(false) }
    var selectedEpisodeForActions by remember(type, id) { mutableStateOf<MetaVideo?>(null) }
    var selectedEpisodeZoomAnchor by remember(type, id) { mutableStateOf<PosterZoomAnchor?>(null) }
    val episodeOverlayHazeState = rememberHazeState()
    var selectedSeasonForActions by remember(type, id) { mutableStateOf<Int?>(null) }
    val commentsEnabled by remember {
        TraktCommentsSettings.ensureLoaded()
        TraktCommentsSettings.enabled
    }.collectAsStateWithLifecycle()
    var comments by remember(type, id) { mutableStateOf<List<TraktCommentReview>>(emptyList()) }
    var commentsCurrentPage by remember(type, id) { mutableIntStateOf(0) }
    var commentsPageCount by remember(type, id) { mutableIntStateOf(0) }
    var isCommentsLoading by remember(type, id) { mutableStateOf(false) }
    var isCommentsLoadingMore by remember(type, id) { mutableStateOf(false) }
    var commentsError by remember(type, id) { mutableStateOf<String?>(null) }
    var selectedComment by remember(type, id) { mutableStateOf<TraktCommentReview?>(null) }
    val detailsScope = rememberCoroutineScope()
    var showLibraryListPicker by remember(type, id) { mutableStateOf(false) }
    var pickerTabs by remember(type, id) { mutableStateOf<List<TrackingLibraryTab>>(emptyList()) }
    var pickerMembership by remember(type, id) { mutableStateOf<Map<String, Boolean>>(emptyMap()) }
    var pickerPending by remember(type, id) { mutableStateOf(false) }
    var pickerError by remember(type, id) { mutableStateOf<String?>(null) }
    var pendingTrackingRemoval by remember(type, id) {
        mutableStateOf<PendingTrackingMembershipRemoval?>(null)
    }
    val trackingListsUpdateFailedMessage = stringResource(Res.string.tracking_lists_update_failed)
    var episodeImdbRatings by remember(type, id) { mutableStateOf<Map<Pair<Int, Int>, Double>>(emptyMap()) }
    var deferredMetaWorkAllowed by remember(type, id) { mutableStateOf(false) }

    // The app shell publishes the details snapshot as soon as the route appears, but it has no
    // artwork at that point. Re-publish here once the meta (and therefore the poster) is known.
    LaunchedEffect(
        displayedMeta?.id,
        displayedMeta?.type,
        displayedMeta?.name,
        displayedMeta?.poster,
        displayedMeta?.releaseInfo,
    ) {
        val meta = displayedMeta ?: return@LaunchedEffect
        AppPresenceState.publish(
            PresenceSnapshot.Details(
                title = meta.name,
                posterUrl = meta.poster,
                year = meta.releaseInfo,
                metaId = meta.id,
                metaType = meta.type,
            ),
        )
    }

    LaunchedEffect(
        displayedMeta?.id,
        displayedMeta?.type,
        displayedMeta?.name,
        displayedMeta?.videos,
        watchedUiState.items,
        watchedUiState.isLoaded,
        watchedUiState.hasLoadedRemoteItems,
        fullyWatchedSeriesKeys,
        watchProgressUiState.entries,
        trackingSettingsUiState.watchProgressSource,
    ) {
        val meta = displayedMeta ?: return@LaunchedEffect
        val posterKey = watchedItemKey(meta.type, meta.id)
        val expectedEpisodeKeys = meta.videos.map { episode ->
            watchedItemKey(meta.type, meta.id, episode.season, episode.episode)
        }
        val matchedEpisodeKeys = expectedEpisodeKeys.filter(watchedUiState.watchedKeys::contains)
        val completedProgressMatches = meta.videos.count { episode ->
            val videoId = buildPlaybackVideoId(
                parentMetaId = meta.id,
                seasonNumber = episode.season,
                episodeNumber = episode.episode,
                fallbackVideoId = episode.id,
            )
            progressByVideoId[videoId]?.isEffectivelyCompleted == true
        }
        val directItemKeys = watchedUiState.items
            .asSequence()
            .filter { item -> item.id == meta.id }
            .take(10)
            .joinToString(separator = ",") { item ->
                watchedItemKey(item.type, item.id, item.season, item.episode)
            }
        val titleCandidateKeys = watchedUiState.items
            .asSequence()
            .filter { item -> item.name.equals(meta.name, ignoreCase = true) }
            .take(10)
            .joinToString(separator = ",") { item ->
                watchedItemKey(item.type, item.id, item.season, item.episode)
            }
        watchedMarkerDiagnosticLog.i {
            "marker state requestedSource=${trackingSettingsUiState.watchProgressSource} " +
                "content=${meta.type}:${meta.id} repositoryLoaded=${watchedUiState.isLoaded} " +
                "remoteLoaded=${watchedUiState.hasLoadedRemoteItems} repositoryItems=${watchedUiState.items.size} " +
                "posterKey=$posterKey posterInWatched=${posterKey in watchedUiState.watchedKeys} " +
                "posterInFullyWatched=${posterKey in fullyWatchedSeriesKeys} videos=${meta.videos.size} " +
                "episodeMarkerMatches=${matchedEpisodeKeys.size} completedProgressMatches=$completedProgressMatches " +
                "directItemKeys=[$directItemKeys] titleCandidateKeys=[$titleCandidateKeys] " +
                "expectedEpisodeKeys=[${expectedEpisodeKeys.take(10).joinToString(",")}] " +
                "repositoryKeySample=[${watchedUiState.watchedKeys.take(10).joinToString(",")}]"
        }
    }

    val shouldShowComments = commentsEnabled &&
        traktAuthUiState.mode == TraktConnectionMode.CONNECTED &&
        displayedMeta != null &&
        displayedMeta.type.lowercase().let { it == "movie" || it == "series" || it == "show" || it == "tv" }

    LaunchedEffect(displayedMeta?.id) {
        deferredMetaWorkAllowed = false
        if (displayedMeta != null) {
            delay(250)
            deferredMetaWorkAllowed = true
        }
    }

    LaunchedEffect(displayedMeta?.id, shouldShowComments, deferredMetaWorkAllowed) {
        if (displayedMeta == null || !shouldShowComments) {
            comments = emptyList()
            commentsCurrentPage = 0
            commentsPageCount = 0
            commentsError = null
            return@LaunchedEffect
        }
        if (!deferredMetaWorkAllowed) return@LaunchedEffect
        isCommentsLoading = true
        commentsError = null
        try {
            val result = TraktCommentsRepository.getCommentsPage(displayedMeta, page = 1)
            comments = result.items
            commentsCurrentPage = result.currentPage
            commentsPageCount = result.pageCount
        } catch (e: Exception) {
            commentsError = e.message ?: getString(Res.string.details_comments_load_failed)
        }
        isCommentsLoading = false
    }

    LaunchedEffect(displayedMeta?.id, displayedMeta?.videos, deferredMetaWorkAllowed) {
        val metaForRatings = displayedMeta
        if (!deferredMetaWorkAllowed) return@LaunchedEffect
        if (metaForRatings == null || !metaForRatings.isSeriesLikeForEpisodeRatings()) {
            episodeImdbRatings = emptyMap()
            return@LaunchedEffect
        }

        val imdbId = extractImdbId(metaForRatings.id) ?: extractImdbId(id)
        val tmdbId = extractTmdbId(metaForRatings.id)
            ?: extractTmdbId(id)
            ?: TmdbService.ensureTmdbId(metaForRatings.id, metaForRatings.type)?.toIntOrNull()
            ?: TmdbService.ensureTmdbId(id, type)?.toIntOrNull()

        if (imdbId == null && tmdbId == null) {
            episodeImdbRatings = emptyMap()
            return@LaunchedEffect
        }

        episodeImdbRatings = ImdbEpisodeRatingsRepository.getEpisodeRatings(
            imdbId = imdbId,
            tmdbId = tmdbId,
        )
    }

    LaunchedEffect(type, id, displayedMeta, uiState.isLoading, autoLoadAttempted) {
        if (!autoLoadAttempted && displayedMeta == null && !uiState.isLoading) {
            autoLoadAttempted = true
            MetaDetailsRepository.load(type, id)
        }
    }

    LaunchedEffect(
        type,
        id,
        displayedMeta?.id,
        uiState.isLoading,
        trackingSettingsUiState.moreLikeThisSource,
        traktAuthUiState.mode,
        tmdbSettingsUiState.enabled,
        tmdbSettingsUiState.useMoreLikeThis,
        tmdbSettingsUiState.language,
    ) {
        if (displayedMeta != null && !uiState.isLoading) {
            MetaDetailsRepository.load(type, id)
        }
    }

    LaunchedEffect(networkStatusUiState.condition, displayedMeta, uiState.isLoading, type, id) {
        when (networkStatusUiState.condition) {
            NetworkCondition.NoInternet,
            NetworkCondition.ServersUnreachable,
            -> {
                observedOfflineState = true
            }

            NetworkCondition.Online -> {
                if (!observedOfflineState) return@LaunchedEffect
                observedOfflineState = false
                if (displayedMeta == null && !uiState.isLoading) {
                    MetaDetailsRepository.load(type, id)
                }
            }

            NetworkCondition.Unknown,
            NetworkCondition.Checking,
            -> Unit
        }
    }

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background),
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .then(
                    if (selectedEpisodeZoomAnchor != null) {
                        Modifier.hazeSource(state = episodeOverlayHazeState)
                    } else {
                        Modifier
                    },
                )
                .background(MaterialTheme.colorScheme.background),
        ) {
            when {
            displayedMeta == null && uiState.isLoading -> {
                NuvioLoadingIndicator(
                    modifier = Modifier.align(Alignment.Center),
                    color = MaterialTheme.colorScheme.primary,
                )
            }

            displayedMeta == null && uiState.errorMessage != null -> {
                Column(
                    modifier = Modifier
                        .align(Alignment.Center)
                        .padding(32.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        text = stringResource(Res.string.details_failed_to_load),
                        style = MaterialTheme.typography.titleLarge,
                        color = MaterialTheme.colorScheme.onBackground,
                    )
                    Text(
                        text = when (networkStatusUiState.condition) {
                            NetworkCondition.NoInternet -> stringResource(Res.string.details_check_connection)
                            NetworkCondition.ServersUnreachable -> stringResource(Res.string.details_servers_unreachable)
                            else -> uiState.errorMessage.orEmpty()
                        },
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(modifier = Modifier.height(8.dp))
                    Button(
                        onClick = {
                            NetworkStatusRepository.requestRefresh(force = true)
                            MetaDetailsRepository.load(type, id)
                        },
                    ) {
                        Text(stringResource(Res.string.action_retry))
                    }
                }
            }

            displayedMeta != null -> {
                val meta = displayedMeta
                val metaPreview = remember(meta) { meta.toMetaPreview() }
                val todayIsoDate = CurrentDateProvider.todayIsoDate()
                val isSaved = remember(
                    libraryUiState.items,
                    libraryUiState.sections,
                    libraryUiState.sourceMode,
                    meta.id,
                    meta.type,
                ) {
                    LibraryRepository.isSaved(meta.id, meta.type)
                }
                val isWatched = remember(watchedUiState.watchedKeys, fullyWatchedSeriesKeys, metaPreview) {
                    WatchingState.isPosterWatched(
                        watchedKeys = watchedUiState.watchedKeys,
                        item = metaPreview,
                        fullyWatchedSeriesKeys = fullyWatchedSeriesKeys,
                    )
                }
                val openLibraryListPicker = remember(meta) {
                    {
                        val libraryItem = meta.toLibraryItem(savedAtEpochMs = 0L)
                        pickerTabs = LibraryRepository.libraryListTabs(libraryItem)
                        pickerMembership = pickerTabs.associate { it.key to false }
                        pickerPending = true
                        pickerError = null
                        showLibraryListPicker = true
                        detailsScope.launch {
                            runCatching {
                                val snapshot = LibraryRepository.getMembershipSnapshot(libraryItem)
                                val tabs = LibraryRepository.libraryListTabs(libraryItem)
                                pickerTabs = tabs
                                pickerMembership = tabs.associate { tab ->
                                    tab.key to (snapshot[tab.key] == true)
                                }
                            }.onFailure { error ->
                                pickerError = error.message ?: getString(Res.string.trakt_lists_load_failed)
                            }
                            pickerPending = false
                        }
                        Unit
                    }
                }
                val toggleSaved = remember(meta, trackingListsUpdateFailedMessage) {
                    {
                        val item = meta.toLibraryItem(savedAtEpochMs = 0L)
                        detailsScope.launch {
                            val toggleMembership: suspend (Set<TrackingProviderId>) ->
                                TrackingMembershipApplyResult = { confirmedProviders ->
                                LibraryRepository.toggleSaved(
                                    item = item,
                                    confirmedRemovalProviders = confirmedProviders,
                                )
                            }
                            executeTrackingMembershipOperation(
                                operation = { toggleMembership(emptySet()) },
                                onSuccess = { result ->
                                    if (result.requiresRemovalConfirmation) {
                                        pendingTrackingRemoval = PendingTrackingMembershipRemoval(
                                            itemTitle = item.name,
                                            confirmations = result.requiredRemovalConfirmations,
                                            retry = toggleMembership,
                                            onApplied = ::showTrackingMembershipRewriteFeedback,
                                            onFailure = { error ->
                                                NuvioToastController.show(
                                                    error.message ?: trackingListsUpdateFailedMessage,
                                                )
                                            },
                                        )
                                    } else {
                                        showTrackingMembershipRewriteFeedback(result)
                                    }
                                },
                                onFailure = { error ->
                                    NuvioToastController.show(
                                        error.message ?: trackingListsUpdateFailedMessage,
                                    )
                                },
                            )
                        }
                        Unit
                    }
                }
                val toggleWatched = remember(metaPreview) {
                    {
                        detailsScope.launch {
                            WatchingActions.togglePosterWatched(metaPreview)
                        }
                        Unit
                    }
                }
                LaunchedEffect(meta.id, meta.type, watchProgressUiState.hasLoadedRemoteProgress) {
                    if (meta.type.lowercase() in setOf("series", "show", "tv", "tvshow")) {
                        WatchProgressRepository.refreshEpisodeProgress(meta.id)
                    }
                }
                LaunchedEffect(
                    meta.id,
                    meta.type,
                    todayIsoDate,
                    watchedUiState.isLoaded,
                    watchProgressUiState.hasLoadedRemoteProgress,
                    watchedUiState.watchedKeys,
                    watchProgressUiState.entries,
                ) {
                    if (watchedUiState.isLoaded && watchProgressUiState.hasLoadedRemoteProgress) {
                        WatchingActions.reconcileSeriesWatchedState(
                            meta = meta,
                            todayIsoDate = todayIsoDate,
                        )
                    }
                }
                val movieProgress = progressByVideoId[meta.id]
                    ?.takeUnless { it.isCompleted }
                val cwPrefs by ContinueWatchingPreferencesRepository.uiState.collectAsStateWithLifecycle()
                val seriesAction = remember(watchProgressUiState.entries, watchedUiState.items, meta, todayIsoDate, cwPrefs.upNextFromFurthestEpisode, watchedUiState.watchedKeys) {
                    meta.seriesPrimaryAction(
                        entries = watchProgressUiState.entries,
                        watchedItems = watchedUiState.items,
                        todayIsoDate = todayIsoDate,
                        preferFurthestEpisode = cwPrefs.upNextFromFurthestEpisode,
                        watchedKeys = watchedUiState.watchedKeys,
                    )
                }
                val seriesActionVideo = remember(seriesAction, meta.id, meta.videos) {
                    val action = seriesAction ?: return@remember null
                    meta.videos.firstOrNull { video ->
                        if (action.seasonNumber != null && action.episodeNumber != null) {
                            video.season == action.seasonNumber &&
                                video.episode == action.episodeNumber
                        } else {
                            buildPlaybackVideoId(
                                parentMetaId = meta.id,
                                seasonNumber = video.season,
                                episodeNumber = video.episode,
                                fallbackVideoId = video.id,
                            ) == action.videoId || video.id == action.videoId
                        }
                    }
                }
                val seriesPauseDescription = remember(seriesActionVideo) {
                    seriesActionVideo?.overview
                }
                val seriesStreamVideoId = remember(seriesAction, seriesActionVideo) {
                    val action = seriesAction ?: return@remember null
                    seriesActionVideo?.id?.takeIf { it.isNotBlank() } ?: action.videoId
                }
                val hasEpisodes = meta.videos.any { it.season != null || it.episode != null }
                val episodeListGroupedEpisodes = remember(
                    meta.videos,
                    meta.type,
                    metaScreenSettingsUiState.episodeCardStyle,
                ) {
                    if (metaScreenSettingsUiState.episodeCardStyle == MetaEpisodeCardStyle.List) {
                        meta.groupedEpisodesForDisplay()
                    } else {
                        emptyMap()
                    }
                }
                val episodeListSeasons = remember(episodeListGroupedEpisodes) {
                    episodeListGroupedEpisodes.keys.sortedBy(::seasonSortKey)
                }
                var selectedEpisodeListSeason by rememberSaveable(meta.id) {
                    mutableStateOf<Int?>(null)
                }
                val defaultEpisodeListSeason = seriesAction?.seasonNumber
                    ?.takeIf { it in episodeListGroupedEpisodes }
                    ?: episodeListSeasons.firstOrNull()
                val currentEpisodeListSeason = selectedEpisodeListSeason
                    ?.takeIf { it in episodeListGroupedEpisodes }
                    ?: defaultEpisodeListSeason
                val hasProductionSection = remember(meta) {
                    meta.productionCompanies.isNotEmpty() || meta.networks.isNotEmpty()
                }
                val hasAdditionalInfoSection = remember(meta) {
                    meta.status != null ||
                        meta.releaseInfo != null ||
                        meta.runtime != null ||
                        meta.ageRating != null ||
                        meta.country != null ||
                        meta.language != null
                }
                val hasCollectionSection = remember(meta) {
                    meta.collectionName != null && meta.collectionItems.isNotEmpty()
                }
                val hasMoreLikeThisSection = remember(meta) {
                    meta.moreLikeThis.isNotEmpty()
                }
                val hasTrailersSection = remember(meta) {
                    meta.trailers.isNotEmpty()
                }
                val uriHandler = LocalUriHandler.current
                val trailerPlaybackMode = AppFeaturePolicy.trailerPlaybackMode
                val inAppTrailerPlaybackEnabled = trailerPlaybackMode == TrailerPlaybackMode.IN_APP
                val trailerScope = rememberCoroutineScope()
                var selectedTrailer by remember(meta.id) { mutableStateOf<MetaTrailer?>(null) }
                var trailerPlaybackSource by remember(meta.id) { mutableStateOf<TrailerPlaybackSource?>(null) }
                var trailerLoading by remember(meta.id) { mutableStateOf(false) }
                var trailerErrorMessage by remember(meta.id) { mutableStateOf<String?>(null) }
                var trailerRequestToken by remember(meta.id) { mutableIntStateOf(0) }
                var isLeavingDetails by remember(meta.id) { mutableStateOf(false) }
                val heroTrailerCandidate = remember(meta.trailers) {
                    selectHeroTrailer(meta.trailers)
                }
                val heroTrailerPlaybackEnabled = AppFeaturePolicy.heroTrailerPlaybackSupported &&
                    inAppTrailerPlaybackEnabled &&
                    metaScreenSettingsUiState.heroTrailerPlayback
                var heroTrailerPlaybackSource by remember(meta.id, heroTrailerCandidate?.id) { mutableStateOf<TrailerPlaybackSource?>(null) }
                var heroTrailerReady by remember(meta.id, heroTrailerCandidate?.id) { mutableStateOf(false) }
                var heroTrailerFinished by remember(meta.id, heroTrailerCandidate?.id) { mutableStateOf(false) }
                val heroTrailerMuted by HeroTrailerAudioState.muted.collectAsStateWithLifecycle()
                LaunchedEffect(
                    heroTrailerPlaybackEnabled,
                    heroTrailerCandidate?.id,
                    heroTrailerCandidate?.key,
                    deferredMetaWorkAllowed,
                ) {
                    heroTrailerPlaybackSource = null
                    heroTrailerReady = false
                    heroTrailerFinished = false
                    if (!deferredMetaWorkAllowed || !heroTrailerPlaybackEnabled || heroTrailerCandidate == null) {
                        return@LaunchedEffect
                    }
                    val resolvedSource = runCatching {
                        TrailerPlaybackResolver.resolveFromYouTubeUrl(heroTrailerCandidate.youtubePlaybackUrl())
                    }.getOrNull()
                    if (resolvedSource == null) {
                        heroTrailerFinished = true
                    } else {
                        heroTrailerPlaybackSource = resolvedSource
                    }
                }
                val onBackFromDetails: () -> Unit = {
                    isLeavingDetails = true
                    heroTrailerReady = false
                    heroTrailerFinished = true
                    onBack()
                }
                val resolveTrailer: (MetaTrailer) -> Unit = remember(meta.id, trailerPlaybackMode, uriHandler) {
                    { trailer ->
                        val youtubeUrl = trailer.youtubePlaybackUrl()
                        when (trailerPlaybackMode) {
                            TrailerPlaybackMode.EXTERNAL -> runCatching { uriHandler.openUri(youtubeUrl) }
                            TrailerPlaybackMode.IN_APP -> {
                                selectedTrailer = trailer
                                trailerPlaybackSource = null
                                trailerErrorMessage = null
                                trailerLoading = true
                                trailerRequestToken += 1
                                val currentRequestToken = trailerRequestToken
                                trailerScope.launch {
                                    val resolvedSource = runCatching {
                                        TrailerPlaybackResolver.resolveFromYouTubeUrl(youtubeUrl)
                                    }.getOrNull()
                                    if (currentRequestToken != trailerRequestToken) {
                                        return@launch
                                    }
                                    trailerPlaybackSource = resolvedSource
                                    trailerErrorMessage = if (resolvedSource == null) {
                                        getString(Res.string.trailer_no_playable_stream)
                                    } else {
                                        null
                                    }
                                    trailerLoading = false
                                }
                            }
                        }
                    }
                }
                val playText = stringResource(Res.string.action_play)
                val resumeText = stringResource(Res.string.action_resume)
                val playButtonLabel = remember(movieProgress, seriesAction, meta.type, hasEpisodes, playText, resumeText) {
                    when {
                        (meta.type == "series" || hasEpisodes) && seriesAction != null ->
                            seriesAction.label
                        meta.type != "series" && !hasEpisodes && movieProgress != null ->
                            resumeText
                        else -> playText
                    }
                }
                val onPrimaryPlayClick: () -> Unit = {
                    when {
                        (meta.type == "series" || hasEpisodes) && seriesAction != null -> {
                            onPlay?.invoke(
                                meta.type,
                                seriesStreamVideoId ?: seriesAction.videoId,
                                meta.id,
                                meta.type,
                                meta.name,
                                meta.logo,
                                meta.poster,
                                meta.background,
                                seriesAction.seasonNumber,
                                seriesAction.episodeNumber,
                                seriesAction.episodeTitle,
                                seriesAction.episodeThumbnail,
                                seriesPauseDescription,
                                seriesAction.resumePositionMs,
                            )
                        }

                        else -> {
                            onPlay?.invoke(
                                meta.type,
                                meta.id,
                                meta.id,
                                meta.type,
                                meta.name,
                                meta.logo,
                                meta.poster,
                                meta.background,
                                null,
                                null,
                                null,
                                null,
                                meta.description,
                                movieProgress?.lastPositionMs,
                            )
                        }
                    }
                }
                val manualPlayHandler = onPlayManually
                val showManualPlayOption = manualPlayHandler != null && StreamAutoPlayPolicy.isEffectivelyEnabled(playerSettingsUiState)
                val onPrimaryPlayLongClick: (() -> Unit)? = manualPlayHandler
                    ?.takeIf { showManualPlayOption }
                    ?.let { manualPlay ->
                        {
                            when {
                                (meta.type == "series" || hasEpisodes) && seriesAction != null -> {
                                    manualPlay(
                                        meta.type,
                                        seriesStreamVideoId ?: seriesAction.videoId,
                                        meta.id,
                                        meta.type,
                                        meta.name,
                                        meta.logo,
                                        meta.poster,
                                        meta.background,
                                        seriesAction.seasonNumber,
                                        seriesAction.episodeNumber,
                                        seriesAction.episodeTitle,
                                        seriesAction.episodeThumbnail,
                                        seriesPauseDescription,
                                        seriesAction.resumePositionMs,
                                    )
                                }

                                else -> {
                                    manualPlay(
                                        meta.type,
                                        meta.id,
                                        meta.id,
                                        meta.type,
                                        meta.name,
                                        meta.logo,
                                        meta.poster,
                                        meta.background,
                                        null,
                                        null,
                                        null,
                                        null,
                                        meta.description,
                                        movieProgress?.lastPositionMs,
                                    )
                                }
                            }
                        }
                    }
                val onEpisodePlayClick: (MetaVideo) -> Unit = { video ->
                    val season = video.season
                    val episode = video.episode
                    val playbackVideoId = buildPlaybackVideoId(
                        parentMetaId = meta.id,
                        seasonNumber = season,
                        episodeNumber = episode,
                        fallbackVideoId = video.id,
                    )
                    val streamVideoId = video.id.takeIf { it.isNotBlank() } ?: playbackVideoId
                    val savedProgress = watchProgressUiState.progressForVideo(
                        videoId = streamVideoId,
                        parentMetaId = meta.id,
                        seasonNumber = season,
                        episodeNumber = episode,
                    )
                        ?.takeUnless { it.isCompleted }
                    onPlay?.invoke(
                        meta.type,
                        streamVideoId,
                        meta.id,
                        meta.type,
                        meta.name,
                        meta.logo,
                        meta.poster,
                        meta.background,
                        season,
                        episode,
                        video.title,
                        video.thumbnail,
                        video.overview,
                        savedProgress?.lastPositionMs,
                    )
                }
                val onEpisodeManualPlayClick: (MetaVideo) -> Unit = { video ->
                    val season = video.season
                    val episode = video.episode
                    val playbackVideoId = buildPlaybackVideoId(
                        parentMetaId = meta.id,
                        seasonNumber = season,
                        episodeNumber = episode,
                        fallbackVideoId = video.id,
                    )
                    val streamVideoId = video.id.takeIf { it.isNotBlank() } ?: playbackVideoId
                    val savedProgress = watchProgressUiState.progressForVideo(
                        videoId = streamVideoId,
                        parentMetaId = meta.id,
                        seasonNumber = season,
                        episodeNumber = episode,
                    )
                        ?.takeUnless { it.isCompleted }
                    onPlayManually?.invoke(
                        meta.type,
                        streamVideoId,
                        meta.id,
                        meta.type,
                        meta.name,
                        meta.logo,
                        meta.poster,
                        meta.background,
                        season,
                        episode,
                        video.title,
                        video.thumbnail,
                        video.overview,
                        savedProgress?.lastPositionMs,
                    )
                }
                val listState = rememberLazyListState()
                val heroStretchState = rememberHeroStretchState(listState)
                val density = LocalDensity.current
                val safeAreaTopPx = with(density) {
                    WindowInsets.statusBars
                        .asPaddingValues()
                        .calculateTopPadding()
                        .toPx()
                }
                val heroHeightPx = rememberSaveable(meta.id) { mutableIntStateOf(0) }
                // Keep pixel-by-pixel list state reads out of this composition.
                val detailScrollOffsetPx = remember(listState, heroHeightPx) {
                    {
                        if (listState.firstVisibleItemIndex == 0) {
                            listState.firstVisibleItemScrollOffset.toFloat()
                        } else {
                            heroHeightPx.intValue.toFloat() + listState.firstVisibleItemScrollOffset
                        }
                    }
                }
                val heroScrollOffset = remember(detailScrollOffsetPx) {
                    { detailScrollOffsetPx().toInt() }
                }
                val isHeroCollapsed = remember(listState, heroHeightPx, safeAreaTopPx) {
                    derivedStateOf {
                        if (listState.firstVisibleItemIndex > 0) {
                            true
                        } else {
                            val measuredHeroHeightPx = heroHeightPx.intValue
                            val thresholdPx = (measuredHeroHeightPx - safeAreaTopPx).coerceAtLeast(0f)
                            measuredHeroHeightPx > 0 && detailScrollOffsetPx() > thresholdPx
                        }
                    }
                }
                val heroTrailerSourceUrl = heroTrailerPlaybackSource
                    ?.videoUrl
                    ?.takeIf { it.isNotBlank() && heroTrailerPlaybackEnabled && !heroTrailerFinished && !isLeavingDetails }
                val heroTrailerSourceAudioUrl = heroTrailerPlaybackSource
                    ?.audioUrl
                    ?.takeIf { heroTrailerSourceUrl != null && it.isNotBlank() }
                val heroTrailerPlayWhenReady = heroTrailerSourceUrl != null &&
                    !isLeavingDetails &&
                    !isHeroCollapsed.value
                val headerTarget = if (isHeroCollapsed.value) 1f else 0f
                val headerProgressState = animateFloatAsState(
                    targetValue = headerTarget,
                    animationSpec = tween(
                        durationMillis = if (headerTarget > 0f) 150 else 100,
                        easing = LinearOutSlowInEasing,
                    ),
                    label = "detail_floating_header_progress",
                )
                val headerProgressProvider = remember(headerProgressState) {
                    { headerProgressState.value }
                }
                val animatedShowHeroBackButton by remember(headerProgressState) {
                    derivedStateOf { headerProgressState.value <= 0.05f }
                }
                val showHeroBackButton = if (isDesktop) {
                    !isHeroCollapsed.value
                } else {
                    animatedShowHeroBackButton
                }
                val headerInteractive by remember(headerProgressState) {
                    derivedStateOf { headerProgressState.value > 0.05f }
                }

                BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
                    val colorScheme = MaterialTheme.colorScheme
                    val screenMaxWidth = maxWidth
                    val isTablet = screenMaxWidth >= 720.dp
                    val useDesktopDetailLayout = isDesktop && screenMaxWidth >= 1000.dp
                    val viewportHeight = maxHeight
                    val desktopPageHorizontalPadding = desktopPageHorizontalPaddingForWidth(screenMaxWidth.value)
                    val contentHorizontalPadding = if (isDesktop) {
                        desktopPageHorizontalPadding
                    } else if (isTablet) {
                        32.dp
                    } else {
                        18.dp
                    }
                    val contentMaxWidth = detailTabletContentMaxWidth(screenMaxWidth, isTablet)
                    val backdropUrl = meta.background ?: meta.poster
                    val backgroundMode = metaScreenSettingsUiState.backgroundMode
                    val dominantColorEnabled = backgroundMode == MetaScreenBackgroundMode.DominantColor &&
                        deferredMetaWorkAllowed &&
                        !backdropUrl.isNullOrBlank()
                    val adaptiveScrollbarColorEnabled = useDesktopDetailLayout &&
                        deferredMetaWorkAllowed &&
                        !backdropUrl.isNullOrBlank()
                    val backdropColorExtractionEnabled = dominantColorEnabled || adaptiveScrollbarColorEnabled
                    var dominantBackdropPainter by remember(meta.id, backdropUrl) {
                        mutableStateOf<Painter?>(null)
                    }
                    var dominantBackdropImageBitmap by remember(meta.id, backdropUrl) {
                        mutableStateOf<ImageBitmap?>(null)
                    }
                    val dominantImageBitmapColorState = rememberDominantColorState(
                        defaultColor = colorScheme.background,
                        defaultOnColor = colorScheme.onBackground,
                    )
                    val dominantPainterColorState = rememberPainterDominantColorState(
                        defaultColor = colorScheme.background,
                        defaultOnColor = colorScheme.onBackground,
                    )
                    LaunchedEffect(backdropColorExtractionEnabled, dominantBackdropImageBitmap, dominantBackdropPainter) {
                        val imageBitmap = dominantBackdropImageBitmap
                        val painter = dominantBackdropPainter
                        if (backdropColorExtractionEnabled) {
                            when {
                                imageBitmap != null -> runCatching {
                                    dominantImageBitmapColorState.updateFrom(imageBitmap)
                                }
                                painter != null -> runCatching {
                                    dominantPainterColorState.updateFrom(painter)
                                }
                            }
                        }
                    }
                    val extractedDominantColor = if (dominantBackdropImageBitmap != null) {
                        dominantImageBitmapColorState.color
                    } else {
                        dominantPainterColorState.color
                    }
                    val dominantBackdropTargetColor = if (dominantColorEnabled) {
                        dominantBackdropBlendColor(extractedDominantColor, colorScheme.background)
                    } else {
                        colorScheme.background
                    }
                    val dominantBackdropColor by animateColorAsState(
                        targetValue = dominantBackdropTargetColor,
                        animationSpec = tween(
                            durationMillis = 320,
                            easing = LinearOutSlowInEasing,
                        ),
                        label = "detail_dominant_backdrop_color",
                    )

                    Box(modifier = Modifier.fillMaxSize()) {
                        when (backgroundMode) {
                            MetaScreenBackgroundMode.Normal -> Unit
                            MetaScreenBackgroundMode.Cinematic -> if (deferredMetaWorkAllowed && backdropUrl != null) {
                                AsyncImage(
                                    model = if (isDesktop) originalTmdbImageUrl(backdropUrl) else backdropUrl,
                                    contentDescription = null,
                                    modifier = Modifier
                                        .fillMaxSize()
                                        .blur(30.dp),
                                    contentScale = ContentScale.Crop,
                                )
                                Box(
                                    modifier = Modifier
                                        .fillMaxSize()
                                        .background(
                                            colorScheme.background.copy(
                                                alpha = if (isDesktop) 0.48f else 0.92f,
                                            ),
                                        ),
                                )
                            }
                            MetaScreenBackgroundMode.DominantColor -> if (deferredMetaWorkAllowed) {
                                Box(
                                    modifier = Modifier
                                        .fillMaxSize()
                                        .background(dominantBackdropColor),
                                )
                            }
                        }
                        if (useDesktopDetailLayout) {
                            DesktopDetailBackdrop(
                                meta = meta,
                                viewportHeight = viewportHeight,
                                heroTrailerSourceUrl = heroTrailerSourceUrl,
                                heroTrailerSourceAudioUrl = heroTrailerSourceAudioUrl,
                                heroTrailerReady = heroTrailerReady,
                                heroTrailerPlayWhenReady = heroTrailerPlayWhenReady,
                                heroTrailerMuted = heroTrailerMuted,
                                heroGradientColor = dominantBackdropColor.takeIf { dominantColorEnabled },
                                onBackdropLoaded = { painter -> dominantBackdropPainter = painter },
                                onHeroTrailerReady = {
                                    if (!heroTrailerFinished) heroTrailerReady = true
                                },
                                onHeroTrailerEnded = {
                                    heroTrailerReady = false
                                    heroTrailerFinished = true
                                },
                                onHeroTrailerError = {
                                    heroTrailerReady = false
                                    heroTrailerFinished = true
                                },
                            )

                            if (backgroundMode == MetaScreenBackgroundMode.Cinematic) {
                                DesktopDetailBackdrop(
                                    meta = meta,
                                    viewportHeight = viewportHeight,
                                    heroTrailerSourceUrl = null,
                                    heroTrailerSourceAudioUrl = null,
                                    heroTrailerReady = false,
                                    heroTrailerPlayWhenReady = false,
                                    heroTrailerMuted = true,
                                    blurBackdrop = true,
                                    onHeroTrailerReady = {},
                                    onHeroTrailerEnded = {},
                                    onHeroTrailerError = {},
                                    modifier = Modifier
                                        .zIndex(0.25f)
                                        .graphicsLayer {
                                            alpha = detailScrolledBackgroundProgress(
                                                scrollOffsetPx = detailScrollOffsetPx(),
                                                heroHeightPx = heroHeightPx.intValue,
                                            )
                                        },
                                )
                            }

                            val scrolledBackgroundColor = if (dominantColorEnabled) {
                                dominantBackdropColor
                            } else {
                                colorScheme.background
                            }
                            Box(
                                modifier = Modifier
                                    .zIndex(0.5f)
                                    .fillMaxSize()
                                    .graphicsLayer {
                                        alpha = detailScrolledBackgroundAlpha(
                                            scrollOffsetPx = detailScrollOffsetPx(),
                                            heroHeightPx = heroHeightPx.intValue,
                                            maxAlpha = if (backgroundMode == MetaScreenBackgroundMode.Cinematic) {
                                                DetailScrolledBackgroundCinematicMaxAlpha
                                            } else {
                                                DetailScrolledBackgroundDefaultMaxAlpha
                                            },
                                        )
                                    }
                                    .background(scrolledBackgroundColor),
                            )
                        }
                        LazyColumn(
                            state = listState,
                            modifier = Modifier
                                .fillMaxSize()
                                .nestedScroll(heroStretchState.nestedScrollConnection)
                                .zIndex(1f),
                        ) {
                            if (useDesktopDetailLayout) {
                                item(
                                    key = "detail-desktop-hero",
                                    contentType = "detail-hero",
                                ) {
                                    DesktopDetailHero(
                                        meta = meta,
                                        playButtonLabel = playButtonLabel,
                                        isSaved = isSaved,
                                        isWatched = isWatched,
                                        onHeightChanged = { heroHeightPx.intValue = it },
                                        heroTrailerSourceUrl = heroTrailerSourceUrl,
                                        heroTrailerReady = heroTrailerReady,
                                        heroTrailerMuted = heroTrailerMuted,
                                        onHeroTrailerMuteToggle = {
                                            HeroTrailerAudioState.toggleMuted()
                                        },
                                        onPlayClick = onPrimaryPlayClick,
                                        onPlayLongClick = if (showManualPlayOption) onPrimaryPlayLongClick else null,
                                        onWatchedClick = toggleWatched,
                                        onSaveClick = toggleSaved,
                                        onSaveLongClick = openLibraryListPicker,
                                    )
                                }
                                configuredMetaSectionItems(
                                    settings = metaScreenSettingsUiState.copy(
                                        items = metaScreenSettingsUiState.items.filterNot {
                                            it.key in desktopHeroOwnedMetaSectionKeys
                                        },
                                    ),
                                    meta = meta,
                                    isTablet = true,
                                    contentHorizontalPadding = desktopPageHorizontalPadding,
                                    contentMaxWidth = Dp.Unspecified,
                                    playButtonLabel = playButtonLabel,
                                    isSaved = isSaved,
                                    isWatched = isWatched,
                                    onPrimaryPlayClick = onPrimaryPlayClick,
                                    onPrimaryPlayLongClick = onPrimaryPlayLongClick,
                                    onSaveClick = toggleSaved,
                                    onSaveLongClick = openLibraryListPicker,
                                    onWatchedClick = toggleWatched,
                                    showManualPlayOption = showManualPlayOption,
                                    preferredEpisodeSeasonNumber = seriesAction?.seasonNumber,
                                    preferredEpisodeNumber = seriesAction?.episodeNumber,
                                    hasProductionSection = hasProductionSection,
                                    hasTrailersSection = hasTrailersSection,
                                    hasEpisodes = hasEpisodes,
                                    hasAdditionalInfoSection = hasAdditionalInfoSection,
                                    hasCollectionSection = hasCollectionSection,
                                    hasMoreLikeThisSection = hasMoreLikeThisSection,
                                    shouldShowComments = shouldShowComments,
                                    comments = comments,
                                    isCommentsLoading = isCommentsLoading,
                                    isCommentsLoadingMore = isCommentsLoadingMore,
                                    commentsCurrentPage = commentsCurrentPage,
                                    commentsPageCount = commentsPageCount,
                                    commentsError = commentsError,
                                    episodeImdbRatings = episodeImdbRatings,
                                    episodeListGroupedEpisodes = episodeListGroupedEpisodes,
                                    episodeListSeasons = episodeListSeasons,
                                    episodeListCurrentSeason = currentEpisodeListSeason,
                                    onEpisodeListSeasonSelect = { selectedEpisodeListSeason = it },
                                    onRetryComments = {
                                        detailsScope.launch {
                                            isCommentsLoading = true
                                            commentsError = null
                                            try {
                                                val result = TraktCommentsRepository.getCommentsPage(meta, page = 1, forceRefresh = true)
                                                comments = result.items
                                                commentsCurrentPage = result.currentPage
                                                commentsPageCount = result.pageCount
                                            } catch (e: Exception) {
                                                commentsError = e.message ?: getString(Res.string.details_comments_load_failed)
                                            }
                                            isCommentsLoading = false
                                        }
                                    },
                                    onLoadMoreComments = {
                                        detailsScope.launch {
                                            isCommentsLoadingMore = true
                                            try {
                                                val nextPage = commentsCurrentPage + 1
                                                val result = TraktCommentsRepository.getCommentsPage(meta, page = nextPage)
                                                val existingIds = comments.map { it.id }.toSet()
                                                val newComments = result.items.filter { it.id !in existingIds }
                                                comments = comments + newComments
                                                commentsCurrentPage = result.currentPage
                                                commentsPageCount = result.pageCount
                                            } catch (_: Exception) { }
                                            isCommentsLoadingMore = false
                                        }
                                    },
                                    onCommentClick = { review -> selectedComment = review },
                                    onTrailerClick = resolveTrailer,
                                    progressByVideoId = progressByVideoId,
                                    watchedKeys = watchedUiState.watchedKeys,
                                    blurUnwatchedEpisodes = metaScreenSettingsUiState.blurUnwatchedEpisodes,
                                    onEpisodeClick = onEpisodePlayClick,
                                    onEpisodeLongPress = { video ->
                                        selectedEpisodeZoomAnchor = PosterZoomAnchorHolder.consume()
                                        selectedEpisodeForActions = video
                                    },
                                    onSeasonLongPress = { season -> selectedSeasonForActions = season },
                                    onOpenMeta = onOpenMeta,
                                    onCastClick = onCastClick,
                                    onCompanyClick = onCompanyClick,
                                    sharedTransitionScope = sharedTransitionScope,
                                    animatedVisibilityScope = animatedVisibilityScope,
                                )
                            } else {
                                item(
                                    key = "detail-hero",
                                    contentType = "detail-hero",
                                ) {
                                    DetailHero(
                                        meta = meta,
                                        isTablet = isTablet,
                                        contentMaxWidth = contentMaxWidth,
                                        viewportHeight = viewportHeight,
                                        scrollOffset = heroScrollOffset,
                                        stretchPx = { heroStretchState.stretchPx },
                                        onHeightChanged = { heroHeightPx.intValue = it },
                                        heroTrailerSourceUrl = heroTrailerSourceUrl,
                                        heroTrailerSourceAudioUrl = heroTrailerSourceAudioUrl,
                                        heroTrailerReady = heroTrailerReady,
                                        heroTrailerPlayWhenReady = { heroTrailerPlayWhenReady },
                                        heroTrailerMuted = heroTrailerMuted,
                                        heroGradientColor = dominantBackdropColor.takeIf { dominantColorEnabled },
                                        onBackdropLoaded = { painter, imageBitmap ->
                                            dominantBackdropPainter = painter
                                            dominantBackdropImageBitmap = imageBitmap
                                        },
                                        onHeroTrailerMuteToggle = {
                                            HeroTrailerAudioState.toggleMuted()
                                        },
                                        onHeroTrailerReady = {
                                            if (!heroTrailerFinished) {
                                                heroTrailerReady = true
                                            }
                                        },
                                        onHeroTrailerEnded = {
                                            heroTrailerReady = false
                                            heroTrailerFinished = true
                                        },
                                        onHeroTrailerError = {
                                            heroTrailerReady = false
                                            heroTrailerFinished = true
                                        },
                                    )
                                }

                                configuredMetaSectionItems(
                                    settings = metaScreenSettingsUiState,
                                    meta = meta,
                                    isTablet = isTablet,
                                    contentHorizontalPadding = contentHorizontalPadding,
                                    contentMaxWidth = if (isTablet) contentMaxWidth else Dp.Unspecified,
                                    playButtonLabel = playButtonLabel,
                                    isSaved = isSaved,
                                    isWatched = isWatched,
                                    onPrimaryPlayClick = onPrimaryPlayClick,
                                    onPrimaryPlayLongClick = onPrimaryPlayLongClick,
                                    onSaveClick = toggleSaved,
                                    onSaveLongClick = openLibraryListPicker,
                                    onWatchedClick = toggleWatched,
                                    showManualPlayOption = showManualPlayOption,
                                    preferredEpisodeSeasonNumber = seriesAction?.seasonNumber,
                                    preferredEpisodeNumber = seriesAction?.episodeNumber,
                                    hasProductionSection = hasProductionSection,
                                    hasTrailersSection = hasTrailersSection,
                                    hasEpisodes = hasEpisodes,
                                    hasAdditionalInfoSection = hasAdditionalInfoSection,
                                    hasCollectionSection = hasCollectionSection,
                                    hasMoreLikeThisSection = hasMoreLikeThisSection,
                                    shouldShowComments = shouldShowComments,
                                    comments = comments,
                                    isCommentsLoading = isCommentsLoading,
                                    isCommentsLoadingMore = isCommentsLoadingMore,
                                    commentsCurrentPage = commentsCurrentPage,
                                    commentsPageCount = commentsPageCount,
                                    commentsError = commentsError,
                                    episodeImdbRatings = episodeImdbRatings,
                                    episodeListGroupedEpisodes = episodeListGroupedEpisodes,
                                    episodeListSeasons = episodeListSeasons,
                                    episodeListCurrentSeason = currentEpisodeListSeason,
                                    onEpisodeListSeasonSelect = { selectedEpisodeListSeason = it },
                                    onRetryComments = {
                                        detailsScope.launch {
                                            isCommentsLoading = true
                                            commentsError = null
                                            try {
                                                val result = TraktCommentsRepository.getCommentsPage(meta, page = 1, forceRefresh = true)
                                                comments = result.items
                                                commentsCurrentPage = result.currentPage
                                                commentsPageCount = result.pageCount
                                            } catch (e: Exception) {
                                                commentsError = e.message ?: getString(Res.string.details_comments_load_failed)
                                            }
                                            isCommentsLoading = false
                                        }
                                    },
                                    onLoadMoreComments = {
                                        detailsScope.launch {
                                            isCommentsLoadingMore = true
                                            try {
                                                val nextPage = commentsCurrentPage + 1
                                                val result = TraktCommentsRepository.getCommentsPage(meta, page = nextPage)
                                                val existingIds = comments.map { it.id }.toSet()
                                                val newComments = result.items.filter { it.id !in existingIds }
                                                comments = comments + newComments
                                                commentsCurrentPage = result.currentPage
                                                commentsPageCount = result.pageCount
                                            } catch (_: Exception) { }
                                            isCommentsLoadingMore = false
                                        }
                                    },
                                    onCommentClick = { review -> selectedComment = review },
                                    onTrailerClick = resolveTrailer,
                                    progressByVideoId = progressByVideoId,
                                    watchedKeys = watchedUiState.watchedKeys,
                                    blurUnwatchedEpisodes = metaScreenSettingsUiState.blurUnwatchedEpisodes,
                                    onEpisodeClick = onEpisodePlayClick,
                                    onEpisodeLongPress = { video -> selectedEpisodeForActions = video },
                                    onSeasonLongPress = { season -> selectedSeasonForActions = season },
                                    onOpenMeta = onOpenMeta,
                                    onCastClick = onCastClick,
                                    onCompanyClick = onCompanyClick,
                                    sharedTransitionScope = sharedTransitionScope,
                                    animatedVisibilityScope = animatedVisibilityScope,
                                )
                            }

                            item(
                                key = "detail-bottom-spacer",
                                contentType = "detail-spacer",
                            ) {
                                Spacer(modifier = Modifier.height(nuvioSafeBottomPadding(32.dp)))
                            }
                        }
                        NuvioDesktopVerticalScrollbar(
                            state = listState,
                            backgroundColor = extractedDominantColor.takeIf { adaptiveScrollbarColorEnabled },
                            modifier = Modifier
                                .align(Alignment.CenterEnd)
                                .fillMaxHeight()
                                .padding(vertical = 8.dp, horizontal = 4.dp)
                                .zIndex(2f),
                        )

                        if (!useDesktopDetailLayout && backgroundMode.usesBackdropBackground &&
                            deferredMetaWorkAllowed && heroHeightPx.intValue > 0
                        ) {
                            val blendColor = dominantBackdropColor.takeIf { dominantColorEnabled }
                                ?: colorScheme.background
                            Box(
                                modifier = Modifier
                                    .zIndex(0.5f)
                                    .fillMaxWidth()
                                    .height(132.dp)
                                    .graphicsLayer {
                                        translationY = heroHeightPx.intValue.toFloat() - detailScrollOffsetPx()
                                    }
                                    .background(
                                        Brush.verticalGradient(
                                            colors = listOf(
                                                blendColor.copy(alpha = 0.98f),
                                                blendColor.copy(alpha = 0.84f),
                                                blendColor.copy(alpha = 0.52f),
                                                Color.Transparent,
                                            ),
                                        ),
                                    ),
                            )
                        }

                        if (!isDesktop && !useDesktopDetailLayout && showHeroBackButton) {
                            NuvioBackButton(
                                onClick = onBackFromDetails,
                                modifier = Modifier.padding(
                                    start = 12.dp,
                                    top = WindowInsets.statusBars.asPaddingValues().calculateTopPadding() + 8.dp,
                                ).zIndex(2f),
                                containerColor = Color.Transparent,
                                contentColor = MaterialTheme.colorScheme.onBackground,
                            )
                        }

                        if (isDesktop) {
                            NuvioBackButton(
                                onClick = onBackFromDetails,
                                modifier = Modifier
                                    .padding(start = desktopPageHorizontalPadding, top = 32.dp)
                                    .zIndex(2f),
                                containerColor = Color.Black.copy(alpha = 0.34f),
                                showContainerOnDesktop = true,
                                contentColor = MaterialTheme.colorScheme.onBackground,
                                buttonSize = 48.dp,
                                iconSize = 24.dp,
                            )
                        }

                        if (!isDesktop) {
                            DetailFloatingHeader(
                                meta = meta,
                                isSaved = isSaved,
                                progressProvider = headerProgressProvider,
                                interactive = headerInteractive,
                                backgroundColor = dominantBackdropColor.takeIf { dominantColorEnabled },
                                onBack = onBackFromDetails,
                                onToggleSaved = toggleSaved,
                                modifier = Modifier.zIndex(2f),
                            )
                        }

                        selectedEpisodeForActions
                            ?.takeIf { selectedEpisodeZoomAnchor == null }
                            ?.let { selectedEpisode ->
                            val isSelectedEpisodeWatched = remember(meta, selectedEpisode, watchedUiState.watchedKeys, progressByVideoId) {
                                isEpisodeWatchedForActions(
                                    meta = meta,
                                    episode = selectedEpisode,
                                    watchedKeys = watchedUiState.watchedKeys,
                                    progressByVideoId = progressByVideoId,
                                )
                            }
                            val previousEpisodes = remember(meta, selectedEpisode, todayIsoDate) {
                                meta.previousReleasedEpisodesBefore(
                                    target = selectedEpisode,
                                    todayIsoDate = todayIsoDate,
                                )
                            }
                            val seasonEpisodes = remember(meta, selectedEpisode, todayIsoDate) {
                                meta.releasedEpisodesForSeason(
                                    seasonNumber = selectedEpisode.season,
                                    todayIsoDate = todayIsoDate,
                                )
                            }
                            val arePreviousEpisodesWatched = remember(previousEpisodes, watchedUiState.watchedKeys, progressByVideoId) {
                                areEpisodesWatchedForActions(
                                    meta = meta,
                                    episodes = previousEpisodes,
                                    watchedKeys = watchedUiState.watchedKeys,
                                    progressByVideoId = progressByVideoId,
                                )
                            }
                            val isSeasonWatched = remember(seasonEpisodes, watchedUiState.watchedKeys, progressByVideoId) {
                                areEpisodesWatchedForActions(
                                    meta = meta,
                                    episodes = seasonEpisodes,
                                    watchedKeys = watchedUiState.watchedKeys,
                                    progressByVideoId = progressByVideoId,
                                )
                            }
                            EpisodeWatchedActionSheet(
                                episode = selectedEpisode,
                                seasonLabel = selectedEpisode.season?.let {
                                    stringResource(Res.string.episodes_season, it)
                                } ?: stringResource(Res.string.episodes_specials),
                                isEpisodeWatched = isSelectedEpisodeWatched,
                                canMarkPreviousEpisodes = previousEpisodes.isNotEmpty(),
                                arePreviousEpisodesWatched = arePreviousEpisodesWatched,
                                isSeasonWatched = isSeasonWatched,
                                onDismiss = { selectedEpisodeForActions = null },
                                onToggleWatched = {
                                    WatchingActions.toggleEpisodeWatched(
                                        meta = meta,
                                        episode = selectedEpisode,
                                        isCurrentlyWatched = isSelectedEpisodeWatched,
                                    )
                                },
                                onTogglePreviousWatched = {
                                    WatchingActions.togglePreviousEpisodesWatched(
                                        meta = meta,
                                        episodes = previousEpisodes,
                                        areCurrentlyWatched = arePreviousEpisodesWatched,
                                    )
                                },
                                onToggleSeasonWatched = {
                                    WatchingActions.toggleSeasonWatched(
                                        meta = meta,
                                        episodes = seasonEpisodes,
                                        areCurrentlyWatched = isSeasonWatched,
                                    )
                                },
                                showPlayManually = showManualPlayOption,
                                onPlayManually = {
                                    onEpisodeManualPlayClick(selectedEpisode)
                                },
                            )
                        }

                        selectedSeasonForActions?.let { selectedSeason ->
                            val seasonLabel = selectedSeasonLabel(selectedSeason)
                            val seasonEpisodes = remember(meta, selectedSeason, todayIsoDate) {
                                meta.releasedEpisodesForSeason(
                                    seasonNumber = selectedSeason,
                                    todayIsoDate = todayIsoDate,
                                )
                            }
                            val previousSeasonEpisodes = remember(meta, selectedSeason, todayIsoDate) {
                                val normalizedSelectedSeason = selectedSeason.coerceAtLeast(0)
                                meta.releasedPlayableEpisodes(todayIsoDate)
                                    .filter { episode ->
                                        val season = episode.season?.coerceAtLeast(0) ?: 0
                                        season > 0 && season < normalizedSelectedSeason
                                    }
                            }
                            val isSeasonWatched = remember(seasonEpisodes, watchedUiState.watchedKeys, progressByVideoId) {
                                areEpisodesWatchedForActions(
                                    meta = meta,
                                    episodes = seasonEpisodes,
                                    watchedKeys = watchedUiState.watchedKeys,
                                    progressByVideoId = progressByVideoId,
                                )
                            }
                            val canMarkPreviousSeasons = remember(previousSeasonEpisodes, watchedUiState.watchedKeys, progressByVideoId) {
                                previousSeasonEpisodes.any { episode ->
                                    !isEpisodeWatchedForActions(
                                        meta = meta,
                                        episode = episode,
                                        watchedKeys = watchedUiState.watchedKeys,
                                        progressByVideoId = progressByVideoId,
                                    )
                                }
                            }
                            SeasonWatchedActionSheet(
                                seasonLabel = seasonLabel,
                                isSeasonWatched = isSeasonWatched,
                                canMarkPreviousSeasons = canMarkPreviousSeasons,
                                onDismiss = { selectedSeasonForActions = null },
                                onToggleSeasonWatched = {
                                    WatchingActions.toggleSeasonWatched(
                                        meta = meta,
                                        episodes = seasonEpisodes,
                                        areCurrentlyWatched = isSeasonWatched,
                                    )
                                },
                                onMarkPreviousSeasonsWatched = {
                                    WatchingActions.togglePreviousEpisodesWatched(
                                        meta = meta,
                                        episodes = previousSeasonEpisodes,
                                        areCurrentlyWatched = false,
                                    )
                                },
                            )
                        }

                        if (inAppTrailerPlaybackEnabled) {
                            TrailerPlayerPopup(
                                visible = selectedTrailer != null,
                                trailerTitle = selectedTrailer?.displayName ?: selectedTrailer?.name.orEmpty(),
                                trailerType = selectedTrailer?.type.orEmpty(),
                                contentTitle = meta.name,
                                playbackSource = trailerPlaybackSource,
                                isLoading = trailerLoading,
                                errorMessage = trailerErrorMessage,
                                onDismiss = {
                                    trailerRequestToken += 1
                                    trailerLoading = false
                                    trailerPlaybackSource = null
                                    trailerErrorMessage = null
                                    selectedTrailer = null
                                },
                                onRetry = selectedTrailer?.let { trailer ->
                                    { resolveTrailer(trailer) }
                                },
                            )
                        }

                        TrackingListPickerDialog(
                            visible = showLibraryListPicker,
                            title = meta.name,
                            tabs = pickerTabs,
                            membership = pickerMembership,
                            isPending = pickerPending,
                            errorMessage = pickerError,
                            onToggle = { listKey ->
                                pickerMembership = toggleTrackingLibraryMembership(
                                    tabs = pickerTabs,
                                    membership = pickerMembership,
                                    key = listKey,
                                )
                            },
                            onDismiss = {
                                if (!pickerPending) {
                                    showLibraryListPicker = false
                                }
                            },
                            onSave = {
                                detailsScope.launch {
                                    pickerPending = true
                                    pickerError = null
                                    val item = meta.toLibraryItem(savedAtEpochMs = 0L)
                                    val desiredMembership = pickerMembership.toMap()
                                    val applyMembership: suspend (Set<TrackingProviderId>) ->
                                        TrackingMembershipApplyResult = { confirmedProviders ->
                                        LibraryRepository.applyMembershipChanges(
                                            item = item,
                                            desiredMembership = desiredMembership,
                                            confirmedRemovalProviders = confirmedProviders,
                                        )
                                    }
                                    val completeMembershipUpdate: suspend (TrackingMembershipApplyResult) -> Unit = { result ->
                                        showTrackingMembershipRewriteFeedback(result)
                                        showLibraryListPicker = false
                                    }
                                    executeTrackingMembershipOperation(
                                        operation = { applyMembership(emptySet()) },
                                        onSuccess = { result ->
                                            if (result.requiresRemovalConfirmation) {
                                                pendingTrackingRemoval = PendingTrackingMembershipRemoval(
                                                    itemTitle = item.name,
                                                    confirmations = result.requiredRemovalConfirmations,
                                                    retry = applyMembership,
                                                    onApplied = completeMembershipUpdate,
                                                    onFailure = { error ->
                                                        pickerError = error.message
                                                            ?: trackingListsUpdateFailedMessage
                                                    },
                                                )
                                            } else {
                                                completeMembershipUpdate(result)
                                            }
                                        },
                                        onFailure = { error ->
                                            pickerError = error.message ?: trackingListsUpdateFailedMessage
                                        },
                                    )
                                    pickerPending = false
                                }
                            },
                        )

                        TrackingMembershipRemovalConfirmationHost(
                            pending = pendingTrackingRemoval,
                            onPendingChange = { pendingTrackingRemoval = it },
                        )

                        selectedComment?.let { comment ->
                            val commentIndex = comments.indexOfFirst { it.id == comment.id }.coerceAtLeast(0)
                            CommentDetailSheet(
                                comment = comment,
                                currentIndex = commentIndex,
                                totalCount = comments.size,
                                canGoBack = commentIndex > 0,
                                canGoForward = commentIndex < comments.size - 1,
                                onPrevious = {
                                    if (commentIndex > 0) {
                                        selectedComment = comments[commentIndex - 1]
                                    }
                                },
                                onNext = {
                                    val nextIndex = commentIndex + 1
                                    if (nextIndex < comments.size) {
                                        selectedComment = comments[nextIndex]
                                    }
                                    if (nextIndex >= comments.size - 3 && commentsCurrentPage < commentsPageCount) {
                                        detailsScope.launch {
                                            isCommentsLoadingMore = true
                                            try {
                                                val nextPage = commentsCurrentPage + 1
                                                val result = TraktCommentsRepository.getCommentsPage(meta, page = nextPage)
                                                val existingIds = comments.map { it.id }.toSet()
                                                val newComments = result.items.filter { it.id !in existingIds }
                                                comments = comments + newComments
                                                commentsCurrentPage = result.currentPage
                                                commentsPageCount = result.pageCount
                                            } catch (_: Exception) { }
                                            isCommentsLoadingMore = false
                                        }
                                    }
                                },
                                onDismiss = { selectedComment = null },
                            )
                        }
                    }
                }
            }
        }

        if (displayedMeta == null) {
            BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
                val loadingBackButtonStartPadding = if (isDesktop) {
                    desktopPageHorizontalPaddingForWidth(maxWidth.value)
                } else {
                    12.dp
                }
                val loadingBackButtonTopPadding = if (isDesktop) {
                    32.dp
                } else {
                    WindowInsets.statusBars.asPaddingValues().calculateTopPadding() + 8.dp
                }
                NuvioBackButton(
                    onClick = onBack,
                    modifier = Modifier.padding(
                        start = loadingBackButtonStartPadding,
                        top = loadingBackButtonTopPadding,
                    ),
                    containerColor = if (isDesktop) Color.Black.copy(alpha = 0.34f) else Color.Transparent,
                    showContainerOnDesktop = isDesktop,
                    contentColor = MaterialTheme.colorScheme.onBackground,
                    buttonSize = if (isDesktop) 48.dp else 40.dp,
                    iconSize = 24.dp,
                )
            }
        }
        }

        val meta = displayedMeta
        val selectedEpisode = selectedEpisodeForActions
        val zoomAnchor = selectedEpisodeZoomAnchor
        if (meta != null && selectedEpisode != null && zoomAnchor != null) {
            val todayIsoDate = CurrentDateProvider.todayIsoDate()
            val isSelectedEpisodeWatched = remember(meta, selectedEpisode, watchedUiState.watchedKeys, progressByVideoId) {
                isEpisodeWatchedForActions(
                    meta = meta,
                    episode = selectedEpisode,
                    watchedKeys = watchedUiState.watchedKeys,
                    progressByVideoId = progressByVideoId,
                )
            }
            val previousEpisodes = remember(meta, selectedEpisode, todayIsoDate) {
                meta.previousReleasedEpisodesBefore(
                    target = selectedEpisode,
                    todayIsoDate = todayIsoDate,
                )
            }
            val seasonEpisodes = remember(meta, selectedEpisode, todayIsoDate) {
                meta.releasedEpisodesForSeason(
                    seasonNumber = selectedEpisode.season,
                    todayIsoDate = todayIsoDate,
                )
            }
            val arePreviousEpisodesWatched = remember(previousEpisodes, watchedUiState.watchedKeys, progressByVideoId) {
                areEpisodesWatchedForActions(
                    meta = meta,
                    episodes = previousEpisodes,
                    watchedKeys = watchedUiState.watchedKeys,
                    progressByVideoId = progressByVideoId,
                )
            }
            val isSeasonWatched = remember(seasonEpisodes, watchedUiState.watchedKeys, progressByVideoId) {
                areEpisodesWatchedForActions(
                    meta = meta,
                    episodes = seasonEpisodes,
                    watchedKeys = watchedUiState.watchedKeys,
                    progressByVideoId = progressByVideoId,
                )
            }
            val seasonLabel = selectedEpisode.season?.let {
                stringResource(Res.string.episodes_season, it)
            } ?: stringResource(Res.string.episodes_specials)
            NuvioPosterZoomActionOverlay(
                imageUrl = zoomAnchor.imageUrl ?: selectedEpisode.thumbnail ?: meta.background ?: meta.poster,
                title = selectedEpisode.title,
                subtitle = localizedSeasonEpisodeCode(selectedEpisode.season, selectedEpisode.episode) ?: seasonLabel,
                isWatched = isSelectedEpisodeWatched,
                blurred = metaScreenSettingsUiState.blurUnwatchedEpisodes && !isSelectedEpisodeWatched,
                depthSurface = NuvioCardDepthSurface.EpisodeCards,
                anchor = zoomAnchor,
                actions = buildList {
                    add(
                        PosterZoomOverlayAction(
                            icon = Icons.Default.CheckCircle,
                            label = if (isSelectedEpisodeWatched) {
                                stringResource(Res.string.episode_mark_unwatched)
                            } else {
                                stringResource(Res.string.episode_mark_watched)
                            },
                            onSelected = {
                                WatchingActions.toggleEpisodeWatched(
                                    meta = meta,
                                    episode = selectedEpisode,
                                    isCurrentlyWatched = isSelectedEpisodeWatched,
                                )
                            },
                        ),
                    )
                    if (previousEpisodes.isNotEmpty()) {
                        add(
                            PosterZoomOverlayAction(
                                icon = Icons.Default.DoneAll,
                                label = if (arePreviousEpisodesWatched) {
                                    stringResource(Res.string.episode_mark_previous_unwatched)
                                } else {
                                    stringResource(Res.string.episode_mark_previous_watched)
                                },
                                onSelected = {
                                    WatchingActions.togglePreviousEpisodesWatched(
                                        meta = meta,
                                        episodes = previousEpisodes,
                                        areCurrentlyWatched = arePreviousEpisodesWatched,
                                    )
                                },
                            ),
                        )
                    }
                    add(
                        PosterZoomOverlayAction(
                            icon = Icons.Default.PlaylistAddCheckCircle,
                            label = if (isSeasonWatched) {
                                stringResource(Res.string.episode_mark_season_unwatched, seasonLabel)
                            } else {
                                stringResource(Res.string.episode_mark_season_watched, seasonLabel)
                            },
                            onSelected = {
                                WatchingActions.toggleSeasonWatched(
                                    meta = meta,
                                    episodes = seasonEpisodes,
                                    areCurrentlyWatched = isSeasonWatched,
                                )
                            },
                        ),
                    )
                    if (onPlayManually != null && StreamAutoPlayPolicy.isEffectivelyEnabled(playerSettingsUiState)) {
                        add(
                            PosterZoomOverlayAction(
                                icon = Icons.Default.PlayArrow,
                                label = stringResource(Res.string.play_manually),
                                onSelected = {
                                    val playbackVideoId = buildPlaybackVideoId(
                                        parentMetaId = meta.id,
                                        seasonNumber = selectedEpisode.season,
                                        episodeNumber = selectedEpisode.episode,
                                        fallbackVideoId = selectedEpisode.id,
                                    )
                                    val streamVideoId = selectedEpisode.id.takeIf { it.isNotBlank() } ?: playbackVideoId
                                    val savedProgress = progressByVideoId[streamVideoId]
                                        ?.takeUnless { it.isCompleted }
                                    onPlayManually.invoke(
                                        meta.type,
                                        streamVideoId,
                                        meta.id,
                                        meta.type,
                                        meta.name,
                                        meta.logo,
                                        meta.poster,
                                        meta.background,
                                        selectedEpisode.season,
                                        selectedEpisode.episode,
                                        selectedEpisode.title,
                                        selectedEpisode.thumbnail,
                                        selectedEpisode.overview,
                                        savedProgress?.lastPositionMs,
                                    )
                                },
                            ),
                        )
                    }
                },
                hazeState = episodeOverlayHazeState,
                onDismissed = {
                    selectedEpisodeForActions = null
                    selectedEpisodeZoomAnchor = null
                },
            )
        }
    }
}

private fun MetaDetails.isSeriesLikeForEpisodeRatings(): Boolean {
    val normalizedType = type.trim().lowercase()
    val hasNumberedEpisodes = videos.any { it.season != null && it.episode != null }
    return hasNumberedEpisodes && normalizedType in setOf("series", "show", "tv", "tvshow")
}

@Composable
private fun selectedSeasonLabel(season: Int): String =
    if (season == 0) {
        stringResource(Res.string.episodes_specials)
    } else {
        stringResource(Res.string.episodes_season, season)
    }

private fun isEpisodeWatchedForActions(
    meta: MetaDetails,
    episode: MetaVideo,
    watchedKeys: Set<String>,
    progressByVideoId: Map<String, WatchProgressEntry>,
): Boolean {
    val episodeVideoId = buildPlaybackVideoId(
        parentMetaId = meta.id,
        seasonNumber = episode.season,
        episodeNumber = episode.episode,
        fallbackVideoId = episode.id,
    )
    return progressByVideoId[episodeVideoId]?.isEffectivelyCompleted == true ||
        WatchingState.isEpisodeWatched(
            watchedKeys = watchedKeys,
            metaType = meta.type,
            metaId = meta.id,
            episode = episode,
        )
}

private fun areEpisodesWatchedForActions(
    meta: MetaDetails,
    episodes: Collection<MetaVideo>,
    watchedKeys: Set<String>,
    progressByVideoId: Map<String, WatchProgressEntry>,
): Boolean = episodes.isNotEmpty() && episodes.all { episode ->
    isEpisodeWatchedForActions(
        meta = meta,
        episode = episode,
        watchedKeys = watchedKeys,
        progressByVideoId = progressByVideoId,
    )
}

private fun extractImdbId(value: String?): String? =
    value
        ?.trim()
        ?.split(':', '/', '?', '&')
        ?.firstOrNull { part -> part.startsWith("tt", ignoreCase = true) }
        ?.takeIf { it.length > 2 }

private fun extractTmdbId(value: String?): Int? {
    val trimmed = value?.trim().orEmpty()
    if (trimmed.isBlank()) return null
    return trimmed
        .takeIf { it.startsWith("tmdb:", ignoreCase = true) }
        ?.substringAfter(':')
        ?.substringBefore(':')
        ?.substringBefore('/')
        ?.toIntOrNull()
}

private fun MetaDetails.toMetaPreview(): MetaPreview =
    MetaPreview(
        id = id,
        type = type,
        name = name,
        poster = poster,
        banner = background,
        logo = logo,
        description = description,
        releaseInfo = releaseInfo,
        imdbRating = imdbRating,
        genres = genres,
    )

private fun LazyListScope.configuredMetaSectionItems(
    settings: MetaScreenSettingsUiState,
    meta: MetaDetails,
    isTablet: Boolean,
    contentHorizontalPadding: Dp,
    contentMaxWidth: Dp,
    playButtonLabel: String,
    isSaved: Boolean,
    isWatched: Boolean,
    onPrimaryPlayClick: () -> Unit,
    onPrimaryPlayLongClick: (() -> Unit)?,
    onSaveClick: () -> Unit,
    onSaveLongClick: (() -> Unit)?,
    onWatchedClick: () -> Unit,
    showManualPlayOption: Boolean,
    preferredEpisodeSeasonNumber: Int?,
    preferredEpisodeNumber: Int?,
    hasProductionSection: Boolean,
    hasTrailersSection: Boolean,
    hasEpisodes: Boolean,
    hasAdditionalInfoSection: Boolean,
    hasCollectionSection: Boolean,
    hasMoreLikeThisSection: Boolean,
    shouldShowComments: Boolean,
    comments: List<TraktCommentReview>,
    isCommentsLoading: Boolean,
    isCommentsLoadingMore: Boolean,
    commentsCurrentPage: Int,
    commentsPageCount: Int,
    commentsError: String?,
    episodeImdbRatings: Map<Pair<Int, Int>, Double>,
    episodeListGroupedEpisodes: Map<Int, List<MetaVideo>>,
    episodeListSeasons: List<Int>,
    episodeListCurrentSeason: Int?,
    onEpisodeListSeasonSelect: (Int) -> Unit,
    onRetryComments: () -> Unit,
    onLoadMoreComments: () -> Unit,
    onCommentClick: (TraktCommentReview) -> Unit,
    onTrailerClick: (MetaTrailer) -> Unit,
    progressByVideoId: Map<String, WatchProgressEntry>,
    watchedKeys: Set<String>,
    blurUnwatchedEpisodes: Boolean,
    onEpisodeClick: (MetaVideo) -> Unit,
    onEpisodeLongPress: (MetaVideo) -> Unit,
    onSeasonLongPress: (Int) -> Unit,
    onOpenMeta: ((MetaPreview) -> Unit)?,
    onCastClick: ((MetaPerson, String?) -> Unit)?,
    onCompanyClick: ((MetaCompany, String) -> Unit)?,
    sharedTransitionScope: SharedTransitionScope?,
    animatedVisibilityScope: AnimatedVisibilityScope?,
) {
    val enabledItems = settings.items.filter { it.enabled }
    fun sectionHasContent(key: MetaScreenSectionKey): Boolean =
        metaSectionHasContent(
            key = key,
            meta = meta,
            hasProductionSection = hasProductionSection,
            hasTrailersSection = hasTrailersSection,
            hasEpisodes = hasEpisodes,
            hasAdditionalInfoSection = hasAdditionalInfoSection,
            hasCollectionSection = hasCollectionSection,
            hasMoreLikeThisSection = hasMoreLikeThisSection,
            shouldShowComments = shouldShowComments,
            comments = comments,
            isCommentsLoading = isCommentsLoading,
            commentsError = commentsError,
        )

    fun addSectionItem(
        key: String,
        sectionItems: List<MetaScreenSectionItem>,
        forceTabLayout: Boolean = settings.tabLayout,
    ) {
        item(key = key) {
            DetailSectionContainer(
                horizontalPadding = contentHorizontalPadding,
                contentMaxWidth = contentMaxWidth,
            ) {
                ConfiguredMetaSections(
                    settings = settings.copy(
                        items = sectionItems,
                        tabLayout = forceTabLayout,
                    ),
                    meta = meta,
                    isTablet = isTablet,
                    horizontalScrollPadding = contentHorizontalPadding,
                    playButtonLabel = playButtonLabel,
                    isSaved = isSaved,
                    isWatched = isWatched,
                    onPrimaryPlayClick = onPrimaryPlayClick,
                    onPrimaryPlayLongClick = onPrimaryPlayLongClick,
                    onSaveClick = onSaveClick,
                    onSaveLongClick = onSaveLongClick,
                    onWatchedClick = onWatchedClick,
                    showManualPlayOption = showManualPlayOption,
                    preferredEpisodeSeasonNumber = preferredEpisodeSeasonNumber,
                    preferredEpisodeNumber = preferredEpisodeNumber,
                    hasProductionSection = hasProductionSection,
                    hasTrailersSection = hasTrailersSection,
                    hasEpisodes = hasEpisodes,
                    hasAdditionalInfoSection = hasAdditionalInfoSection,
                    hasCollectionSection = hasCollectionSection,
                    hasMoreLikeThisSection = hasMoreLikeThisSection,
                    shouldShowComments = shouldShowComments,
                    comments = comments,
                    isCommentsLoading = isCommentsLoading,
                    isCommentsLoadingMore = isCommentsLoadingMore,
                    commentsCurrentPage = commentsCurrentPage,
                    commentsPageCount = commentsPageCount,
                    commentsError = commentsError,
                    episodeImdbRatings = episodeImdbRatings,
                    onRetryComments = onRetryComments,
                    onLoadMoreComments = onLoadMoreComments,
                    onCommentClick = onCommentClick,
                    onTrailerClick = onTrailerClick,
                    progressByVideoId = progressByVideoId,
                    watchedKeys = watchedKeys,
                    blurUnwatchedEpisodes = blurUnwatchedEpisodes,
                    onEpisodeClick = onEpisodeClick,
                    onEpisodeLongPress = onEpisodeLongPress,
                    onSeasonLongPress = onSeasonLongPress,
                    onOpenMeta = onOpenMeta,
                    onCastClick = onCastClick,
                    onCompanyClick = onCompanyClick,
                    sharedTransitionScope = sharedTransitionScope,
                    animatedVisibilityScope = animatedVisibilityScope,
                )
            }
        }
    }

    fun addLazyEpisodeListItems(key: String) {
        val currentSeason = episodeListCurrentSeason ?: return
        val episodes = episodeListGroupedEpisodes[currentSeason].orEmpty()
        if (episodes.isEmpty()) return

        item(
            key = "$key-header",
            contentType = "detail-episode-header",
        ) {
            DetailSectionContainer(
                horizontalPadding = contentHorizontalPadding,
                contentMaxWidth = contentMaxWidth,
                bottomPadding = 12.dp,
            ) {
                DetailSeriesListHeader(
                    meta = meta,
                    groupedEpisodes = episodeListGroupedEpisodes,
                    seasons = episodeListSeasons,
                    currentSeason = currentSeason,
                    horizontalScrollPadding = contentHorizontalPadding,
                    onSeasonSelect = onEpisodeListSeasonSelect,
                    onSeasonLongPress = onSeasonLongPress,
                )
            }
        }
        itemsIndexed(
            items = episodes,
            key = { index, episode ->
                "$key-episode-$currentSeason-${episode.episode}-${episode.id}-$index"
            },
            contentType = { _, _ -> "detail-episode" },
        ) { index, episode ->
            DetailSectionContainer(
                horizontalPadding = contentHorizontalPadding,
                contentMaxWidth = contentMaxWidth,
                bottomPadding = if (index == episodes.lastIndex) 20.dp else 12.dp,
            ) {
                DetailSeriesListEpisode(
                    meta = meta,
                    episode = episode,
                    progressByVideoId = progressByVideoId,
                    watchedKeys = watchedKeys,
                    episodeRatings = episodeImdbRatings,
                    blurUnwatchedEpisodes = blurUnwatchedEpisodes,
                    onEpisodeClick = onEpisodeClick,
                    onEpisodeLongPress = onEpisodeLongPress,
                )
            }
        }
    }

    fun addStandaloneSection(
        section: MetaScreenSectionItem,
        key: String,
        forceTabLayout: Boolean = false,
    ) {
        if (section.key == MetaScreenSectionKey.EPISODES && settings.episodeCardStyle == MetaEpisodeCardStyle.List) {
            addLazyEpisodeListItems(key)
        } else {
            addSectionItem(
                key = key,
                sectionItems = listOf(section),
                forceTabLayout = forceTabLayout,
            )
        }
    }

    if (!settings.tabLayout) {
        enabledItems
            .filter { sectionHasContent(it.key) }
            .forEach { section ->
                addStandaloneSection(
                    section = section,
                    key = "detail-section-${section.key.name}",
                )
            }
        return
    }

    val processedGroups = mutableSetOf<Int>()
    enabledItems.forEach { section ->
        val groupId = section.tabGroupForRendering(settings.episodeCardStyle)
        if (groupId == null) {
            if (sectionHasContent(section.key)) {
                addStandaloneSection(
                    section = section,
                    key = "detail-section-${section.key.name}",
                    forceTabLayout = true,
                )
            }
        } else if (groupId !in processedGroups) {
            processedGroups.add(groupId)
            val groupMembers = enabledItems.filter { item ->
                item.tabGroupForRendering(settings.episodeCardStyle) == groupId && sectionHasContent(item.key)
            }
            if (groupMembers.isNotEmpty()) {
                if (groupMembers.size == 1) {
                    addStandaloneSection(
                        section = groupMembers.single(),
                        key = "detail-section-group-$groupId",
                    )
                } else {
                    addSectionItem(
                        key = "detail-section-group-$groupId",
                        sectionItems = groupMembers,
                        forceTabLayout = true,
                    )
                }
            }
        }
    }
}

@Composable
private fun DetailSectionContainer(
    horizontalPadding: Dp,
    contentMaxWidth: Dp,
    bottomPadding: Dp = 20.dp,
    content: @Composable () -> Unit,
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = horizontalPadding)
            .padding(bottom = bottomPadding),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .then(
                    if (contentMaxWidth == Dp.Unspecified) {
                        Modifier
                    } else {
                        Modifier.widthIn(max = contentMaxWidth)
                    },
                ),
            contentAlignment = Alignment.Center,
        ) {
            content()
        }
    }
}

private fun metaSectionHasContent(
    key: MetaScreenSectionKey,
    meta: MetaDetails,
    hasProductionSection: Boolean,
    hasTrailersSection: Boolean,
    hasEpisodes: Boolean,
    hasAdditionalInfoSection: Boolean,
    hasCollectionSection: Boolean,
    hasMoreLikeThisSection: Boolean,
    shouldShowComments: Boolean,
    comments: List<TraktCommentReview>,
    isCommentsLoading: Boolean,
    commentsError: String?,
): Boolean =
    when (key) {
        MetaScreenSectionKey.ACTIONS -> true
        MetaScreenSectionKey.OVERVIEW -> true
        MetaScreenSectionKey.PRODUCTION -> hasProductionSection
        MetaScreenSectionKey.CAST -> meta.cast.isNotEmpty()
        MetaScreenSectionKey.COMMENTS -> shouldShowComments && (isCommentsLoading || comments.isNotEmpty() || !commentsError.isNullOrBlank())
        MetaScreenSectionKey.TRAILERS -> hasTrailersSection
        MetaScreenSectionKey.EPISODES -> hasEpisodes
        MetaScreenSectionKey.DETAILS -> hasAdditionalInfoSection
        MetaScreenSectionKey.COLLECTION -> !hasEpisodes && hasCollectionSection
        MetaScreenSectionKey.MORE_LIKE_THIS -> hasMoreLikeThisSection
    }

@Composable
@OptIn(ExperimentalSharedTransitionApi::class)
private fun ConfiguredMetaSections(
    settings: MetaScreenSettingsUiState,
    meta: MetaDetails,
    isTablet: Boolean,
    horizontalScrollPadding: Dp,
    playButtonLabel: String,
    isSaved: Boolean,
    isWatched: Boolean,
    onPrimaryPlayClick: () -> Unit,
    onPrimaryPlayLongClick: (() -> Unit)?,
    onSaveClick: () -> Unit,
    onSaveLongClick: (() -> Unit)?,
    onWatchedClick: () -> Unit,
    showManualPlayOption: Boolean,
    preferredEpisodeSeasonNumber: Int?,
    preferredEpisodeNumber: Int?,
    hasProductionSection: Boolean,
    hasTrailersSection: Boolean,
    hasEpisodes: Boolean,
    hasAdditionalInfoSection: Boolean,
    hasCollectionSection: Boolean,
    hasMoreLikeThisSection: Boolean,
    shouldShowComments: Boolean,
    comments: List<TraktCommentReview>,
    isCommentsLoading: Boolean,
    isCommentsLoadingMore: Boolean,
    commentsCurrentPage: Int,
    commentsPageCount: Int,
    commentsError: String?,
    episodeImdbRatings: Map<Pair<Int, Int>, Double>,
    onRetryComments: () -> Unit,
    onLoadMoreComments: () -> Unit,
    onCommentClick: (TraktCommentReview) -> Unit,
    onTrailerClick: (MetaTrailer) -> Unit,
    progressByVideoId: Map<String, WatchProgressEntry>,
    watchedKeys: Set<String>,
    blurUnwatchedEpisodes: Boolean,
    onEpisodeClick: (MetaVideo) -> Unit,
    onEpisodeLongPress: (MetaVideo) -> Unit,
    onSeasonLongPress: (Int) -> Unit,
    onOpenMeta: ((MetaPreview) -> Unit)?,
    onCastClick: ((MetaPerson, String?) -> Unit)?,
    onCompanyClick: ((MetaCompany, String) -> Unit)?,
    sharedTransitionScope: SharedTransitionScope?,
    animatedVisibilityScope: AnimatedVisibilityScope?,
) {
    val enabledItems = settings.items.filter { it.enabled }

    // Helper to check if a section actually has content to show
    val sectionHasContent: (MetaScreenSectionKey) -> Boolean = { key ->
        when (key) {
            MetaScreenSectionKey.ACTIONS -> true
            MetaScreenSectionKey.OVERVIEW -> true
            MetaScreenSectionKey.PRODUCTION -> hasProductionSection
            MetaScreenSectionKey.CAST -> meta.cast.isNotEmpty()
            MetaScreenSectionKey.COMMENTS -> shouldShowComments && (isCommentsLoading || comments.isNotEmpty() || !commentsError.isNullOrBlank())
            MetaScreenSectionKey.TRAILERS -> hasTrailersSection
            MetaScreenSectionKey.EPISODES -> hasEpisodes
            MetaScreenSectionKey.DETAILS -> hasAdditionalInfoSection
            MetaScreenSectionKey.COLLECTION -> !hasEpisodes && hasCollectionSection
            MetaScreenSectionKey.MORE_LIKE_THIS -> hasMoreLikeThisSection
        }
    }

    @Composable
    fun RenderSection(key: MetaScreenSectionKey, showHeader: Boolean = true) {
        when (key) {
            MetaScreenSectionKey.ACTIONS -> {
                DetailActionButtons(
                    playLabel = playButtonLabel,
                    secondaryActions = buildList {
                        add(DetailSecondaryAction(
                            label = if (isWatched) {
                                stringResource(Res.string.hero_mark_unwatched)
                            } else {
                                stringResource(Res.string.hero_mark_watched)
                            },
                            icon = if (isWatched) {
                                Icons.Default.CheckCircle
                            } else {
                                Icons.Default.CheckCircleOutline
                            },
                            isActive = isWatched,
                            onClick = onWatchedClick,
                        ))
                        add(DetailSecondaryAction(
                            label = if (isSaved) {
                                stringResource(Res.string.hero_remove_from_library)
                            } else {
                                stringResource(Res.string.hero_add_to_library)
                            },
                            icon = if (isSaved) {
                                Icons.Default.Check
                            } else {
                                Icons.Default.Add
                            },
                            isActive = isSaved,
                            onClick = onSaveClick,
                            onLongClick = onSaveLongClick,
                        ))
                    },
                    isTablet = isTablet,
                    onPlayClick = onPrimaryPlayClick,
                    onPlayLongClick = if (showManualPlayOption) onPrimaryPlayLongClick else null,
                )
            }
            MetaScreenSectionKey.OVERVIEW -> {
                DetailMetaInfo(
                    meta = meta,
                    horizontalScrollPadding = horizontalScrollPadding,
                )
            }
            MetaScreenSectionKey.PRODUCTION -> {
                if (hasProductionSection) {
                    DetailProductionSection(meta = meta, showHeader = showHeader, onCompanyClick = onCompanyClick)
                }
            }
            MetaScreenSectionKey.CAST -> {
                DetailCastSection(
                    cast = meta.cast,
                    showHeader = showHeader,
                    horizontalScrollPadding = horizontalScrollPadding,
                    onCastClick = onCastClick,
                    sharedTransitionScope = sharedTransitionScope,
                    animatedVisibilityScope = animatedVisibilityScope,
                )
            }
            MetaScreenSectionKey.COMMENTS -> {
                if (shouldShowComments && (isCommentsLoading || comments.isNotEmpty() || !commentsError.isNullOrBlank())) {
                    DetailCommentsSection(
                        comments = comments,
                        isLoading = isCommentsLoading,
                        isLoadingMore = isCommentsLoadingMore,
                        canLoadMore = commentsCurrentPage < commentsPageCount,
                        error = commentsError,
                        onRetry = onRetryComments,
                        onLoadMore = onLoadMoreComments,
                        onCommentClick = onCommentClick,
                        showHeader = showHeader,
                        horizontalScrollPadding = horizontalScrollPadding,
                    )
                }
            }
            MetaScreenSectionKey.TRAILERS -> {
                if (hasTrailersSection) {
                    DetailTrailersSection(
                        trailers = meta.trailers,
                        onTrailerClick = onTrailerClick,
                        showHeader = showHeader,
                        horizontalScrollPadding = horizontalScrollPadding,
                    )
                }
            }
            MetaScreenSectionKey.EPISODES -> {
                if (hasEpisodes) {
                    DetailSeriesContent(
                        meta = meta,
                        showHeader = showHeader,
                        horizontalScrollPadding = horizontalScrollPadding,
                        preferredSeasonNumber = preferredEpisodeSeasonNumber,
                        preferredEpisodeNumber = preferredEpisodeNumber,
                        episodeCardStyle = settings.episodeCardStyle,
                        progressByVideoId = progressByVideoId,
                        watchedKeys = watchedKeys,
                        episodeRatings = episodeImdbRatings,
                        blurUnwatchedEpisodes = blurUnwatchedEpisodes,
                        onEpisodeClick = onEpisodeClick,
                        onEpisodeLongPress = onEpisodeLongPress,
                        onSeasonLongPress = onSeasonLongPress,
                    )
                }
            }
            MetaScreenSectionKey.DETAILS -> {
                if (hasAdditionalInfoSection) {
                    DetailAdditionalInfoSection(meta = meta, showHeader = showHeader)
                }
            }
            MetaScreenSectionKey.COLLECTION -> {
                if (!hasEpisodes && hasCollectionSection) {
                    DetailPosterRailSection(
                        title = meta.collectionName.orEmpty(),
                        items = meta.collectionItems,
                        watchedKeys = watchedKeys,
                        showHeader = showHeader,
                        horizontalScrollPadding = horizontalScrollPadding,
                        onPosterClick = onOpenMeta,
                    )
                }
            }
            MetaScreenSectionKey.MORE_LIKE_THIS -> {
                if (hasMoreLikeThisSection) {
                    val sourceLabel = when (meta.moreLikeThisSource) {
                        MoreLikeThisSource.TMDB -> stringResource(Res.string.detail_more_like_this_powered_by_tmdb)
                        MoreLikeThisSource.TRAKT -> stringResource(Res.string.detail_more_like_this_powered_by_trakt)
                        null -> null
                    }
                    DetailPosterRailSection(
                        title = stringResource(Res.string.details_more_like_this),
                        items = meta.moreLikeThis,
                        watchedKeys = watchedKeys,
                        showHeader = showHeader,
                        horizontalScrollPadding = horizontalScrollPadding,
                        sourceLabel = sourceLabel,
                        onPosterClick = onOpenMeta,
                    )
                }
            }
        }
    }

    if (!settings.tabLayout) {
        // Standard mode: render sections individually in order
        enabledItems.forEach { section -> RenderSection(section.key) }
    } else {
        // Tab layout mode: group sections by tabGroup, render grouped ones as tabs
        val processedGroups = mutableSetOf<Int>()

        enabledItems.forEach { section ->
            val groupId = section.tabGroup
            if (groupId == null) {
                // Standalone section
                RenderSection(section.key)
            } else if (groupId !in processedGroups) {
                // First encounter of this group - render the whole tabbed group
                processedGroups.add(groupId)
                val groupMembers = enabledItems
                    .filter { it.tabGroup == groupId && sectionHasContent(it.key) }
                if (groupMembers.isEmpty()) return@forEach
                if (groupMembers.size == 1) {
                    // Only one member with content - render standalone
                    RenderSection(groupMembers.first().key)
                } else {
                    TabbedSectionGroup(
                        tabs = groupMembers.map { it.key to it.title },
                    ) { activeKey ->
                        RenderSection(activeKey, showHeader = false)
                    }
                }
            }
            // else: already processed as part of group, skip
        }
    }
}

@Composable
private fun TabbedSectionGroup(
    tabs: List<Pair<MetaScreenSectionKey, String>>,
    content: @Composable (MetaScreenSectionKey) -> Unit,
) {
    if (tabs.isEmpty()) return

    var selectedIndex by remember { mutableIntStateOf(0) }
    val clampedIndex = selectedIndex.coerceIn(0, tabs.lastIndex)
    if (clampedIndex != selectedIndex) selectedIndex = clampedIndex

    val headerColor = MaterialTheme.colorScheme.onBackground

    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        // Tab row using the same style as DetailSectionTitle
        BoxWithConstraints(modifier = Modifier.fillMaxWidth()) {
            val titleSize = if (maxWidth >= 720.dp) 22.sp else 20.sp
            val headerStyle = MaterialTheme.typography.titleLarge.copy(
                fontSize = titleSize,
                fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold,
            )

            Row(verticalAlignment = Alignment.CenterVertically) {
                tabs.forEachIndexed { index, (_, title) ->
                    if (index > 0) {
                        Text(
                            text = "|",
                            style = headerStyle,
                            color = headerColor.copy(alpha = 0.45f),
                            modifier = Modifier.padding(horizontal = 10.dp),
                        )
                    }

                    Text(
                        text = title,
                        style = headerStyle,
                        color = if (index == selectedIndex) {
                            headerColor
                        } else {
                            headerColor.copy(alpha = 0.55f)
                        },
                        maxLines = 1,
                        modifier = Modifier
                            .clickable(
                                interactionSource = remember { MutableInteractionSource() },
                                indication = null,
                            ) { selectedIndex = index },
                    )
                }
            }
        }

        // Content with crossfade
        Crossfade(
            targetState = tabs[selectedIndex].first,
            animationSpec = tween(durationMillis = 200),
            label = "tabbedSectionCrossfade",
        ) { activeKey ->
            content(activeKey)
        }
    }
}

private fun detailTabletContentMaxWidth(maxWidth: Dp, isTablet: Boolean): Dp =
    if (!isTablet) {
        maxWidth
    } else {
        (maxWidth * 0.6f).coerceIn(520.dp, 680.dp)
    }

private fun dominantBackdropBlendColor(dominantColor: Color, backgroundColor: Color): Color =
    backgroundColor.blendTowards(dominantColor, fraction = 0.42f)

private fun Color.blendTowards(target: Color, fraction: Float): Color {
    val clamped = fraction.coerceIn(0f, 1f)
    return Color(
        red = red + (target.red - red) * clamped,
        green = green + (target.green - green) * clamped,
        blue = blue + (target.blue - blue) * clamped,
        alpha = alpha + (target.alpha - alpha) * clamped,
    )
}

'@

Write-RepoFile "composeApp\src\commonMain\kotlin\com\nuvio\app\features\search\SearchScreen.kt" @'
package com.nuvio.app.features.search

import androidx.compose.foundation.clickable
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.nuvio.app.core.network.NetworkCondition
import com.nuvio.app.core.network.NetworkStatusRepository
import com.nuvio.app.core.ui.NuvioInputField
import com.nuvio.app.core.ui.NuvioScreen
import com.nuvio.app.core.ui.NuvioNetworkOfflineCard
import com.nuvio.app.core.ui.NuvioScreenHeader
import com.nuvio.app.core.ui.nuvioConsumePointerEvents
import com.nuvio.app.core.ui.rememberPosterCardStyleUiState
import com.nuvio.app.core.ui.withDuplicateSafeLazyKeys
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.addons.firstEnabledManifestError
import com.nuvio.app.features.addons.hasPendingEnabledManifests
import com.nuvio.app.features.home.HomeCatalogSettingsRepository
import com.nuvio.app.features.home.MetaPreview
import com.nuvio.app.features.home.buildAddonCatalogRefreshSignature
import com.nuvio.app.features.home.components.HomeCatalogRowSection
import com.nuvio.app.features.home.components.HomeEmptyStateCard
import com.nuvio.app.features.home.components.homeSectionHorizontalPaddingForWidth
import com.nuvio.app.features.home.components.HomeSkeletonRow
import com.nuvio.app.core.ui.AppPresenceState
import com.nuvio.app.core.ui.posterGridColumnCountForCatalogWidth
import com.nuvio.app.features.home.components.posterGridColumnCountForWidth
import com.nuvio.app.isDesktop
import com.nuvio.app.features.watched.WatchedRepository
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.map
import nuvio.composeapp.generated.resources.Res
import nuvio.composeapp.generated.resources.action_retry
import nuvio.composeapp.generated.resources.compose_nav_search
import nuvio.composeapp.generated.resources.compose_search_clear
import nuvio.composeapp.generated.resources.compose_search_discover_title
import nuvio.composeapp.generated.resources.compose_search_empty_failed_message
import nuvio.composeapp.generated.resources.compose_search_empty_failed_title
import nuvio.composeapp.generated.resources.compose_search_empty_no_active_addons_message
import nuvio.composeapp.generated.resources.compose_search_empty_no_active_addons_title
import nuvio.composeapp.generated.resources.compose_search_empty_no_results_message
import nuvio.composeapp.generated.resources.compose_search_empty_no_results_title
import nuvio.composeapp.generated.resources.compose_search_empty_no_search_catalogs_message
import nuvio.composeapp.generated.resources.compose_search_empty_no_search_catalogs_title
import nuvio.composeapp.generated.resources.compose_search_placeholder
import nuvio.composeapp.generated.resources.compose_search_recent_searches
import nuvio.composeapp.generated.resources.compose_search_remove_recent_search
import org.jetbrains.compose.resources.stringResource

@Composable
fun SearchScreen(
    modifier: Modifier = Modifier,
    topChromePadding: Dp? = null,
    listState: LazyListState = rememberLazyListState(),
    onPosterClick: ((MetaPreview) -> Unit)? = null,
    onPosterLongClick: ((MetaPreview) -> Unit)? = null,
    searchFocusRequestCount: Int = 0,
    scrollToTopRequests: Flow<Unit> = emptyFlow(),
) {
    val focusRequester = remember { FocusRequester() }

    LaunchedEffect(searchFocusRequestCount) {
        if (searchFocusRequestCount > 0) {
            focusRequester.requestFocus()
        }
    }

    LaunchedEffect(Unit) {
        AddonRepository.initialize()
        WatchedRepository.ensureLoaded()
        SearchHistoryRepository.ensureLoaded()
    }

    val addonsUiState by AddonRepository.uiState.collectAsStateWithLifecycle()
    val uiState by SearchRepository.uiState.collectAsStateWithLifecycle()
    val discoverUiState by SearchRepository.discoverUiState.collectAsStateWithLifecycle()
    val homeCatalogSettingsUiState by remember {
        HomeCatalogSettingsRepository.snapshot()
        HomeCatalogSettingsRepository.uiState
    }.collectAsStateWithLifecycle()
    val recentSearches by SearchHistoryRepository.uiState.collectAsStateWithLifecycle()
    val watchedUiState by WatchedRepository.uiState.collectAsStateWithLifecycle()
    val fullyWatchedSeriesKeys by WatchedRepository.fullyWatchedSeriesKeys.collectAsStateWithLifecycle()
    val networkStatusUiState by NetworkStatusRepository.uiState.collectAsStateWithLifecycle()
    var query by rememberSaveable { mutableStateOf("") }
    var lastRequestedQuery by rememberSaveable { mutableStateOf<String?>(null) }

    // Let the app shell put the active search term into the Discord presence.
    LaunchedEffect(query) {
        AppPresenceState.publishSearchQuery(query.trim())
    }
    var observedOfflineState by remember { mutableStateOf(false) }
    val discoverInFocus by remember(query, listState) {
        derivedStateOf {
            query.isBlank() && listState.firstVisibleItemIndex > 0
        }
    }

    LaunchedEffect(scrollToTopRequests) {
        scrollToTopRequests.collect {
            listState.animateScrollToItem(0)
        }
    }

    val addonRefreshKey = remember(addonsUiState.addons) {
        buildAddonCatalogRefreshSignature(addonsUiState.addons)
    }
    val addonManifestsLoading = addonsUiState.addons.hasPendingEnabledManifests()

    LaunchedEffect(addonRefreshKey, homeCatalogSettingsUiState.hideUnreleasedContent) {
        SearchRepository.refreshDiscover(addonsUiState.addons)
    }

    LaunchedEffect(query, addonRefreshKey, homeCatalogSettingsUiState.hideUnreleasedContent) {
        val normalizedQuery = query.trim()
        if (normalizedQuery.isBlank()) {
            lastRequestedQuery = null
            SearchRepository.clear()
        } else {
            delay(350)
            lastRequestedQuery = normalizedQuery
            SearchRepository.search(
                query = normalizedQuery,
                addons = addonsUiState.addons,
            )
        }
    }

    LaunchedEffect(listState, query, discoverUiState.canLoadMore, discoverUiState.isLoading) {
        if (query.isNotBlank()) return@LaunchedEffect

        snapshotFlow { listState.layoutInfo }
            .map { layoutInfo ->
                val lastVisible = layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: -1
                lastVisible >= layoutInfo.totalItemsCount - 4
            }
            .distinctUntilChanged()
            .filter { it && discoverUiState.canLoadMore && !discoverUiState.isLoading }
            .collect {
                SearchRepository.loadMoreDiscover()
            }
    }

    LaunchedEffect(query, lastRequestedQuery, uiState.isLoading, uiState.sections) {
        val normalizedQuery = query.trim()
        if (normalizedQuery.isBlank()) return@LaunchedEffect
        if (lastRequestedQuery != normalizedQuery) return@LaunchedEffect
        if (uiState.isLoading || uiState.sections.isEmpty()) return@LaunchedEffect
        SearchHistoryRepository.recordSearch(normalizedQuery)
    }

    LaunchedEffect(networkStatusUiState.condition, query, addonRefreshKey) {
        when (networkStatusUiState.condition) {
            NetworkCondition.NoInternet,
            NetworkCondition.ServersUnreachable,
            -> {
                observedOfflineState = true
            }

            NetworkCondition.Online -> {
                if (!observedOfflineState) return@LaunchedEffect
                observedOfflineState = false

                val normalizedQuery = query.trim()
                if (normalizedQuery.isBlank()) {
                    SearchRepository.refreshDiscover(
                        addons = addonsUiState.addons,
                        forceRefresh = true,
                    )
                } else {
                    SearchRepository.search(
                        query = normalizedQuery,
                        addons = addonsUiState.addons,
                        forceRefresh = true,
                    )
                }
            }

            NetworkCondition.Unknown,
            NetworkCondition.Checking,
            -> Unit
        }
    }

    BoxWithConstraints(
        modifier = modifier.fillMaxSize(),
    ) {
        val posterCardStyle = rememberPosterCardStyleUiState()
        val discoverColumns = remember(maxWidth, maxHeight, posterCardStyle.widthDp, isDesktop) {
            if (isDesktop) {
                posterGridColumnCountForCatalogWidth(
                    screenWidth = maxWidth,
                    basePosterWidthDp = posterCardStyle.widthDp,
                )
            } else {
                posterGridColumnCountForWidth(maxWidth)
            }
        }
        val homeSectionPadding = remember(maxWidth) {
            homeSectionHorizontalPaddingForWidth(maxWidth.value)
        }
        val headerTitle = when {
            query.isNotBlank() -> stringResource(Res.string.compose_nav_search)
            discoverInFocus -> stringResource(Res.string.compose_search_discover_title)
            else -> stringResource(Res.string.compose_nav_search)
        }

        NuvioScreen(
            horizontalPadding = 0.dp,
            topPadding = if (topChromePadding != null) 0.dp else null,
            listState = listState,
            modifier = Modifier.fillMaxSize(),
        ) {
        stickyHeader {
            Box(modifier = Modifier.fillMaxWidth()) {
                Box(
                    modifier = Modifier
                        .matchParentSize()
                        .background(MaterialTheme.colorScheme.background)
                        .nuvioConsumePointerEvents(),
                )
                androidx.compose.foundation.layout.Column(
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    NuvioScreenHeader(
                        title = headerTitle,
                        modifier = Modifier.padding(horizontal = 16.dp),
                        topPadding = topChromePadding,
                    )
                    androidx.compose.foundation.layout.Spacer(modifier = Modifier.height(6.dp))
                    androidx.compose.foundation.layout.Box(modifier = Modifier.padding(horizontal = 16.dp)) {
                        NuvioInputField(
                            value = query,
                            onValueChange = { query = it },
                            placeholder = stringResource(Res.string.compose_search_placeholder),
                            modifier = Modifier.focusRequester(focusRequester),
                            trailingContent = if (query.isNotBlank()) {
                                {
                                    IconButton(onClick = { query = "" }) {
                                        Icon(
                                            imageVector = Icons.Rounded.Close,
                                            contentDescription = stringResource(Res.string.compose_search_clear),
                                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                        )
                                    }
                                }
                            } else {
                                null
                            },
                        )
                    }
                    androidx.compose.foundation.layout.Spacer(modifier = Modifier.height(14.dp))
                }
            }
        }

        if (query.isBlank()) {
            if (recentSearches.isNotEmpty()) {
                item(key = "recent_searches") {
                    SearchRecentSection(
                        recentSearches = recentSearches,
                        onSearchPress = { recentQuery -> query = recentQuery },
                        onRemoveSearch = SearchHistoryRepository::removeSearch,
                    )
                }
            }
                discoverContent(
                    state = discoverUiState,
                    isSourceLoading = addonManifestsLoading,
                    columns = discoverColumns,
                    networkCondition = networkStatusUiState.condition,
                    onTypeSelected = SearchRepository::selectDiscoverType,
                    onCatalogSelected = SearchRepository::selectDiscoverCatalog,
                    onGenreSelected = SearchRepository::selectDiscoverGenre,
                    onRetry = {
                        NetworkStatusRepository.requestRefresh(force = true)
                        if (addonsUiState.addons.firstEnabledManifestError() != null) {
                            AddonRepository.refreshAll()
                        } else {
                            SearchRepository.refreshDiscover(
                                addons = addonsUiState.addons,
                                forceRefresh = true,
                            )
                        }
                    },
                    watchedKeys = watchedUiState.watchedKeys,
                    fullyWatchedSeriesKeys = fullyWatchedSeriesKeys,
                    onPosterClick = onPosterClick,
                    onPosterLongClick = onPosterLongClick,
                )
            } else {
                val normalizedQuery = query.trim()
                val isWaitingForSearch = normalizedQuery.isNotBlank() && lastRequestedQuery != normalizedQuery
                when {
                    isWaitingForSearch -> {
                        items(2) {
                            HomeSkeletonRow(
                                modifier = Modifier.padding(horizontal = homeSectionPadding),
                            )
                        }
                    }

                    (uiState.isLoading || addonManifestsLoading) && uiState.sections.isEmpty() -> {
                        items(2) {
                            HomeSkeletonRow(
                                modifier = Modifier.padding(horizontal = homeSectionPadding),
                            )
                        }
                    }

                    uiState.sections.isEmpty() -> {
                        item {
                            SearchEmptyStateCard(
                                reason = uiState.emptyStateReason,
                                errorMessage = uiState.errorMessage,
                                networkCondition = networkStatusUiState.condition,
                                onRetry = {
                                    if (normalizedQuery.isNotBlank()) {
                                        NetworkStatusRepository.requestRefresh(force = true)
                                        if (addonsUiState.addons.firstEnabledManifestError() != null) {
                                            AddonRepository.refreshAll()
                                        } else {
                                            SearchRepository.search(
                                                query = normalizedQuery,
                                                addons = addonsUiState.addons,
                                                forceRefresh = true,
                                            )
                                        }
                                    }
                                },
                                modifier = Modifier.padding(horizontal = homeSectionPadding),
                            )
                        }
                    }

                    else -> {
                        items(
                            items = uiState.sections.withDuplicateSafeLazyKeys { section -> section.key },
                            key = { section -> section.lazyKey },
                        ) { keyedSection ->
                            val section = keyedSection.value
                            HomeCatalogRowSection(
                                section = section,
                                modifier = Modifier.padding(bottom = 12.dp),
                                watchedKeys = watchedUiState.watchedKeys,
                                fullyWatchedSeriesKeys = fullyWatchedSeriesKeys,
                                onPosterClick = onPosterClick,
                                onPosterLongClick = onPosterLongClick,
                            )
                        }
                        if (uiState.isLoading) {
                            item(key = "search_loading_more") {
                                HomeSkeletonRow(
                                    modifier = Modifier.padding(horizontal = homeSectionPadding),
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SearchEmptyStateCard(
    reason: SearchEmptyStateReason?,
    errorMessage: String?,
    networkCondition: NetworkCondition,
    onRetry: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    if (
        reason == SearchEmptyStateReason.RequestFailed &&
        (networkCondition == NetworkCondition.NoInternet || networkCondition == NetworkCondition.ServersUnreachable)
    ) {
        NuvioNetworkOfflineCard(
            condition = networkCondition,
            modifier = modifier,
            onRetry = onRetry,
        )
        return
    }

    val title: String
    val message: String

    when (reason) {
        SearchEmptyStateReason.NoActiveAddons -> {
            title = stringResource(Res.string.compose_search_empty_no_active_addons_title)
            message = stringResource(Res.string.compose_search_empty_no_active_addons_message)
        }

        SearchEmptyStateReason.NoSearchCatalogs -> {
            title = stringResource(Res.string.compose_search_empty_no_search_catalogs_title)
            message = stringResource(Res.string.compose_search_empty_no_search_catalogs_message)
        }

        SearchEmptyStateReason.RequestFailed -> {
            title = stringResource(Res.string.compose_search_empty_failed_title)
            message = errorMessage ?: stringResource(Res.string.compose_search_empty_failed_message)
        }

        SearchEmptyStateReason.NoResults, null -> {
            title = stringResource(Res.string.compose_search_empty_no_results_title)
            message = stringResource(Res.string.compose_search_empty_no_results_message)
        }
    }

    HomeEmptyStateCard(
        modifier = modifier,
        title = title,
        message = message,
        actionLabel = if (reason == SearchEmptyStateReason.RequestFailed) {
            stringResource(Res.string.action_retry)
        } else {
            null
        },
        onActionClick = if (reason == SearchEmptyStateReason.RequestFailed) onRetry else null,
    )
}

@Composable
private fun SearchRecentSection(
    recentSearches: List<String>,
    onSearchPress: (String) -> Unit,
    onRemoveSearch: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            text = stringResource(Res.string.compose_search_recent_searches),
            style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold),
            color = MaterialTheme.colorScheme.onBackground,
        )
        Spacer(modifier = Modifier.height(4.dp))
        recentSearches.forEach { recentQuery ->
            SearchRecentRow(
                query = recentQuery,
                onSearchPress = { onSearchPress(recentQuery) },
                onRemovePress = { onRemoveSearch(recentQuery) },
            )
        }
        Spacer(modifier = Modifier.height(6.dp))
    }
}

@Composable
private fun SearchRecentRow(
    query: String,
    onSearchPress: () -> Unit,
    onRemovePress: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clickable(onClick = onSearchPress)
            .padding(vertical = 2.dp)
            .background(
                color = MaterialTheme.colorScheme.background,
                shape = RoundedCornerShape(16.dp),
            )
            .padding(start = 2.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = query,
            modifier = Modifier.weight(1f),
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onBackground,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        IconButton(onClick = onRemovePress) {
            Icon(
                imageVector = Icons.Rounded.Close,
                contentDescription = stringResource(Res.string.compose_search_remove_recent_search),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

'@

Write-RepoFile "composeApp\src\commonMain\kotlin\com\nuvio\app\features\settings\AdvancedSettingsPage.kt" @'
package com.nuvio.app.features.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.material3.BasicAlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.nuvio.app.core.ui.NuvioTokens
import com.nuvio.app.core.ui.nuvio
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.features.watchprogress.ContinueWatchingEnrichmentCache
import com.nuvio.app.features.watchprogress.WatchProgressRepository
import kotlinx.coroutines.launch
import nuvio.composeapp.generated.resources.Res
import nuvio.composeapp.generated.resources.action_cancel
import nuvio.composeapp.generated.resources.settings_advanced_clear_cw_cache
import nuvio.composeapp.generated.resources.settings_advanced_clear_cw_cache_done
import nuvio.composeapp.generated.resources.settings_advanced_clear_cw_cache_subtitle
import nuvio.composeapp.generated.resources.settings_advanced_discord_browsing
import nuvio.composeapp.generated.resources.settings_advanced_discord_browsing_description
import nuvio.composeapp.generated.resources.settings_advanced_discord_buttons
import nuvio.composeapp.generated.resources.settings_advanced_discord_buttons_description
import nuvio.composeapp.generated.resources.settings_advanced_discord_hide_paused
import nuvio.composeapp.generated.resources.settings_advanced_discord_hide_paused_description
import nuvio.composeapp.generated.resources.settings_advanced_discord_rich_presence
import nuvio.composeapp.generated.resources.settings_advanced_discord_rich_presence_description
import nuvio.composeapp.generated.resources.settings_advanced_discord_swap_title
import nuvio.composeapp.generated.resources.settings_advanced_discord_swap_title_description
import nuvio.composeapp.generated.resources.settings_advanced_opengl_renderer
import nuvio.composeapp.generated.resources.settings_advanced_opengl_renderer_description
import nuvio.composeapp.generated.resources.settings_advanced_opengl_renderer_external_description
import nuvio.composeapp.generated.resources.settings_advanced_remember_last_profile
import nuvio.composeapp.generated.resources.settings_advanced_remember_last_profile_description
import nuvio.composeapp.generated.resources.settings_advanced_section_cache
import nuvio.composeapp.generated.resources.settings_advanced_section_diagnostics
import nuvio.composeapp.generated.resources.settings_advanced_section_discord
import nuvio.composeapp.generated.resources.settings_advanced_section_startup
import nuvio.composeapp.generated.resources.settings_advanced_section_windows_graphics
import nuvio.composeapp.generated.resources.settings_advanced_sentry_reports
import nuvio.composeapp.generated.resources.settings_advanced_sentry_reports_subtitle
import nuvio.composeapp.generated.resources.settings_advanced_sentry_reports_subtitle_desktop
import nuvio.composeapp.generated.resources.sentry_disable_dialog_subtitle
import nuvio.composeapp.generated.resources.sentry_disable_dialog_subtitle_desktop
import nuvio.composeapp.generated.resources.sentry_disable_dialog_title
import nuvio.composeapp.generated.resources.sentry_enable_dialog_subtitle
import nuvio.composeapp.generated.resources.sentry_enable_dialog_subtitle_desktop
import nuvio.composeapp.generated.resources.sentry_enable_dialog_title
import nuvio.composeapp.generated.resources.sentry_help_body
import nuvio.composeapp.generated.resources.sentry_help_body_desktop
import nuvio.composeapp.generated.resources.sentry_help_title
import nuvio.composeapp.generated.resources.sentry_keep_enabled
import nuvio.composeapp.generated.resources.sentry_not_sent_body
import nuvio.composeapp.generated.resources.sentry_not_sent_title
import nuvio.composeapp.generated.resources.sentry_sent_body
import nuvio.composeapp.generated.resources.sentry_sent_body_desktop
import nuvio.composeapp.generated.resources.sentry_sent_title
import nuvio.composeapp.generated.resources.sentry_turn_off
import nuvio.composeapp.generated.resources.sentry_turn_on
import org.jetbrains.compose.resources.stringResource

internal fun LazyListScope.advancedSettingsContent(
    isTablet: Boolean,
    rememberLastProfileEnabled: Boolean,
) {
    item {
        SettingsSection(
            title = stringResource(Res.string.settings_advanced_section_startup),
            isTablet = isTablet,
        ) {
            SettingsGroup(isTablet = isTablet) {
                SettingsSwitchRow(
                    title = stringResource(Res.string.settings_advanced_remember_last_profile),
                    description = stringResource(Res.string.settings_advanced_remember_last_profile_description),
                    checked = rememberLastProfileEnabled,
                    isTablet = isTablet,
                    onCheckedChange = ProfileRepository::setRememberLastProfileEnabled,
                )
            }
        }
    }
    if (DesktopRendererSettings.isSupported) {
        item {
            val externallyControlled = remember { DesktopRendererSettings.isExternallyControlled }
            var useOpenGl by remember { mutableStateOf(DesktopRendererSettings.useOpenGl) }

            SettingsSection(
                title = stringResource(Res.string.settings_advanced_section_windows_graphics),
                isTablet = isTablet,
            ) {
                SettingsGroup(isTablet = isTablet) {
                    SettingsSwitchRow(
                        title = stringResource(Res.string.settings_advanced_opengl_renderer),
                        description = stringResource(
                            if (externallyControlled) {
                                Res.string.settings_advanced_opengl_renderer_external_description
                            } else {
                                Res.string.settings_advanced_opengl_renderer_description
                            },
                        ),
                        checked = useOpenGl,
                        enabled = !externallyControlled,
                        isTablet = isTablet,
                        onCheckedChange = { enabled ->
                            DesktopRendererSettings.setUseOpenGl(enabled)
                            useOpenGl = enabled
                        },
                    )
                }
            }
        }
    }
    if (SentrySettingsRepository.isSupported) {
        item {
            val sentryEnabledFlow = remember {
                SentrySettingsRepository.ensureLoaded()
                SentrySettingsRepository.enabled
            }
            val sentryEnabled by sentryEnabledFlow.collectAsStateWithLifecycle()
            var showSentryDialog by rememberSaveable { mutableStateOf(false) }

            SettingsSection(
                title = stringResource(Res.string.settings_advanced_section_diagnostics),
                isTablet = isTablet,
            ) {
                SettingsGroup(isTablet = isTablet) {
                    SettingsSwitchRow(
                        title = stringResource(Res.string.settings_advanced_sentry_reports),
                        description = stringResource(
                            if (SentrySettingsPlatform.usesDesktopCopy) {
                                Res.string.settings_advanced_sentry_reports_subtitle_desktop
                            } else {
                                Res.string.settings_advanced_sentry_reports_subtitle
                            },
                        ),
                        checked = sentryEnabled,
                        isTablet = isTablet,
                        onCheckedChange = { showSentryDialog = true },
                    )
                }
            }

            if (showSentryDialog) {
                SentrySettingsDialog(
                    enabled = sentryEnabled,
                    onConfirm = {
                        SentrySettingsRepository.setEnabled(!sentryEnabled)
                    },
                    onDismiss = {
                        showSentryDialog = false
                    },
                )
            }
        }
    }
    if (DiscordRichPresenceRepository.isSupported) {
        item {
            val discordEnabledFlow = remember {
                DiscordRichPresenceRepository.ensureLoaded()
                DiscordRichPresenceRepository.enabled
            }
            val discordEnabled by discordEnabledFlow.collectAsStateWithLifecycle()

            SettingsSection(
                title = stringResource(Res.string.settings_advanced_section_discord),
                isTablet = isTablet,
            ) {
                SettingsGroup(isTablet = isTablet) {
                    SettingsSwitchRow(
                        title = stringResource(Res.string.settings_advanced_discord_rich_presence),
                        description = stringResource(Res.string.settings_advanced_discord_rich_presence_description),
                        checked = discordEnabled,
                        isTablet = isTablet,
                        onCheckedChange = DiscordRichPresenceRepository::setEnabled,
                    )
                    if (discordEnabled) {
                        val discordShowButtons by DiscordRichPresenceRepository.showButtons
                            .collectAsStateWithLifecycle()
                        val discordHideWhenPaused by DiscordRichPresenceRepository.hideWhenPaused
                            .collectAsStateWithLifecycle()
                        val discordShowBrowsing by DiscordRichPresenceRepository.showBrowsing
                            .collectAsStateWithLifecycle()
                        val discordSwapNameAndTitle by DiscordRichPresenceRepository.swapNameAndTitle
                            .collectAsStateWithLifecycle()

                        SettingsSwitchRow(
                            title = stringResource(Res.string.settings_advanced_discord_buttons),
                            description = stringResource(Res.string.settings_advanced_discord_buttons_description),
                            checked = discordShowButtons,
                            isTablet = isTablet,
                            onCheckedChange = DiscordRichPresenceRepository::setShowButtons,
                        )
                        SettingsSwitchRow(
                            title = stringResource(Res.string.settings_advanced_discord_browsing),
                            description = stringResource(Res.string.settings_advanced_discord_browsing_description),
                            checked = discordShowBrowsing,
                            isTablet = isTablet,
                            onCheckedChange = DiscordRichPresenceRepository::setShowBrowsing,
                        )
                        SettingsSwitchRow(
                            title = stringResource(Res.string.settings_advanced_discord_swap_title),
                            description = stringResource(Res.string.settings_advanced_discord_swap_title_description),
                            checked = discordSwapNameAndTitle,
                            isTablet = isTablet,
                            onCheckedChange = DiscordRichPresenceRepository::setSwapNameAndTitle,
                        )
                        SettingsSwitchRow(
                            title = stringResource(Res.string.settings_advanced_discord_hide_paused),
                            description = stringResource(Res.string.settings_advanced_discord_hide_paused_description),
                            checked = discordHideWhenPaused,
                            isTablet = isTablet,
                            onCheckedChange = DiscordRichPresenceRepository::setHideWhenPaused,
                        )
                    }
                }
            }
        }
    }
    item {
        SettingsSection(
            title = stringResource(Res.string.settings_advanced_section_cache),
            isTablet = isTablet,
        ) {
            SettingsGroup(isTablet = isTablet) {
                val scope = rememberCoroutineScope()
                var cleared by rememberSaveable { mutableStateOf(false) }
                SettingsNavigationRow(
                    title = stringResource(Res.string.settings_advanced_clear_cw_cache),
                    description = if (cleared) {
                        stringResource(Res.string.settings_advanced_clear_cw_cache_done)
                    } else {
                        stringResource(Res.string.settings_advanced_clear_cw_cache_subtitle)
                    },
                    isTablet = isTablet,
                    onClick = {
                        if (!cleared) {
                            ContinueWatchingEnrichmentCache.clearAll(ProfileRepository.activeProfileId)
                            cleared = true
                            scope.launch {
                                WatchProgressRepository.clearLocalAndForceSnapshotRefreshFromServer(
                                    ProfileRepository.activeProfileId,
                                )
                            }
                        }
                    },
                )
            }
        }
    }
}

@Composable
@OptIn(ExperimentalMaterial3Api::class)
private fun SentrySettingsDialog(
    enabled: Boolean,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    val tokens = MaterialTheme.nuvio
    BasicAlertDialog(
        onDismissRequest = onDismiss,
    ) {
        Surface(
            modifier = Modifier.fillMaxWidth(),
            color = tokens.colors.surfaceDialog,
            shape = tokens.shapes.dialog,
        ) {
            Column(
                modifier = Modifier.padding(tokens.spacing.dialogPadding),
            ) {
                Text(
                    text = stringResource(
                        if (enabled) {
                            Res.string.sentry_disable_dialog_title
                        } else {
                            Res.string.sentry_enable_dialog_title
                        },
                    ),
                    style = MaterialTheme.typography.titleLarge,
                    color = tokens.colors.textPrimary,
                )
                Spacer(modifier = Modifier.height(tokens.spacing.controlGap))
                Text(
                    text = stringResource(
                        when {
                            enabled && SentrySettingsPlatform.usesDesktopCopy -> {
                                Res.string.sentry_disable_dialog_subtitle_desktop
                            }
                            enabled -> Res.string.sentry_disable_dialog_subtitle
                            SentrySettingsPlatform.usesDesktopCopy -> {
                                Res.string.sentry_enable_dialog_subtitle_desktop
                            }
                            else -> Res.string.sentry_enable_dialog_subtitle
                        },
                    ),
                    style = MaterialTheme.typography.bodyLarge,
                    color = tokens.colors.textMuted,
                )
                Spacer(modifier = Modifier.height(NuvioTokens.Space.s18))
                Column(
                    verticalArrangement = Arrangement.spacedBy(NuvioTokens.Space.s12),
                ) {
                    SentryInfoSection(
                        title = stringResource(Res.string.sentry_help_title),
                        body = stringResource(
                            if (SentrySettingsPlatform.usesDesktopCopy) {
                                Res.string.sentry_help_body_desktop
                            } else {
                                Res.string.sentry_help_body
                            },
                        ),
                    )
                    SentryInfoSection(
                        title = stringResource(Res.string.sentry_sent_title),
                        body = stringResource(
                            if (SentrySettingsPlatform.usesDesktopCopy) {
                                Res.string.sentry_sent_body_desktop
                            } else {
                                Res.string.sentry_sent_body
                            },
                        ),
                    )
                    SentryInfoSection(
                        title = stringResource(Res.string.sentry_not_sent_title),
                        body = stringResource(Res.string.sentry_not_sent_body),
                    )
                }
                Spacer(modifier = Modifier.height(NuvioTokens.Space.s18))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.End,
                ) {
                    Button(
                        onClick = onDismiss,
                        shape = tokens.shapes.button,
                        colors = ButtonDefaults.buttonColors(
                            containerColor = tokens.colors.surfaceCard,
                            contentColor = tokens.colors.textPrimary,
                        ),
                    ) {
                        Text(
                            text = stringResource(
                                if (enabled) {
                                    Res.string.sentry_keep_enabled
                                } else {
                                    Res.string.action_cancel
                                },
                            ),
                        )
                    }
                    Spacer(modifier = Modifier.width(NuvioTokens.Space.s10))
                    Button(
                        onClick = {
                            onConfirm()
                            onDismiss()
                        },
                        shape = tokens.shapes.button,
                    ) {
                        Text(
                            text = stringResource(
                                if (enabled) {
                                    Res.string.sentry_turn_off
                                } else {
                                    Res.string.sentry_turn_on
                                },
                            ),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SentryInfoSection(
    title: String,
    body: String,
) {
    val tokens = MaterialTheme.nuvio
    Column(
        verticalArrangement = Arrangement.spacedBy(NuvioTokens.Space.s4),
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.titleSmall,
            color = tokens.colors.textPrimary,
            fontWeight = FontWeight.SemiBold,
        )
        Text(
            text = body,
            style = MaterialTheme.typography.bodyMedium,
            color = tokens.colors.textMuted,
        )
    }
}

'@

Write-RepoFile "composeApp\src\commonMain\kotlin\com\nuvio\app\features\settings\DiscordRichPresenceRepository.kt" @'
package com.nuvio.app.features.settings

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

internal object DiscordRichPresenceRepository {
    private const val showButtonsKey = "show_buttons"
    private const val hideWhenPausedKey = "hide_when_paused"
    private const val showBrowsingKey = "show_browsing"
    private const val swapNameAndTitleKey = "swap_name_and_title"

    val isSupported: Boolean
        get() = DiscordRichPresencePlatform.isSupported

    private val _enabled = MutableStateFlow(false)
    val enabled: StateFlow<Boolean> = _enabled.asStateFlow()

    /** Show the "View on IMDb" / "View on Kitsu" action button under the presence card. */
    private val _showButtons = MutableStateFlow(true)
    val showButtons: StateFlow<Boolean> = _showButtons.asStateFlow()

    /** Clear the presence entirely while playback is paused instead of showing a paused card. */
    private val _hideWhenPaused = MutableStateFlow(false)
    val hideWhenPaused: StateFlow<Boolean> = _hideWhenPaused.asStateFlow()

    /** Report browsing/details activity, not just active playback. */
    private val _showBrowsing = MutableStateFlow(true)
    val showBrowsing: StateFlow<Boolean> = _showBrowsing.asStateFlow()

    /** Swap the headline and the second line of the card. */
    private val _swapNameAndTitle = MutableStateFlow(false)
    val swapNameAndTitle: StateFlow<Boolean> = _swapNameAndTitle.asStateFlow()

    private var hasLoaded = false

    fun ensureLoaded() {
        if (hasLoaded) return
        hasLoaded = true
        _enabled.value = DiscordRichPresenceStorage.loadEnabled() ?: false
        _showButtons.value = DiscordRichPresenceStorage.loadFlag(showButtonsKey) ?: true
        _hideWhenPaused.value = DiscordRichPresenceStorage.loadFlag(hideWhenPausedKey) ?: false
        _showBrowsing.value = DiscordRichPresenceStorage.loadFlag(showBrowsingKey) ?: true
        _swapNameAndTitle.value = DiscordRichPresenceStorage.loadFlag(swapNameAndTitleKey) ?: false
    }

    fun setEnabled(enabled: Boolean) {
        ensureLoaded()
        if (_enabled.value == enabled) return
        _enabled.value = enabled
        DiscordRichPresenceStorage.saveEnabled(enabled)
    }

    fun setShowButtons(value: Boolean) = updateFlag(_showButtons, showButtonsKey, value)

    fun setHideWhenPaused(value: Boolean) = updateFlag(_hideWhenPaused, hideWhenPausedKey, value)

    fun setShowBrowsing(value: Boolean) = updateFlag(_showBrowsing, showBrowsingKey, value)

    fun setSwapNameAndTitle(value: Boolean) = updateFlag(_swapNameAndTitle, swapNameAndTitleKey, value)

    private fun updateFlag(flow: MutableStateFlow<Boolean>, key: String, value: Boolean) {
        ensureLoaded()
        if (flow.value == value) return
        flow.value = value
        DiscordRichPresenceStorage.saveFlag(key, value)
    }
}

'@

Write-RepoFile "composeApp\src\desktopMain\kotlin\com\nuvio\app\features\discordrpc\DiscordPresenceManager.kt" @'
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

'@


Write-Host ""
Set-Location $repo

Write-Host "Running: git add -A" -ForegroundColor Cyan
& git add -A

Write-Host "Running: git commit" -ForegroundColor Cyan
& git commit -m "discord: browsing presence with poster, no small badge, paused state, IMDb-only button"
if ($LASTEXITCODE -ne 0) {
    Write-Host "  (nothing new to commit - continuing anyway)" -ForegroundColor Yellow
}

Write-Host "Running: git push origin Dev" -ForegroundColor Cyan
& git push origin Dev
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "PUSH FAILED. Copy the red text above and send it to me." -ForegroundColor Red
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
Write-Host " (Use Run workflow - NOT 'Re-run jobs'.)" -ForegroundColor Yellow
Write-Host "=============================================" -ForegroundColor Green
