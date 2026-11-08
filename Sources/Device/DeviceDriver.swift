import Foundation

/// Low-level device access: MTP (libmtp), ADB or a test device.
/// All methods are called only from the serial `DeviceService` queue.
protocol DeviceDriver: AnyObject {
    var transport: Transport { get }

    /// Open the device (if not open yet) and return its info.
    /// `.notConnected` — no device; `.busy` / `.locked` — it's there but not available yet.
    func connectIfNeeded() throws -> DeviceInfo
    func release()

    func list(storage: UInt32, parent: UInt32) throws -> [RemoteItem]

    /// Download a file. `offset > 0` — append to the part already downloaded (if the driver can).
    func download(_ item: RemoteItem, to url: URL, offset: UInt64,
                  progress: @escaping (UInt64, UInt64) -> Bool) throws
    var supportsPartialDownload: Bool { get }

    @discardableResult
    func upload(_ url: URL, parent: UInt32, storage: UInt32,
                progress: @escaping (UInt64, UInt64) -> Bool) throws -> UInt32

    func createFolder(_ name: String, parent: UInt32, storage: UInt32) throws -> UInt32
    func delete(_ id: UInt32) throws
    func rename(_ id: UInt32, to name: String) throws

    /// A small preview (JPEG), if the device can provide one.
    func thumbnail(_ item: RemoteItem) -> Data?

    // Verification: the more precise the driver, the more reliable the check.
    /// Object size on the device — after upload we compare it with the file on the Mac.
    func remoteSize(_ id: UInt32) -> UInt64?
    /// A chunk of a file from the device — we compare content samples.
    func readRange(_ item: RemoteItem, offset: UInt64, length: UInt32) -> Data?
    /// SHA-256 of a file, computed on the device itself (ADB).
    func sha256(_ item: RemoteItem) -> String?
}

extension DeviceDriver {
    var supportsPartialDownload: Bool { false }
    func thumbnail(_ item: RemoteItem) -> Data? { nil }
    func remoteSize(_ id: UInt32) -> UInt64? { nil }
    func readRange(_ item: RemoteItem, offset: UInt64, length: UInt32) -> Data? { nil }
    func sha256(_ item: RemoteItem) -> String? { nil }
}
