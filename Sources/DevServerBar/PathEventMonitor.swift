import CoreServices
import Foundation

final class PathEventMonitor {
    private let paths: [String]
    private let latency: CFTimeInterval
    private let queue = DispatchQueue(
        label: "NotchAgents.PathEventMonitor",
        qos: .utility
    )
    private let callback: @Sendable () -> Void

    private var stream: FSEventStreamRef?

    init(
        paths: [String],
        latency: CFTimeInterval = 0.5,
        callback: @escaping @Sendable () -> Void
    ) {
        self.paths = Array(
            Set(paths.filter { FileManager.default.fileExists(atPath: $0) })
        ).sorted()
        self.latency = latency
        self.callback = callback
    }

    func start() {
        guard stream == nil, !paths.isEmpty else {
            return
        }

        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )

        let stream = FSEventStreamCreate(
            nil,
            { _, info, _, _, _, _ in
                guard let info else {
                    return
                }

                let monitor = Unmanaged<PathEventMonitor>
                    .fromOpaque(info)
                    .takeUnretainedValue()
                monitor.callback()
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        )

        guard let stream else {
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)

        guard FSEventStreamStart(stream) else {
            stop()
            return
        }
    }

    func stop() {
        guard let stream else {
            return
        }

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}
