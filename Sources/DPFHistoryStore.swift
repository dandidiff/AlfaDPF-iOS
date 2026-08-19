import Foundation
import SQLite3

// MARK: - Data types

/// A single DPF sample recorded to the time-series store.
struct DPFHistorySample: Equatable, Sendable {
    let timestamp: Date
    /// Cumulative driving time (seconds while the engine is running with the
    /// app connected) at the moment this sample was recorded. The chart plots
    /// against this axis so idle engine-off gaps are compressed away.
    let drivingTime: TimeInterval
    let cloggingPercent: Double
    let exhaustTempC: Double?
    let regenActive: Bool
    let distanceSinceLastRegenKm: Double?
}

/// A recorded regeneration cycle.
struct DPFRegenCycle: Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case active
        case completed
        case interrupted
        case unconfirmed
    }

    let id: Int64
    let startedAt: Date
    let finishedAt: Date?
    let startingLoad: Double
    let endingLoad: Double?
    let status: Status
}

/// Honest aggregate of locally recorded cycles. Active and unconfirmed rows
/// remain visible in the history but do not dilute outcome or duration stats.
struct DPFHistoryInsights: Equatable, Sendable {
    let completedCycles: Int
    let interruptedCycles: Int
    let unconfirmedCycles: Int
    let averageDuration: TimeInterval?
    let averageLoadReduction: Double?

    var observedOutcomeCount: Int { completedCycles + interruptedCycles }

    var completionRate: Double? {
        guard observedOutcomeCount > 0 else { return nil }
        return Double(completedCycles) / Double(observedOutcomeCount)
    }

    init(
        completedCycles: Int,
        interruptedCycles: Int,
        unconfirmedCycles: Int,
        averageDuration: TimeInterval?,
        averageLoadReduction: Double?
    ) {
        self.completedCycles = completedCycles
        self.interruptedCycles = interruptedCycles
        self.unconfirmedCycles = unconfirmedCycles
        self.averageDuration = averageDuration
        self.averageLoadReduction = averageLoadReduction
    }

    init(cycles: [DPFRegenCycle]) {
        let completedCycles = cycles.count { $0.status == .completed }
        let interruptedCycles = cycles.count { $0.status == .interrupted }
        let unconfirmedCycles = cycles.count { $0.status == .unconfirmed }

        let completedDurations = cycles.compactMap { cycle -> TimeInterval? in
            guard cycle.status == .completed, let finishedAt = cycle.finishedAt else { return nil }
            let duration = finishedAt.timeIntervalSince(cycle.startedAt)
            return duration >= 0 ? duration : nil
        }
        let averageDuration = completedDurations.isEmpty
            ? nil
            : completedDurations.reduce(0, +) / Double(completedDurations.count)

        let completedReductions = cycles.compactMap { cycle -> Double? in
            guard cycle.status == .completed, let endingLoad = cycle.endingLoad else { return nil }
            let reduction = cycle.startingLoad - endingLoad
            return reduction >= 0 ? reduction : nil
        }
        let averageLoadReduction = completedReductions.isEmpty
            ? nil
            : completedReductions.reduce(0, +) / Double(completedReductions.count)

        self.init(
            completedCycles: completedCycles,
            interruptedCycles: interruptedCycles,
            unconfirmedCycles: unconfirmedCycles,
            averageDuration: averageDuration,
            averageLoadReduction: averageLoadReduction
        )
    }
}

// MARK: - Store

/// On-device SQLite store for DPF time-series samples and regeneration cycles.
/// Samples are recorded on a delta basis (≥1% load change) and pruned to a
/// rolling 200-driving-hours window — wall-clock idle time between drives is
/// not counted. Everything stays local — zero network, zero account.
///
/// @unchecked Sendable: the OpaquePointer (SQLite handle) is not Sendable,
/// but all access is serialized through the internal DispatchQueue.
final class DPFHistoryStore: @unchecked Sendable {
    private let db: OpaquePointer
    private let queue = DispatchQueue(label: "dpf.history.store")

    /// Retention window expressed in driving hours. A regeneration lands every
    /// ~12–18 driving hours, so 200 hours spans roughly ten cycles.
    private static let drivingWindow: TimeInterval = 200 * 60 * 60
    private static let minLoadDelta = 1.0

    // MARK: - Init

    init(databaseURL: URL? = nil) throws {
        let dbURL = try databaseURL ?? Self.databaseURL()
        try FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        if sqlite3_open(dbURL.path, &handle) != SQLITE_OK {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw HistoryStoreError.openFailed(msg)
        }
        guard let handle else {
            throw HistoryStoreError.openFailed("nil handle")
        }
        self.db = handle
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try createSchema()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Schema

    private func createSchema() throws {
        // The pre-driving-time schema stored wall-clock samples only. Those
        // rows carry no driving-time coordinate, so they are discarded on
        // upgrade rather than given an invented value.
        if samplesTableMissingDrivingTime() {
            try execute("DROP TABLE dpf_samples")
        }
        try execute("""
            CREATE TABLE IF NOT EXISTS dpf_samples (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp REAL NOT NULL,
                driving_time REAL NOT NULL,
                clogging_pct REAL NOT NULL,
                exhaust_temp_c REAL,
                regen_active INTEGER NOT NULL DEFAULT 0,
                distance_km REAL,
                UNIQUE(timestamp)
            )
            """)
        try execute("""
            CREATE INDEX IF NOT EXISTS idx_samples_driving_time
            ON dpf_samples(driving_time)
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS regen_cycles (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                started_at REAL NOT NULL,
                finished_at REAL,
                starting_load REAL NOT NULL,
                ending_load REAL,
                status TEXT NOT NULL DEFAULT 'active'
            )
            """)
        try execute("""
            CREATE INDEX IF NOT EXISTS idx_cycles_started
            ON regen_cycles(started_at)
            """)
    }

    /// True when `dpf_samples` already exists but predates the driving-time
    /// column. A brand-new database (no table) returns false.
    private func samplesTableMissingDrivingTime() -> Bool {
        let sql = "PRAGMA table_info(dpf_samples)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return false
        }
        defer { sqlite3_finalize(stmt) }
        var hasColumns = false
        var hasDrivingTime = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            hasColumns = true
            if let name = sqlite3_column_text(stmt, 1),
               String(cString: name) == "driving_time" {
                hasDrivingTime = true
            }
        }
        return hasColumns && !hasDrivingTime
    }

    // MARK: - Sample recording

    /// Records a sample if the load changed by at least 1% from the last
    /// recorded value. Returns true when a row was actually inserted.
    @discardableResult
    func recordSample(
        timestamp: Date,
        drivingTime: TimeInterval,
        cloggingPercent: Double,
        exhaustTempC: Double?,
        regenActive: Bool,
        distanceSinceLastRegenKm: Double?
    ) -> Bool {
        queue.sync {
            _recordSample(
                timestamp: timestamp,
                drivingTime: drivingTime,
                cloggingPercent: cloggingPercent,
                exhaustTempC: exhaustTempC,
                regenActive: regenActive,
                distanceSinceLastRegenKm: distanceSinceLastRegenKm
            )
        }
    }

    /// Records without blocking the caller. MonitorSession is main-actor
    /// isolated, so its regular telemetry path must never wait for SQLite.
    func recordSampleAsync(
        timestamp: Date,
        drivingTime: TimeInterval,
        cloggingPercent: Double,
        exhaustTempC: Double?,
        regenActive: Bool,
        distanceSinceLastRegenKm: Double?
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: _recordSample(
                    timestamp: timestamp,
                    drivingTime: drivingTime,
                    cloggingPercent: cloggingPercent,
                    exhaustTempC: exhaustTempC,
                    regenActive: regenActive,
                    distanceSinceLastRegenKm: distanceSinceLastRegenKm
                ))
            }
        }
    }

    private func _recordSample(
        timestamp: Date,
        drivingTime: TimeInterval,
        cloggingPercent: Double,
        exhaustTempC: Double?,
        regenActive: Bool,
        distanceSinceLastRegenKm: Double?
    ) -> Bool {
        // Prune before the delta check. Otherwise an expired row with almost
        // the same value can suppress the first valid sample of a new window
        // forever.
        _pruneOldSamples(beforeDrivingTime: drivingTime - Self.drivingWindow)

        // Check delta against the most recent sample by driving time.
        let lastSQL = "SELECT clogging_pct FROM dpf_samples ORDER BY driving_time DESC LIMIT 1"
        var stmt: OpaquePointer?
        var shouldInsert = true
        if sqlite3_prepare_v2(db, lastSQL, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                let last = sqlite3_column_double(stmt, 0)
                if abs(cloggingPercent - last) < Self.minLoadDelta {
                    shouldInsert = false
                }
            }
        }
        sqlite3_finalize(stmt)

        guard shouldInsert else { return false }

        let insertSQL = """
            INSERT INTO dpf_samples (timestamp, driving_time, clogging_pct, exhaust_temp_c, regen_active, distance_km)
            VALUES (?, ?, ?, ?, ?, ?)
            """
        if sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, timestamp.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, drivingTime)
            sqlite3_bind_double(stmt, 3, cloggingPercent)
            if let temp = exhaustTempC {
                sqlite3_bind_double(stmt, 4, temp)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_int(stmt, 5, regenActive ? 1 : 0)
            if let dist = distanceSinceLastRegenKm {
                sqlite3_bind_double(stmt, 6, dist)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            let rc = sqlite3_step(stmt)
            sqlite3_finalize(stmt)

            if rc == SQLITE_DONE {
                return true
            }
        }
        sqlite3_finalize(stmt)
        return false
    }

    // MARK: - Regen cycles

    @discardableResult
    func recordRegenStart(
        at timestamp: Date,
        load: Double
    ) -> Bool {
        queue.sync {
            guard !_hasActiveRegen() else { return false }
            let sql = """
                INSERT INTO regen_cycles (started_at, starting_load, status)
                VALUES (?, ?, 'active')
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt)
                return false
            }
            sqlite3_bind_double(stmt, 1, timestamp.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, load)
            let inserted = sqlite3_step(stmt) == SQLITE_DONE
            sqlite3_finalize(stmt)
            return inserted
        }
    }

    @discardableResult
    func recordRegenFinish(
        at timestamp: Date,
        endingLoad: Double?
    ) -> Bool {
        queue.sync {
            _closeActiveRegen(
                at: timestamp,
                endingLoad: endingLoad,
                status: .completed
            )
        }
    }

    /// Marks the active regeneration as interrupted because robust battery
    /// evidence indicates the engine stopped mid-cycle.
    @discardableResult
    func recordRegenInterrupted(
        at timestamp: Date,
        endingLoad: Double?
    ) -> Bool {
        queue.sync {
            _closeActiveRegen(
                at: timestamp,
                endingLoad: endingLoad,
                status: .interrupted
            )
        }
    }

    /// Resolves an active row left behind across app termination or an
    /// unobserved disconnect. Neither outcome can be inferred honestly.
    @discardableResult
    func recordActiveRegenUnconfirmed() -> Bool {
        queue.sync {
            let sql = """
                UPDATE regen_cycles
                SET status = 'unconfirmed'
                WHERE id = (
                    SELECT id FROM regen_cycles
                    WHERE status = 'active'
                    ORDER BY started_at DESC LIMIT 1
                )
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt)
                return false
            }
            let updated = sqlite3_step(stmt) == SQLITE_DONE && sqlite3_changes(db) == 1
            sqlite3_finalize(stmt)
            return updated
        }
    }

    // MARK: - Queries

    /// Returns every retained sample, ordered by driving time ascending. The
    /// store already prunes to the driving-time window, so no further filter
    /// is applied here.
    func samples(limit: Int = 2000) -> [DPFHistorySample] {
        queue.sync {
            _samples(limit: limit)
        }
    }

    private func _samples(limit: Int) -> [DPFHistorySample] {
        let sql = """
            SELECT timestamp, driving_time, clogging_pct, exhaust_temp_c, regen_active, distance_km
            FROM dpf_samples
            ORDER BY driving_time ASC
            LIMIT ?
            """
        var result: [DPFHistorySample] = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(min(limit, 2000)))
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(DPFHistorySample(
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                    drivingTime: sqlite3_column_double(stmt, 1),
                    cloggingPercent: sqlite3_column_double(stmt, 2),
                    exhaustTempC: sqlite3_column_type(stmt, 3) == SQLITE_NULL
                        ? nil : sqlite3_column_double(stmt, 3),
                    regenActive: sqlite3_column_int(stmt, 4) != 0,
                    distanceSinceLastRegenKm: sqlite3_column_type(stmt, 5) == SQLITE_NULL
                        ? nil : sqlite3_column_double(stmt, 5)
                ))
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    /// Most recent cumulative driving time, used to seed the session's
    /// accumulator across app restarts. Zero when the store is empty.
    func latestDrivingTime() -> TimeInterval {
        queue.sync {
            let sql = "SELECT MAX(driving_time) FROM dpf_samples"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt)
                return 0
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return 0 }
            return sqlite3_column_double(stmt, 0)
        }
    }

    /// Returns the most recent regeneration cycles, newest first.
    func cycles(limit: Int = 50) -> [DPFRegenCycle] {
        queue.sync {
            _cycles(limit: limit)
        }
    }

    private func _cycles(limit: Int) -> [DPFRegenCycle] {
        let sql = """
            SELECT id, started_at, finished_at, starting_load, ending_load, status
            FROM regen_cycles
            ORDER BY started_at DESC
            LIMIT ?
            """
        var result: [DPFRegenCycle] = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(min(limit, 100)))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let statusRaw = String(cString: sqlite3_column_text(stmt, 5))
                result.append(DPFRegenCycle(
                    id: sqlite3_column_int64(stmt, 0),
                    startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                    finishedAt: sqlite3_column_type(stmt, 2) == SQLITE_NULL
                        ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                    startingLoad: sqlite3_column_double(stmt, 3),
                    endingLoad: sqlite3_column_type(stmt, 4) == SQLITE_NULL
                        ? nil : sqlite3_column_double(stmt, 4),
                    status: DPFRegenCycle.Status(rawValue: statusRaw) ?? .active
                ))
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    /// Aggregates every recorded cycle. The visible list is intentionally
    /// capped for rendering, but summary cards must not silently change their
    /// meaning once the database contains more than 50 rows.
    func insights() -> DPFHistoryInsights {
        queue.sync { _insights() }
    }

    private func _insights() -> DPFHistoryInsights {
        let sql = """
            SELECT
                SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END),
                SUM(CASE WHEN status = 'interrupted' THEN 1 ELSE 0 END),
                SUM(CASE WHEN status = 'unconfirmed' THEN 1 ELSE 0 END),
                AVG(CASE
                    WHEN status = 'completed'
                     AND finished_at IS NOT NULL
                     AND finished_at >= started_at
                    THEN finished_at - started_at
                END),
                AVG(CASE
                    WHEN status = 'completed'
                     AND ending_load IS NOT NULL
                     AND starting_load >= ending_load
                    THEN starting_load - ending_load
                END)
            FROM regen_cycles
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return DPFHistoryInsights(cycles: [])
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return DPFHistoryInsights(cycles: [])
        }
        return DPFHistoryInsights(
            completedCycles: Int(sqlite3_column_int64(stmt, 0)),
            interruptedCycles: Int(sqlite3_column_int64(stmt, 1)),
            unconfirmedCycles: Int(sqlite3_column_int64(stmt, 2)),
            averageDuration: sqlite3_column_type(stmt, 3) == SQLITE_NULL
                ? nil : sqlite3_column_double(stmt, 3),
            averageLoadReduction: sqlite3_column_type(stmt, 4) == SQLITE_NULL
                ? nil : sqlite3_column_double(stmt, 4)
        )
    }

    /// Returns true if there's currently an active (unfinished) regeneration.
    var hasActiveRegen: Bool {
        queue.sync {
            _hasActiveRegen()
        }
    }

    // MARK: - Maintenance

    private func _pruneOldSamples(beforeDrivingTime cutoff: TimeInterval) {
        let sql = "DELETE FROM dpf_samples WHERE driving_time < ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    private func _hasActiveRegen() -> Bool {
        let sql = "SELECT 1 FROM regen_cycles WHERE status = 'active' LIMIT 1"
        var stmt: OpaquePointer?
        let found: Bool
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            found = sqlite3_step(stmt) == SQLITE_ROW
        } else {
            found = false
        }
        sqlite3_finalize(stmt)
        return found
    }

    private func _closeActiveRegen(
        at timestamp: Date,
        endingLoad: Double?,
        status: DPFRegenCycle.Status
    ) -> Bool {
        guard status == .completed || status == .interrupted else { return false }
        let sql = """
            UPDATE regen_cycles
            SET finished_at = ?, ending_load = ?, status = ?
            WHERE id = (
                SELECT id FROM regen_cycles
                WHERE status = 'active'
                ORDER BY started_at DESC LIMIT 1
            )
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return false
        }
        sqlite3_bind_double(stmt, 1, timestamp.timeIntervalSince1970)
        if let endingLoad {
            sqlite3_bind_double(stmt, 2, endingLoad)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        sqlite3_bind_text(
            stmt,
            3,
            status.rawValue,
            -1,
            unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        )
        let updated = sqlite3_step(stmt) == SQLITE_DONE && sqlite3_changes(db) == 1
        sqlite3_finalize(stmt)
        return updated
    }

    // MARK: - Helpers

    private static func databaseURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport.appendingPathComponent("DPFHistory", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("dpf_history.db")
    }

    @discardableResult
    private func execute(_ sql: String) throws -> Bool {
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let msg = errMsg.flatMap { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw HistoryStoreError.execFailed(msg)
        }
        return true
    }
}

// MARK: - Errors

enum HistoryStoreError: Error {
    case openFailed(String)
    case execFailed(String)
}
