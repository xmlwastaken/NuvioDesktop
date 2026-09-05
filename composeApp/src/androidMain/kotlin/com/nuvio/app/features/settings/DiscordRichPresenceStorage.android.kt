package com.nuvio.app.features.settings

internal actual object DiscordRichPresencePlatform {
    actual val isSupported: Boolean = false
}

internal actual object DiscordRichPresenceStorage {
    actual fun loadEnabled(): Boolean? = null
    actual fun saveEnabled(enabled: Boolean) = Unit
    actual fun loadFlag(key: String): Boolean? = null
    actual fun saveFlag(key: String, value: Boolean) = Unit
}
