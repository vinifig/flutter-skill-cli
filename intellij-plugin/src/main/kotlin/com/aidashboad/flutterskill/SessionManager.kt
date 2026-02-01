package com.aidashboad.flutterskill

import com.intellij.openapi.components.Service
import com.intellij.openapi.project.Project
import java.time.Instant
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Session state enum
 */
enum class SessionState {
    CREATED,        // Session created, not yet launched
    LAUNCHING,      // App is starting
    CONNECTED,      // Connected to VM Service
    DISCONNECTED,   // Lost connection
    ERROR          // Error state
}

/**
 * Represents a Flutter app session
 */
data class Session(
    val id: String = UUID.randomUUID().toString(),
    var name: String,
    val projectPath: String,
    val deviceId: String,
    val port: Int,
    var state: SessionState = SessionState.CREATED,
    var vmServiceUri: String? = null,
    var vmService: VmServiceInfo? = null,
    var lastUpdate: Instant = Instant.now(),
    var errorMessage: String? = null
) {
    /**
     * Update session state
     */
    fun updateState(newState: SessionState, error: String? = null) {
        state = newState
        errorMessage = error
        lastUpdate = Instant.now()
    }

    /**
     * Get display name for UI
     */
    fun getDisplayName(): String {
        return "$name ($deviceId)"
    }

    /**
     * Get status icon
     */
    fun getStatusIcon(): String {
        return when (state) {
            SessionState.CONNECTED -> "●"      // Green
            SessionState.DISCONNECTED -> "○"   // Gray
            SessionState.LAUNCHING -> "⏳"     // Blue
            SessionState.ERROR -> "⚠️"         // Yellow
            SessionState.CREATED -> "○"        // Gray
        }
    }
}

/**
 * Manages multiple Flutter app sessions
 */
@Service(Service.Level.PROJECT)
class SessionManager(private val project: Project) {
    private val sessions = ConcurrentHashMap<String, Session>()
    private var activeSessionId: String? = null

    private val stateChangeListeners = mutableListOf<(Session) -> Unit>()
    private val sessionListListeners = mutableListOf<() -> Unit>()

    /**
     * Create a new session
     */
    fun createSession(
        name: String,
        projectPath: String,
        deviceId: String,
        port: Int? = null
    ): Session {
        val assignedPort = port ?: getNextAvailablePort()

        val session = Session(
            name = name,
            projectPath = projectPath,
            deviceId = deviceId,
            port = assignedPort
        )

        sessions[session.id] = session

        // If this is the first session, make it active
        if (activeSessionId == null) {
            activeSessionId = session.id
        }

        notifySessionListChanged()
        return session
    }

    /**
     * Get next available port (starting from 50001)
     */
    private fun getNextAvailablePort(): Int {
        val usedPorts = sessions.values.map { it.port }.toSet()
        var port = 50001
        while (port in usedPorts && port < 60000) {
            port++
        }
        return port
    }

    /**
     * Get session by ID
     */
    fun getSession(sessionId: String): Session? {
        return sessions[sessionId]
    }

    /**
     * Get all sessions
     */
    fun getAllSessions(): List<Session> {
        return sessions.values.toList()
    }

    /**
     * Get active session
     */
    fun getActiveSession(): Session? {
        return activeSessionId?.let { sessions[it] }
    }

    /**
     * Switch to a different session
     */
    fun switchToSession(sessionId: String): Boolean {
        if (!sessions.containsKey(sessionId)) {
            return false
        }

        activeSessionId = sessionId
        sessions[sessionId]?.let { notifyStateChanged(it) }
        return true
    }

    /**
     * Update session state
     */
    fun updateSessionState(
        sessionId: String,
        state: SessionState,
        vmServiceUri: String? = null,
        vmService: VmServiceInfo? = null,
        error: String? = null
    ) {
        sessions[sessionId]?.let { session ->
            session.updateState(state, error)
            session.vmServiceUri = vmServiceUri ?: session.vmServiceUri
            session.vmService = vmService ?: session.vmService

            notifyStateChanged(session)
        }
    }

    /**
     * Update session VM service info
     */
    fun updateSessionVmService(sessionId: String, vmService: VmServiceInfo) {
        sessions[sessionId]?.let { session ->
            session.vmService = vmService
            session.vmServiceUri = vmService.uri
            notifyStateChanged(session)
        }
    }

    /**
     * Close a session
     */
    fun closeSession(sessionId: String) {
        sessions.remove(sessionId)

        // If active session was closed, switch to another
        if (activeSessionId == sessionId) {
            activeSessionId = sessions.keys.firstOrNull()
            activeSessionId?.let { newActiveId ->
                sessions[newActiveId]?.let { notifyStateChanged(it) }
            }
        }

        notifySessionListChanged()
    }

    /**
     * Close all sessions
     */
    fun closeAllSessions() {
        sessions.clear()
        activeSessionId = null
        notifySessionListChanged()
    }

    /**
     * Rename a session
     */
    fun renameSession(sessionId: String, newName: String) {
        sessions[sessionId]?.let { session ->
            session.name = newName
            notifyStateChanged(session)
        }
    }

    /**
     * Add listener for session state changes
     */
    fun addStateChangeListener(listener: (Session) -> Unit) {
        stateChangeListeners.add(listener)
    }

    /**
     * Add listener for session list changes (add/remove)
     */
    fun addSessionListListener(listener: () -> Unit) {
        sessionListListeners.add(listener)
    }

    /**
     * Notify listeners of state change
     */
    private fun notifyStateChanged(session: Session) {
        stateChangeListeners.forEach { it(session) }
    }

    /**
     * Notify listeners of session list change
     */
    private fun notifySessionListChanged() {
        sessionListListeners.forEach { it() }
    }

    companion object {
        /**
         * Get instance for project
         */
        fun getInstance(project: Project): SessionManager {
            return project.getService(SessionManager::class.java)
        }
    }
}
