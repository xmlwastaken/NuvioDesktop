# =====================================================================
#  Nuvio Discord Rich Presence - rebased on upstream af480339
#
#  Upstream shipped their own Rich Presence and edited the same files we
#  do, which is why the old patch stopped applying. This switches to a
#  conflict-proof setup: the Rich Presence files live in their own drp/
#  folder, and the workflow lays them over a clean checkout of the
#  latest upstream every time it builds. No more merge conflicts.
#
#  Run this ONCE from PowerShell. It writes 8 files, commits and pushes
#  to the Dev branch.
#
#  1. Save this file to  C:\Users\XML\NuvioDesktop\apply-drp-v3.ps1
#  2. Open PowerShell and run:
#         cd C:\Users\XML\NuvioDesktop
#         powershell -ExecutionPolicy Bypass -File .\apply-drp-v3.ps1
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
    ) : PresenceSnapshot {
        override val presenceKey: String get() = "details:$title"
    }

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

        override val presenceKey: String
            get() = "player:${metaId ?: title}:$seasonNumber:$episodeNumber"
    }
}

'@

Write-RepoFile "drp\composeApp\src\commonMain\kotlin\com\nuvio\app\MainAppContent.kt" @'
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
        val detailTitle = (topRoute as? DetailRoute)?.title
        AppPresenceState.publish(
            if (!detailTitle.isNullOrBlank()) {
                // No poster yet; the details screen re-publishes this with artwork once loaded.
                PresenceSnapshot.Details(detailTitle)
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

Write-RepoFile "drp\composeApp\src\commonMain\kotlin\com\nuvio\app\features\details\MetaDetailsScreen.kt" @'
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
    // artwork at that point. Re-publish here once the meta, and therefore the poster, is known.
    LaunchedEffect(displayedMeta?.id, displayedMeta?.name, displayedMeta?.poster, displayedMeta?.releaseInfo) {
        val meta = displayedMeta ?: return@LaunchedEffect
        AppPresenceState.publish(
            PresenceSnapshot.Details(
                title = meta.name,
                posterUrl = meta.poster,
                year = meta.releaseInfo,
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
                // First encounter of this group — render the whole tabbed group
                processedGroups.add(groupId)
                val groupMembers = enabledItems
                    .filter { it.tabGroup == groupId && sectionHasContent(it.key) }
                if (groupMembers.isEmpty()) return@forEach
                if (groupMembers.size == 1) {
                    // Only one member with content — render standalone
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

Write-RepoFile "drp\composeApp\src\commonMain\kotlin\com\nuvio\app\features\search\SearchScreen.kt" @'
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
                                horizontalPadding = homeSectionPadding,
                            )
                        }
                    }

                    (uiState.isLoading || addonManifestsLoading) && uiState.sections.isEmpty() -> {
                        items(2) {
                            HomeSkeletonRow(
                                horizontalPadding = homeSectionPadding,
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
                                    horizontalPadding = homeSectionPadding,
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
 * "Watching Nuvio" instead of "Playing Nuvio", which is what a media player should report.
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

Write-RepoFile "drp\composeApp\src\desktopMain\kotlin\com\nuvio\app\features\discordrpc\DiscordPresenceManager.kt" @'
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
 * Fallback artwork for anything that has no poster of its own: the menu screens, and titles whose
 * addon never returned an image.
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

/** Identity of the context the elapsed timer is counting from, and the moment that started. */
private var presenceKey: String? = null
private var presenceSinceSec = System.currentTimeMillis() / 1_000L

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
                    presenceKey = null
                    try {
                        AppPresenceState.current.collect { snapshot ->
                            val activity = snapshot.toDiscordActivity()
                            // The player re-publishes every few seconds; only push real changes.
                            if (activity.isEquivalentTo(lastActivity)) return@collect
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

private fun PresenceSnapshot?.toDiscordActivity(): DiscordActivity {
    // Restart the menu elapsed timer whenever the user actually moves somewhere else, keyed on
    // identity so that the player's periodic republish does not keep resetting it.
    val key = this?.presenceKey
    if (key != presenceKey) {
        presenceKey = key
        presenceSinceSec = System.currentTimeMillis() / 1_000L
    }
    return when (this) {
        null -> browsingActivity(tab = null, query = null, sinceSec = presenceSinceSec)
        is PresenceSnapshot.Tab -> browsingActivity(tab = tab, query = searchQuery, sinceSec = presenceSinceSec)
        is PresenceSnapshot.Details -> detailsActivity(sinceSec = presenceSinceSec)
        is PresenceSnapshot.Player -> toPlayerActivity()
    }
}

/**
 * Menu presence. The headline stays "Watching Nuvio" and the second line says what is actually
 * being done, matching the wording stremio-shell-ng uses for its own menu states.
 */
private fun browsingActivity(tab: AppScreenTab?, query: String?, sinceSec: Long): DiscordActivity {
    val trimmedQuery = query?.trim().orEmpty()
    val (state, details) = when (tab) {
        AppScreenTab.Home -> "Home" to "Browsing"
        AppScreenTab.Search -> (if (trimmedQuery.isEmpty()) "Search" else trimmedQuery) to "Searching"
        AppScreenTab.Library -> "Library" to "Browsing library"
        AppScreenTab.Settings -> "Settings" to "Changing configuration"
        else -> "Nuvio" to "Browsing"
    }

    return DiscordActivity(
        type = DiscordActivityTypes.WATCHING,
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
private fun PresenceSnapshot.Details.detailsActivity(sinceSec: Long): DiscordActivity {
    val releaseYear = year?.trim()?.takeIf { it.isNotEmpty() }
    val largeText = if (releaseYear != null) "$title ($releaseYear)" else title

    return DiscordActivity(
        type = DiscordActivityTypes.WATCHING,
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
 */
private fun PresenceSnapshot.Player.toPlayerActivity(): DiscordActivity {
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
            "composeApp/src/commonMain/kotlin/com/nuvio/app/MainAppContent.kt" \
            "composeApp/src/commonMain/kotlin/com/nuvio/app/features/details/MetaDetailsScreen.kt" \
            "composeApp/src/commonMain/kotlin/com/nuvio/app/features/search/SearchScreen.kt" \
            "composeApp/src/commonMain/kotlin/com/nuvio/app/features/player/PlayerScreenRuntimeUi.kt" \
            "composeApp/src/desktopMain/kotlin/com/nuvio/app/features/discordrpc/DiscordActivity.kt" \
            "composeApp/src/desktopMain/kotlin/com/nuvio/app/features/discordrpc/DiscordPresenceManager.kt" ; do
            if [[ ! -f "${f}" ]]; then
              echo "::error::Missing after overlay: ${f}" >&2
              exit 1
            fi
          done
          echo "all 7 files present"
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
& git commit -m "discord: rebase Rich Presence on upstream af480339 via drp overlay"
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
Write-Host "=============================================" -ForegroundColor Green
