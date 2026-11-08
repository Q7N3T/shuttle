import Foundation

/// Низкоуровневый доступ к устройству: MTP (libmtp), ADB или тестовое устройство.
/// Все методы вызываются только с последовательной очереди `DeviceService`.
protocol DeviceDriver: AnyObject {
    var transport: Transport { get }

    /// Открыть устройство (если ещё не открыто) и вернуть сведения о нём.
    /// `.notConnected` — устройства нет; `.busy` / `.locked` — есть, но пока недоступно.
    func connectIfNeeded() throws -> DeviceInfo
    func release()

    func list(storage: UInt32, parent: UInt32) throws -> [RemoteItem]

    /// Скачать файл. `offset > 0` — дописать к уже скачанной части (если драйвер умеет).
    func download(_ item: RemoteItem, to url: URL, offset: UInt64,
                  progress: @escaping (UInt64, UInt64) -> Bool) throws
    var supportsPartialDownload: Bool { get }

    @discardableResult
    func upload(_ url: URL, parent: UInt32, storage: UInt32,
                progress: @escaping (UInt64, UInt64) -> Bool) throws -> UInt32

    func createFolder(_ name: String, parent: UInt32, storage: UInt32) throws -> UInt32
    func delete(_ id: UInt32) throws
    func rename(_ id: UInt32, to name: String) throws

    /// Маленькое превью (JPEG), если устройство умеет его отдавать.
    func thumbnail(_ item: RemoteItem) -> Data?

    // Сверка: чем точнее умеет драйвер, тем надёжнее проверка.
    /// Размер объекта на устройстве — после загрузки сравниваем с файлом на Mac.
    func remoteSize(_ id: UInt32) -> UInt64?
    /// Кусок файла с устройства — сравниваем пробы содержимого.
    func readRange(_ item: RemoteItem, offset: UInt64, length: UInt32) -> Data?
    /// SHA-256 файла, посчитанный на самом устройстве (ADB).
    func sha256(_ item: RemoteItem) -> String?
}

extension DeviceDriver {
    var supportsPartialDownload: Bool { false }
    func thumbnail(_ item: RemoteItem) -> Data? { nil }
    func remoteSize(_ id: UInt32) -> UInt64? { nil }
    func readRange(_ item: RemoteItem, offset: UInt64, length: UInt32) -> Data? { nil }
    func sha256(_ item: RemoteItem) -> String? { nil }
}
