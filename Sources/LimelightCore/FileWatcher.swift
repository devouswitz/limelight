import CoreServices
import Foundation

/// FSEvents stream over a set of folders. Reports changed paths in batches.
public final class FileWatcher {
    public struct Change {
        public let path: String
        /// The kernel dropped events or coalesced them; the whole subtree must be re-read.
        public let mustRescanSubtree: Bool
    }

    private var stream: FSEventStreamRef?
    private let handler: ([Change]) -> Void
    private let queue = DispatchQueue(label: "limelight.fsevents", qos: .utility)

    public init?(paths: [String], excluding excluded: [String] = [], latency: TimeInterval = 0.5, handler: @escaping ([Change]) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, FileWatcher.callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else { return nil }
        self.stream = stream
        if !excluded.isEmpty {
            FSEventStreamSetExclusionPaths(stream, Array(excluded.prefix(8)) as CFArray)
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit { stop() }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
        let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
        let rescanMask = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
        )
        var changes: [Change] = []
        changes.reserveCapacity(count)
        for i in 0..<min(count, list.count) {
            changes.append(Change(path: list[i], mustRescanSubtree: flags[i] & rescanMask != 0))
        }
        watcher.handler(changes)
    }
}
