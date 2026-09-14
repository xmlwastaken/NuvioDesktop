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
