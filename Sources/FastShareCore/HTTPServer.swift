import Foundation
import Network

/// Minimal HTTP/1.1 server for share links. It listens on every interface, so links keep
/// working when the Mac moves between Wi‑Fi networks or joins a phone's hotspot.
public final class HTTPServer: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    public enum Event: Sendable, Equatable {
        case transferStarted(token: String)
        /// `completedFile` is true when the entire file went out in a single 200 response.
        case transferFinished(token: String, completedFile: Bool)
    }

    struct Context: Sendable {
        let registry: ShareRegistry
        let senderName: String
        let emit: @Sendable (Event) -> Void
    }

    private let context: Context
    private let onStateChange: @Sendable (State) -> Void
    private let queue = DispatchQueue(label: "app.fastshare.server")

    // Confined to `queue`.
    private var listener: NWListener?
    private var listenerIsReady = false
    private var generation = 0
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]

    /// Callbacks arrive on a private queue.
    public init(
        registry: ShareRegistry,
        senderName: String,
        onStateChange: @escaping @Sendable (State) -> Void,
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        context = Context(registry: registry, senderName: senderName, emit: onEvent)
        self.onStateChange = onStateChange
    }

    /// Listens on the first free port in `ports`; 0 lets the system choose.
    public func start(ports: [UInt16]) {
        queue.async {
            self.generation += 1
            self.cancelListener()
            self.onStateChange(.starting)
            self.listen(on: ports[...], allPorts: ports, generation: self.generation, lastError: nil)
        }
    }

    public func stop() {
        queue.async {
            self.generation += 1
            self.cancelListener()
            for connection in self.connections.values {
                connection.cancel()
            }
            self.connections.removeAll()
        }
    }

    private func listen(on candidates: ArraySlice<UInt16>, allPorts: [UInt16], generation: Int, lastError: NWError?) {
        guard generation == self.generation else { return }
        guard let port = candidates.first else {
            onStateChange(.failed(lastError.map(Self.describe) ?? "No port available for sharing."))
            return
        }
        let remaining = candidates.dropFirst()

        let listener: NWListener
        do {
            listener = try NWListener(using: Self.makeParameters(), on: NWEndpoint.Port(rawValue: port) ?? .any)
        } catch {
            listen(on: remaining, allPorts: allPorts, generation: generation, lastError: error as? NWError)
            return
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, listener === self.listener else { return }
            switch state {
            case .ready:
                self.listenerIsReady = true
                self.onStateChange(.running(port: listener.port?.rawValue ?? port))
            case .failed(let error):
                let wasReady = self.listenerIsReady
                self.cancelListener()
                if wasReady {
                    // A working listener died (e.g. the network stack reset): start over shortly.
                    self.onStateChange(.starting)
                    self.queue.asyncAfter(deadline: .now() + 1) {
                        self.listen(on: allPorts[...], allPorts: allPorts, generation: generation, lastError: nil)
                    }
                } else {
                    // Usually EADDRINUSE: try the next port.
                    self.listen(on: remaining, allPorts: allPorts, generation: generation, lastError: error)
                }
            default:
                break
            }
        }
        self.listener = listener
        listenerIsReady = false
        listener.start(queue: queue)
    }

    private func cancelListener() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        listenerIsReady = false
    }

    private func accept(_ nwConnection: NWConnection) {
        let connection = HTTPConnection(nwConnection, context: context) { [weak self] id in
            guard let self else { return }
            self.queue.async { self.connections[id] = nil }
        }
        connections[ObjectIdentifier(connection)] = connection
        connection.start()
    }

    private static func makeParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        // Drop connections to phones that left the network without closing them.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        let parameters = NWParameters(tls: nil, tcp: tcp)
        // Rebinding right after a relaunch must not trip over TIME_WAIT; a live listener on the
        // port is still detected (EADDRINUSE).
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    private static func describe(_ error: NWError) -> String {
        if case .posix(.EADDRINUSE) = error {
            return "Every sharing port is in use by another app."
        }
        return "Couldn’t start sharing: \(error.debugDescription)"
    }
}
