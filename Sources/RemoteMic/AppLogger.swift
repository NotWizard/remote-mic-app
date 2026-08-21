import Foundation

/// Collapses repeats of a few explicitly opted-in, high-noise log messages.
///
/// Field data from a long-running install (11 days, 113242 lines) showed the noisiest
/// messages do **not** arrive consecutively: `BLE CONNECTING` and `BLE CONNECT TIMEOUT`
/// strictly alternate, so comparing only against the previous line saves nothing. The
/// fold therefore keys on a bounded table of recently seen keys with a time window
/// instead of a single "last message" slot.
///
/// Folding is **opt-in per message class**, not a structural heuristic. An earlier
/// version keyed on "every token up to and including the first token containing `=`"
/// for every message. Replaying that rule over the same field log suppressed 78165
/// lines, and 1586 of them carried content that differed from the line that was kept —
/// the difference always sat *after* the first `=`. Casualties per key included
/// `AUDIO CONFIGURE begin target={name=MiRemoteV…` (802 lines), `VOICE DESTINATION
/// pending request=1` (164), `AUDIO READY target={name=MiRemoteV…` (118),
/// `AUDIO REBIND begin reason=recovery_…` (88, where the discriminating
/// `bound_to_selected=false` lives) and `APP FOCUS failed bundle=…` (46). That is the
/// same defect as squashing several distinct causes into one indistinguishable line,
/// so the heuristic was replaced by this whitelist.
enum LogFold {
    /// Longest message that may fold. A key is always the *whole* message, so refusing
    /// to fold anything longer is what makes truncation-induced collisions impossible.
    static let keyScanLimit = 160

    /// Message classes allowed to fold, as literal prefixes.
    ///
    /// The first three are the bluetooth reconnect retry loop, the single mechanism behind
    /// 43557 of the 113242 field lines (38.5%): a scan starts, a connect is attempted,
    /// it times out, repeat. Every attempt renders byte-identical text, so a count is a
    /// complete substitute for the individual lines.
    ///
    /// `HID INPUT ignored reason=` is the same shape for a different mechanism: it sits on
    /// the per-HID-report path, where a chattering remote can produce hundreds of reports a
    /// second, and it renders a fixed reason token plus at most a button name — no
    /// `state={…}` dump whose contents would be lost. Nothing else is listed: the other
    /// high-volume classes all carry a per-line `state={…}` or `target={…}` dump whose
    /// contents are exactly what triage needs.
    static let foldableMessagePrefixes = [
        "BLE CONNECTING ",
        "BLE CONNECT TIMEOUT",
        "BLE SCANNING",
        "HID INPUT ignored reason=",
    ]

    /// Fold key for `message`, or `nil` when the message must be written verbatim.
    ///
    /// The key is the entire message, so two lines that share a key are byte-identical
    /// and a suppressed repeat can never hide a field the retained line does not show.
    static func foldKey(for message: String) -> String? {
        guard foldableMessagePrefixes.contains(where: { message.hasPrefix($0) }) else { return nil }
        // A truncated key could merge two different messages that share a long prefix.
        guard message.count <= keyScanLimit else { return nil }
        return message
    }
}

final class AppLogger {
    static let shared = AppLogger()

    /// Rotation threshold. Four MiB stays small enough to open in an editor or attach to
    /// a feedback report, and at the projected post-fix write rate (~0.9 MB/day for a
    /// permanently resident menu-bar app) one file covers roughly four days.
    static let defaultMaximumFileSize: UInt64 = 4 * 1024 * 1024

    /// Archives kept besides the live file. Three archives cap the log directory at
    /// 16 MiB while retaining ~2.5x the "it broke sometime last week" report window.
    static let defaultMaximumArchiveCount = 3

    /// Byte-identical repeats of a whitelisted message inside this window are counted
    /// instead of written. Sixty seconds collapses the observed ~11s bluetooth retry
    /// loop about 5x while keeping per-minute resolution, which bug triage needs to line
    /// up log evidence with a user-reported time range.
    static let defaultFoldWindow: TimeInterval = 60

    let logURL: URL

    private let queue = DispatchQueue(label: "RemoteMic.logger")
    private let formatter = ISO8601DateFormatter()
    private let maximumFileSize: UInt64
    private let maximumArchiveCount: Int
    private let foldWindow: TimeInterval

    /// Guards fold bookkeeping, the formatter and the observer table. Held only for
    /// cheap in-memory work so the caller never blocks on file IO.
    private let stateLock = NSLock()
    private var foldStates: [String: FoldState] = [:]
    private var observers: [UUID: (String) -> Void] = [:]

    // File state, touched only on `queue`.
    private var handle: FileHandle?
    private var currentSize: UInt64 = 0
    private var reportedWriteFailure = false
    private var writeFailureCountStorage = 0

    private struct FoldState {
        var windowStart: Date
        var suppressed: Int
    }

    private enum Decision {
        case suppress
        case emit(suffix: String)
    }

    private init() {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("RemoteMic", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        logURL = base.appendingPathComponent("runtime.log")
        maximumFileSize = Self.defaultMaximumFileSize
        maximumArchiveCount = Self.defaultMaximumArchiveCount
        foldWindow = Self.defaultFoldWindow
    }

    /// Test seam: a logger writing to a caller-owned directory. Production code keeps
    /// using `AppLogger.shared`.
    init(
        directory: URL,
        fileName: String = "runtime.log",
        maximumFileSize: UInt64 = AppLogger.defaultMaximumFileSize,
        maximumArchiveCount: Int = AppLogger.defaultMaximumArchiveCount,
        foldWindow: TimeInterval = AppLogger.defaultFoldWindow
    ) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        logURL = directory.appendingPathComponent(fileName)
        self.maximumFileSize = maximumFileSize
        self.maximumArchiveCount = maximumArchiveCount
        self.foldWindow = foldWindow
    }

    deinit {
        try? handle?.close()
    }

    /// Appends `message` to the runtime log.
    ///
    /// `message` is an `@autoclosure`, so expensive interpolations (for example
    /// `VirtualAudioOutput.diagnosticState()`, which performs ~9 synchronous CoreAudio
    /// property reads) are only paid for when the line is actually written.
    ///
    /// Only the message classes in `LogFold.foldableMessagePrefixes` fold; everything
    /// else reaches disk verbatim, one line per call. Pass `foldKey` to take the fold
    /// decision *before* the message is built, so suppressed repeats cost nothing. The
    /// key must be the complete message text: if the built message turns out to differ
    /// from it, the key is thrown away instead of being used to suppress anything, so a
    /// wrong `foldKey` can only cost a rebuild, never a merged line.
    ///
    /// The message is built on the calling thread, matching the previous behaviour, so
    /// callers touching main-thread-only state stay safe.
    func write(_ message: @autoclosure () -> String, foldKey: String? = nil) {
        let now = Date()

        if let declared = foldKey, let key = LogFold.foldKey(for: declared) {
            let (decision, staleSummaries) = resolve(key: key, now: now)
            switch decision {
            case .suppress:
                append(lines: staleSummaries, at: now)
            case .emit(let suffix):
                let built = message()
                guard LogFold.foldKey(for: built) == key else {
                    // The declared key does not describe this message, so folding on it
                    // could merge differing lines. Forget the window `resolve` just opened
                    // — nothing has been suppressed under it — and use the message itself.
                    discard(key: key)
                    emit(built: built, pending: staleSummaries, at: now)
                    return
                }
                append(lines: staleSummaries + [built + suffix], at: now)
            }
            return
        }

        emit(built: message(), pending: [], at: now)
    }

    /// Folds and writes a message that has already been built. `pending` carries summary
    /// lines collected earlier in the same call so their order is preserved.
    private func emit(built: String, pending: [String], at now: Date) {
        guard let key = LogFold.foldKey(for: built) else {
            append(lines: pending + sweepExpired(now: now) + [built], at: now)
            return
        }
        let (decision, staleSummaries) = resolve(key: key, now: now)
        switch decision {
        case .suppress:
            append(lines: pending + staleSummaries, at: now)
        case .emit(let suffix):
            append(lines: pending + staleSummaries + [built + suffix], at: now)
        }
    }

    /// Blocks until every queued line has reached the file. Tests only.
    func flush() {
        queue.sync {}
    }

    /// Number of failed disk writes observed so far. Surfaced instead of swallowed so a
    /// broken log destination is detectable without logging recursively.
    var writeFailureCount: Int {
        queue.sync { writeFailureCountStorage }
    }

    /// Observes every line that is actually written. Tests only; suppressed lines never
    /// reach observers, which is what makes fold behaviour assertable.
    @discardableResult
    func addWriteObserver(_ observer: @escaping (String) -> Void) -> UUID {
        let id = UUID()
        stateLock.lock()
        observers[id] = observer
        stateLock.unlock()
        return id
    }

    func removeWriteObserver(_ id: UUID) {
        stateLock.lock()
        observers.removeValue(forKey: id)
        stateLock.unlock()
    }

    // MARK: - Folding

    /// Decides whether `key` may be written now, and collects summaries for other keys
    /// whose window expired while they still had suppressed repeats. Entries are dropped
    /// once summarised, which keeps the table bounded by the number of message classes
    /// active in the last window rather than growing without limit.
    private func resolve(key: String, now: Date) -> (Decision, [String]) {
        stateLock.lock()
        defer { stateLock.unlock() }

        var suffix = ""
        if let state = foldStates[key] {
            if now.timeIntervalSince(state.windowStart) < foldWindow {
                foldStates[key]?.suppressed = state.suppressed + 1
                return (.suppress, expiredSummaries(now: now, excluding: key))
            }
            if state.suppressed > 0 {
                suffix = " folded_repeats=\(state.suppressed)"
            }
        }
        foldStates[key] = FoldState(windowStart: now, suppressed: 0)
        return (.emit(suffix: suffix), expiredSummaries(now: now, excluding: key))
    }

    /// Must be called with `stateLock` held.
    private func expiredSummaries(now: Date, excluding key: String) -> [String] {
        let expired = foldStates.filter { candidate, state in
            candidate != key && now.timeIntervalSince(state.windowStart) >= foldWindow
        }
        guard !expired.isEmpty else { return [] }

        var summaries: [String] = []
        for (candidate, state) in expired {
            if state.suppressed > 0 {
                summaries.append("LOG FOLD flushed key={\(candidate)} folded_repeats=\(state.suppressed)")
            }
            foldStates.removeValue(forKey: candidate)
        }
        return summaries
    }

    /// Forgets a fold window that must not be used. Called when a caller-declared
    /// `foldKey` turns out not to match the message it was supposed to describe.
    private func discard(key: String) {
        stateLock.lock()
        foldStates.removeValue(forKey: key)
        stateLock.unlock()
    }

    /// Drains pending fold counts without opening a window. Non-foldable messages — the
    /// overwhelming majority — take this path, so a count never waits for the next
    /// occurrence of its own key to be reported.
    private func sweepExpired(now: Date) -> [String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return expiredSummaries(now: now, excluding: "")
    }

    // MARK: - File output

    private func append(lines: [String], at date: Date) {
        guard !lines.isEmpty else { return }
        stateLock.lock()
        let stamp = formatter.string(from: date)
        let sinks = Array(observers.values)
        stateLock.unlock()

        let rendered = lines.map { "\(stamp) \($0)\n" }
        for sink in sinks {
            for line in lines { sink(line) }
        }
        queue.async { [weak self] in
            guard let self else { return }
            for line in rendered {
                self.appendOnQueue(Data(line.utf8))
            }
        }
    }

    private func appendOnQueue(_ data: Data) {
        guard openHandleOnQueue() != nil else { return }
        if currentSize > 0, currentSize + UInt64(data.count) > maximumFileSize {
            rotateOnQueue()
            guard openHandleOnQueue() != nil else { return }
        }
        guard let active = handle else { return }
        do {
            try active.write(contentsOf: data)
            currentSize += UInt64(data.count)
        } catch {
            recordFailureOnQueue(error, stage: "write")
            // Drop the handle so the next line reopens instead of writing into a dead fd.
            try? active.close()
            handle = nil
        }
    }

    private func openHandleOnQueue() -> FileHandle? {
        if let handle { return handle }
        let manager = FileManager.default
        let path = logURL.path
        if !manager.fileExists(atPath: path) {
            // 0600: the log records target bundle identifiers and audio device names, so
            // it must not stay world readable like the previous 0644 default.
            manager.createFile(
                atPath: path,
                contents: nil,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
            )
        } else {
            try? manager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: path
            )
        }
        do {
            let opened = try FileHandle(forWritingTo: logURL)
            currentSize = try opened.seekToEnd()
            handle = opened
            return opened
        } catch {
            recordFailureOnQueue(error, stage: "open")
            return nil
        }
    }

    private func rotateOnQueue() {
        let manager = FileManager.default
        try? handle?.close()
        handle = nil
        currentSize = 0

        guard maximumArchiveCount > 0 else {
            try? manager.removeItem(at: logURL)
            return
        }
        let archive: (Int) -> URL = { [logURL] index in
            logURL.appendingPathExtension(String(index))
        }
        try? manager.removeItem(at: archive(maximumArchiveCount))
        var index = maximumArchiveCount - 1
        while index >= 1 {
            let source = archive(index)
            if manager.fileExists(atPath: source.path) {
                try? manager.removeItem(at: archive(index + 1))
                try? manager.moveItem(at: source, to: archive(index + 1))
            }
            index -= 1
        }
        try? manager.removeItem(at: archive(1))
        try? manager.moveItem(at: logURL, to: archive(1))
    }

    /// Reports the first failure to stderr and keeps a counter. Never logs through
    /// `self`, which would recurse on a failing destination.
    private func recordFailureOnQueue(_ error: Error, stage: String) {
        writeFailureCountStorage += 1
        guard !reportedWriteFailure else { return }
        reportedWriteFailure = true
        let notice = "RemoteMic AppLogger \(stage) failed for \(logURL.path): \(error)\n"
        FileHandle.standardError.write(Data(notice.utf8))
    }
}
