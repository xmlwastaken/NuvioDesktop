package com.nuvio.app.features.settings

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

internal object DiscordRichPresenceRepository {
    private const val showButtonsKey = "show_buttons"
    private const val hideWhenPausedKey = "hide_when_paused"
    private const val showBrowsingKey = "show_browsing"
    private const val showSmallImageKey = "show_small_image"
    private const val swapNameAndTitleKey = "swap_name_and_title"

    val isSupported: Boolean
        get() = DiscordRichPresencePlatform.isSupported

    private val _enabled = MutableStateFlow(false)
    val enabled: StateFlow<Boolean> = _enabled.asStateFlow()

    /** Show "View on IMDb" / "Get Nuvio" action buttons under the presence card. */
    private val _showButtons = MutableStateFlow(true)
    val showButtons: StateFlow<Boolean> = _showButtons.asStateFlow()

    /** Clear the presence entirely while playback is paused instead of showing a paused card. */
    private val _hideWhenPaused = MutableStateFlow(false)
    val hideWhenPaused: StateFlow<Boolean> = _hideWhenPaused.asStateFlow()

    /** Report browsing/details activity, not just active playback. */
    private val _showBrowsing = MutableStateFlow(true)
    val showBrowsing: StateFlow<Boolean> = _showBrowsing.asStateFlow()

    /** Overlay the small play/pause badge on the poster. */
    private val _showSmallImage = MutableStateFlow(true)
    val showSmallImage: StateFlow<Boolean> = _showSmallImage.asStateFlow()

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
        _showSmallImage.value = DiscordRichPresenceStorage.loadFlag(showSmallImageKey) ?: true
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

    fun setShowSmallImage(value: Boolean) = updateFlag(_showSmallImage, showSmallImageKey, value)

    fun setSwapNameAndTitle(value: Boolean) = updateFlag(_swapNameAndTitle, swapNameAndTitleKey, value)

    private fun updateFlag(flow: MutableStateFlow<Boolean>, key: String, value: Boolean) {
        ensureLoaded()
        if (flow.value == value) return
        flow.value = value
        DiscordRichPresenceStorage.saveFlag(key, value)
    }
}
