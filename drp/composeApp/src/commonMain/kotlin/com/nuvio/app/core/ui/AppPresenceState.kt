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
