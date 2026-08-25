import Foundation

/// Samples this process's resident size while a scenario runs and remembers
/// the peak. The ceilings in `main.swift` were calibrated against a release
/// build on Apple silicon and exist to catch growth, not to benchmark.
final class MemoryWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var baseline: UInt64 = 0
    private var task: Task<Void, Never>?

    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    private func note(_ bytes: UInt64) {
        lock.lock()
        if bytes > peak { peak = bytes }
        lock.unlock()
    }

    func start() {
        baseline = Self.residentBytes()
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.note(Self.residentBytes())
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Stops sampling and returns the peak *growth* over the baseline taken
    /// at `start()`, in bytes. Growth, not absolute: `all` runs scenarios in
    /// one process and malloc does not hand pages back, so an absolute
    /// ceiling would bill each scenario for its predecessors.
    func stop() -> UInt64 {
        task?.cancel()
        task = nil
        lock.lock()
        defer { lock.unlock() }
        if peak == 0 { peak = Self.residentBytes() }
        return peak > baseline ? peak - baseline : 0
    }
}
