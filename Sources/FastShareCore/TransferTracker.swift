import os

/// Turns individual file transfers into what the app shows: how many devices are receiving each
/// file, and when a device has received all of one. Phones often split a download across several
/// connections (Chrome on Android fetches three slices at once) or finish it later with a range
/// request, so both are tracked per device rather than per connection.
struct TransferTracker {
    typealias TransferID = Int

    /// One device receiving one shared file. Devices are told apart by address.
    private struct Receiver: Hashable {
        let token: String
        let client: String
    }

    private struct Transfer {
        let receiver: Receiver
        let fileVersion: String
        let fileSize: UInt64
    }

    /// The bytes of one version of a file sent to a receiver, as sorted, separated ranges.
    private struct Coverage {
        let fileVersion: String
        var ranges: [Range<UInt64>] = []

        mutating func insert(_ range: Range<UInt64>) {
            var merged = range
            var result: [Range<UInt64>] = []
            result.reserveCapacity(ranges.count + 1)
            var isInserted = false
            for existing in ranges {
                if existing.upperBound < merged.lowerBound {
                    result.append(existing)
                } else if merged.upperBound < existing.lowerBound {
                    if !isInserted {
                        result.append(merged)
                        isInserted = true
                    }
                    result.append(existing)
                } else {
                    merged = min(existing.lowerBound, merged.lowerBound)..<max(existing.upperBound, merged.upperBound)
                }
            }
            if !isInserted { result.append(merged) }
            ranges = result
        }

        func covers(size: UInt64) -> Bool {
            guard let first = ranges.first else { return false }
            return first.lowerBound == 0 && first.upperBound >= size
        }
    }

    private var lastID: TransferID = 0
    private var transfers: [TransferID: Transfer] = [:]
    private var coverage: [Receiver: Coverage] = [:]

    mutating func begin(token: String, client: String, fileVersion: String, fileSize: UInt64)
        -> (TransferID, [HTTPServer.Event]) {
        let devicesBefore = deviceCount(for: token)
        lastID += 1
        transfers[lastID] = Transfer(receiver: Receiver(token: token, client: client), fileVersion: fileVersion,
                                     fileSize: fileSize)
        var events = deviceEvents(for: token, before: devicesBefore)
        if fileSize == 0 { events.append(.downloadCompleted(token: token)) } // Nothing to receive.
        return (lastID, events)
    }

    /// Records bytes as soon as they're handed to the network: never less than the device received,
    /// so a complete download always counts, even when a connection is dropped right after its last byte.
    mutating func sent(_ range: Range<UInt64>, by id: TransferID) -> [HTTPServer.Event] {
        guard let transfer = transfers[id], !range.isEmpty else { return [] }
        var sent = coverage[transfer.receiver].flatMap { $0.fileVersion == transfer.fileVersion ? $0 : nil }
            ?? Coverage(fileVersion: transfer.fileVersion)
        sent.insert(range)
        guard sent.covers(size: transfer.fileSize) else {
            coverage[transfer.receiver] = sent
            return []
        }
        coverage[transfer.receiver] = nil // Downloading the file again counts again.
        return [.downloadCompleted(token: transfer.receiver.token)]
    }

    mutating func end(_ id: TransferID) -> [HTTPServer.Event] {
        guard let token = transfers[id]?.receiver.token else { return [] }
        let devicesBefore = deviceCount(for: token)
        transfers[id] = nil
        return deviceEvents(for: token, before: devicesBefore)
    }

    private func deviceCount(for token: String) -> Int {
        Set(transfers.values.lazy.filter { $0.receiver.token == token }.map(\.receiver.client)).count
    }

    private func deviceEvents(for token: String, before: Int) -> [HTTPServer.Event] {
        let count = deviceCount(for: token)
        return count == before ? [] : [.devicesChanged(token: token, count: count)]
    }
}

/// Thread-safe front for a `TransferTracker`: connections report from their own queues.
final class TransferMonitor: Sendable {
    private let tracker = OSAllocatedUnfairLock(initialState: TransferTracker())
    private let emit: @Sendable (HTTPServer.Event) -> Void

    init(emit: @escaping @Sendable (HTTPServer.Event) -> Void) {
        self.emit = emit
    }

    // Events are emitted while holding the lock so they arrive in the order the tracker produced
    // them; the app's handler only dispatches to the main queue.

    func begin(token: String, client: String, fileVersion: String, fileSize: UInt64) -> TransferTracker.TransferID {
        tracker.withLock { tracker in
            let (id, events) = tracker.begin(token: token, client: client, fileVersion: fileVersion, fileSize: fileSize)
            events.forEach(emit)
            return id
        }
    }

    func sent(_ range: Range<UInt64>, by id: TransferTracker.TransferID) {
        tracker.withLock { $0.sent(range, by: id).forEach(emit) }
    }

    func end(_ id: TransferTracker.TransferID) {
        tracker.withLock { $0.end(id).forEach(emit) }
    }
}
