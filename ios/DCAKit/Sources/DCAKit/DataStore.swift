import Foundation

/// 本機投資資料的保存介面。資料只存在手機，不上傳、不做 iCloud 備份（docs/04、docs/10）。
public protocol DataStore: AnyObject {
    func load() throws -> AppData
    func save(_ data: AppData) throws
    /// 「清除所有資料並重新開始」用
    func wipe() throws
}

public final class InMemoryDataStore: DataStore {
    public private(set) var saved: AppData?
    public private(set) var saveCount = 0
    public init(_ initial: AppData? = nil) { saved = initial }
    public func load() throws -> AppData { saved ?? AppData() }
    public func save(_ data: AppData) throws {
        saved = data
        saveCount += 1
    }
    public func wipe() throws { saved = nil }
}

public enum DataStoreError: Error, Equatable {
    case newerSchema(Int)
}

/// 以單一 JSON 檔保存（原子寫入）。
/// iOS 上設定 `completeFileProtection`（手機鎖定時無法讀取）並排除在裝置備份之外。
/// 個人投資紀錄筆數有限（數千筆），單檔 JSON 足以應付；之後若有需要再換 SQLite。
public final class JSONFileDataStore: DataStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static func defaultURL() throws -> URL {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
        return dir.appendingPathComponent("portfolio-data.json")
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public func load() throws -> AppData {
        guard FileManager.default.fileExists(atPath: url.path) else { return AppData() }
        let data = try Data(contentsOf: url)
        let decoded = try Self.decoder().decode(AppData.self, from: data)
        if decoded.schemaVersion > AppData.currentSchemaVersion {
            throw DataStoreError.newerSchema(decoded.schemaVersion)
        }
        return decoded
    }

    public func save(_ data: AppData) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = try Self.encoder().encode(data)
        #if os(iOS)
        try bytes.write(to: url, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var u = url
        try u.setResourceValues(values)
        #else
        try bytes.write(to: url, options: [.atomic])
        #endif
    }

    public func wipe() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
