import CommonCrypto
import Foundation
import SQLite3

enum LoadError: Error {
    case databaseMissing
    case noSession
    case keychainDenied
    case keychainMissing
    case decryptFailed
    case unauthorized
    case network(String)
}

struct UsageSnapshot: Equatable, Codable {
    var planLabel: String
    var cursorModelsPercent: Double?
    var otherModelsPercent: Double?
    var grokPercent: Double?
    var grokReset: Date?
    var periodEnd: Date?
    var fetchedAt: Date
    var grokUnavailableReason: String?
}

enum UsageText {
    static func menuTitle(_ snapshot: UsageSnapshot) -> String {
        let cursor = snapshot.cursorModelsPercent.map { "C \(Int($0.rounded()))%" }
        let grok = snapshot.grokPercent.map { "G \(Int($0.rounded()))%" }
        let parts = [cursor, grok].compactMap { $0 }
        return parts.isEmpty ? "Cursor" : parts.joined(separator: "  ")
    }

    static func percent(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if abs(rounded - rounded.rounded()) < 0.05 {
            return "\(Int(rounded.rounded())) %"
        }
        return String(format: "%.1f %%", rounded)
    }

    static func planLabel(_ raw: String?) -> String {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pro": return "Pro"
        case "pro_plus", "pro+": return "Pro+"
        case "ultra": return "Ultra"
        case "free", "free_trial": return "Free"
        case "enterprise", "business", "team": return "Enterprise"
        case let other?:
            return other.isEmpty ? "Cursor" : other.replacingOccurrences(of: "_", with: " ").capitalized
        default:
            return "Cursor"
        }
    }

    static func resetLine(at date: Date, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMM"
        let day = formatter.string(from: date).replacingOccurrences(of: ".", with: "")
        let remaining = date.timeIntervalSince(now)
        if remaining <= 0 {
            return "Сброс \(day). Счётчик уже должен обновиться"
        }
        return "Сброс \(day). (\(remainingPhrase(remaining)))"
    }

    static func remainingPhrase(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        if minutes < 1 { return "Осталось меньше минуты" }
        if minutes < 60 {
            return counted(minutes, one: "Осталась", few: "минуты", many: "минут", nounOne: "минута")
        }
        let hours = minutes / 60
        if hours < 48 {
            return counted(hours, one: "Остался", few: "часа", many: "часов", nounOne: "час")
        }
        let days = hours / 24
        return counted(days, one: "Остался", few: "дня", many: "дней", nounOne: "день")
    }

    static func message(for error: Error) -> String {
        guard let error = error as? LoadError else {
            return "Не получилось обновить лимиты"
        }
        switch error {
        case .databaseMissing:
            return "Не найден локальный вход Cursor"
        case .noSession:
            return "В Cursor нет сохранённой сессии. Войдите в аккаунт"
        case .keychainDenied:
            return "Нужен доступ к связке ключей «Cursor Safe Storage». Нажмите «Обновить» и разрешите его"
        case .keychainMissing:
            return "В связке ключей нет ключа Cursor Safe Storage. Откройте Cursor и войдите ещё раз"
        case .decryptFailed:
            return "Сессия Cursor не расшифровалась"
        case .unauthorized:
            return "Сессия Cursor не принята. Войдите в аккаунт ещё раз"
        case .network(let detail):
            return detail
        }
    }

    private static func counted(_ n: Int, one verb: String, few: String, many: String, nounOne: String) -> String {
        let mod10 = abs(n) % 10
        let mod100 = abs(n) % 100
        if mod10 == 1 && mod100 != 11 { return "\(verb) \(n) \(nounOne)" }
        let noun = ru(n, one: nounOne, few: few, many: many)
        return "Осталось \(n) \(noun)"
    }

    private static func ru(_ n: Int, one: String, few: String, many: String) -> String {
        let n = abs(n) % 100
        let n1 = n % 10
        if n > 10 && n < 20 { return many }
        if n1 == 1 { return one }
        if (2...4).contains(n1) { return few }
        return many
    }
}

enum SafeStorage {
    private static let envelope = "cursor-safe-storage:v1:"

    static func open(stored: String, password: Data) -> String? {
        guard stored.hasPrefix(envelope) else {
            let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let blob = Data(base64Encoded: String(stored.dropFirst(envelope.count))),
              blob.count > 3,
              blob.prefix(3) == Data("v10".utf8) else {
            return nil
        }
        for candidate in passwordCandidates(password) {
            if let text = decryptV10(ciphertext: blob.dropFirst(3), password: candidate) {
                return text
            }
        }
        return nil
    }

    private static func passwordCandidates(_ password: Data) -> [Data] {
        var list = [password]
        if password.last == 0, password.count > 1 {
            list.append(password.dropLast())
        }
        return list
    }

    private static func decryptV10(ciphertext: Data, password: Data) -> String? {
        guard let plain = crypt(ciphertext, password: password, operation: CCOperation(kCCDecrypt)) else {
            return nil
        }
        guard let text = String(data: plain, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        return text
    }

    private static func crypt(_ input: Data, password: Data, operation: CCOperation) -> Data? {
        let key = deriveKey(password)
        let iv = Data(repeating: 0x20, count: 16)
        let outputCount = input.count + kCCBlockSizeAES128
        var output = Data(count: outputCount)
        var moved = 0
        let status: CCCryptorStatus = output.withUnsafeMutableBytes { outRaw in
            input.withUnsafeBytes { inRaw in
                key.withUnsafeBytes { keyRaw in
                    iv.withUnsafeBytes { ivRaw in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyRaw.baseAddress, key.count,
                            ivRaw.baseAddress,
                            inRaw.baseAddress, input.count,
                            outRaw.baseAddress, outputCount,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return output.prefix(moved)
    }

    private static func deriveKey(_ password: Data) -> Data {
        let salt = Array("saltysalt".utf8)
        var key = Data(count: 16)
        _ = key.withUnsafeMutableBytes { keyRaw in
            password.withUnsafeBytes { passwordRaw in
                salt.withUnsafeBytes { saltRaw in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordRaw.bindMemory(to: Int8.self).baseAddress,
                        password.count,
                        saltRaw.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyRaw.bindMemory(to: UInt8.self).baseAddress,
                        16
                    )
                }
            }
        }
        return key
    }
}

enum KeychainPassword {
    static func cursorSafeStorage() throws -> Data {
        let attempts: [(String, String?)] = [
            ("Cursor Safe Storage", "Cursor Key"),
            ("Cursor Safe Storage", "Cursor"),
            ("Cursor Safe Storage", nil),
        ]
        var sawMissing = true
        for (service, account) in attempts {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            if let account {
                query[kSecAttrAccount as String] = account
            }
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data, !data.isEmpty {
                return data
            }
            if status == errSecUserCanceled || status == errSecAuthFailed || status == errSecInteractionNotAllowed {
                throw LoadError.keychainDenied
            }
            sawMissing = sawMissing && (status == errSecItemNotFound || status == errSecSuccess)
        }
        throw sawMissing ? LoadError.keychainMissing : LoadError.keychainDenied
    }
}

enum CursorDatabase {
    static var stateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    static func value(for key: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            throw LoadError.databaseMissing
        }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(stateURL.path, &db, flags, nil) == SQLITE_OK else {
            throw LoadError.databaseMissing
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        var statement: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw LoadError.databaseMissing
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, key, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else {
            return nil
        }
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }
}

enum JSONValue {
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func field(_ object: [String: Any], _ names: String...) -> Any? {
        for name in names {
            if let value = object[name] { return value }
        }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let string as String:
            return Double(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            return number.doubleValue
        default:
            return nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    static func string(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func date(_ value: Any?) -> Date? {
        if let string = value as? String {
            if let date = isoDate(string) { return date }
            if let number = Double(string) { return unixDate(number) }
        }
        if let number = double(value) { return unixDate(number) }
        if let object = value as? [String: Any] {
            let seconds = double(field(object, "seconds")) ?? 0
            let nanos = double(field(object, "nanos")) ?? 0
            if seconds == 0 && nanos == 0 { return nil }
            return Date(timeIntervalSince1970: seconds + nanos / 1_000_000_000)
        }
        return nil
    }

    private static func unixDate(_ value: Double) -> Date {
        if value > 100_000_000_000 { return Date(timeIntervalSince1970: value / 1000) }
        return Date(timeIntervalSince1970: value)
    }

    private static func isoDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

enum UsageCache {
    static var fileURL: URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor Usage", isDirectory: true)
        return directory.appendingPathComponent("latest.json")
    }

    static func load() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UsageSnapshot.self, from: data)
    }

    static func save(_ snapshot: UsageSnapshot) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

enum CursorSession {
    private static let clientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"
    private static var cachedAccess: String?
    private static var cachedExpiry: Date?

    static func snapshot() async throws -> UsageSnapshot {
        let token = try await validAccessToken(forceRefresh: false)
        do {
            return try await fetch(token: token)
        } catch LoadError.unauthorized {
            self.cachedAccess = nil
            self.cachedExpiry = nil
            return try await fetch(token: try await validAccessToken(forceRefresh: true))
        }
    }

    private static func validAccessToken(forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let cachedAccess, let cachedExpiry, cachedExpiry.timeIntervalSinceNow > 120 {
            return cachedAccess
        }
        guard let storedAccess = try CursorDatabase.value(for: "cursorAuth/accessToken") else {
            throw LoadError.noSession
        }
        let password = try KeychainPassword.cursorSafeStorage()
        guard let access = SafeStorage.open(stored: storedAccess, password: password) else {
            throw LoadError.decryptFailed
        }
        let storedRefresh = try CursorDatabase.value(for: "cursorAuth/refreshToken") ?? storedAccess
        let refresh = SafeStorage.open(stored: storedRefresh, password: password) ?? access
        let expiry = jwtExpiry(access)
        let stale = forceRefresh || expiry == nil || (expiry?.timeIntervalSinceNow ?? 0) < 120
        var current = access
        if stale {
            do {
                current = try await refreshAccess(refresh)
            } catch {
                if forceRefresh || expiry == nil || (expiry?.timeIntervalSinceNow ?? 0) <= 0 {
                    throw error
                }
            }
        }
        cachedAccess = current
        cachedExpiry = jwtExpiry(current) ?? Date().addingTimeInterval(30 * 60)
        return current
    }

    private static func refreshAccess(_ refreshToken: String) async throws -> String {
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refreshToken,
        ]
        let (status, data) = try await post(
            url: URL(string: "https://api2.cursor.sh/oauth/token")!,
            body: try JSONSerialization.data(withJSONObject: body),
            headers: ["Content-Type": "application/json"]
        )
        let object = JSONValue.object(data) ?? [:]
        if JSONValue.bool(object["shouldLogout"]) == true || status == 401 || status == 400 {
            throw LoadError.unauthorized
        }
        guard (200..<300).contains(status),
              let token = JSONValue.string(object["access_token"]) else {
            throw LoadError.unauthorized
        }
        return token
    }

    private static func fetch(token: String) async throws -> UsageSnapshot {
        async let periodData = dashboard("GetCurrentPeriodUsage", token: token)
        async let sandData = dashboard("GetSandUsageStatus", token: token)
        let period = try await periodData
        let sand = try await sandData
        let planUsage = JSONValue.field(period, "planUsage", "plan_usage") as? [String: Any] ?? [:]
        let membership = try? CursorDatabase.value(for: "cursorAuth/stripeMembershipType")
        let plan = JSONValue.string(JSONValue.field(sand, "cursorPlanName", "cursor_plan_name")) ?? membership
        let includedZero = JSONValue.bool(JSONValue.field(sand, "includedLimitZero", "included_limit_zero")) == true
        let hasLimit = JSONValue.bool(JSONValue.field(sand, "hasNonZeroIncludedLimit", "has_non_zero_included_limit"))
        let grok: Double?
        let grokReason: String?
        if includedZero || hasLimit == false {
            grok = nil
            grokReason = "Отдельный недельный лимит не включён"
        } else {
            grok = JSONValue.double(JSONValue.field(sand, "usagePercent", "usage_percent"))
            grokReason = nil
        }
        return UsageSnapshot(
            planLabel: UsageText.planLabel(plan),
            cursorModelsPercent: JSONValue.double(JSONValue.field(planUsage, "autoPercentUsed", "auto_percent_used")),
            otherModelsPercent: JSONValue.double(JSONValue.field(planUsage, "apiPercentUsed", "api_percent_used")),
            grokPercent: grok,
            grokReset: JSONValue.date(JSONValue.field(sand, "nextResetTimestampUtc", "next_reset_timestamp_utc")),
            periodEnd: JSONValue.date(JSONValue.field(period, "billingCycleEnd", "billing_cycle_end")),
            fetchedAt: Date(),
            grokUnavailableReason: grokReason
        )
    }

    private static func dashboard(_ method: String, token: String) async throws -> [String: Any] {
        var headers = [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json",
            "Connect-Protocol-Version": "1",
            "x-cursor-client-version": cursorVersion(),
            "x-cursor-client-type": "ide",
        ]
        if let checksum = cursorChecksum() {
            headers["x-cursor-checksum"] = checksum
        }
        let (status, data) = try await post(
            url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/\(method)")!,
            body: Data("{}".utf8),
            headers: headers
        )
        if status == 401 || status == 403 { throw LoadError.unauthorized }
        guard (200..<300).contains(status), let object = JSONValue.object(data) else {
            throw LoadError.network("сервер лимитов ответил \(status)")
        }
        return object
    }

    private static func post(url: URL, body: Data, headers: [String: String]) async throws -> (Int, Data) {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = body
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch {
            throw LoadError.network("нет соединения с Cursor")
        }
    }

    private static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = JSONValue.object(data),
              let exp = JSONValue.double(object["exp"]) else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    private static func cursorVersion() -> String {
        let url = URL(fileURLWithPath: "/Applications/Cursor.app/Contents/Info.plist")
        let version = NSDictionary(contentsOf: url)?["CFBundleShortVersionString"] as? String
        return version ?? "0"
    }

    private static func cursorChecksum() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/storage.json")
        guard let data = try? Data(contentsOf: url),
              let object = JSONValue.object(data),
              let machineID = JSONValue.string(object["telemetry.machineId"]) else {
            return nil
        }
        let macMachineID = JSONValue.string(object["telemetry.macMachineId"])
        let stamp = UInt64(Date().timeIntervalSince1970 * 1000) / 1_000_000
        var bytes = (0..<6).map { shift in UInt8((stamp >> ((5 - shift) * 8)) & 0xff) }
        var rolling: UInt8 = 165
        for index in bytes.indices {
            let mixed = Int(bytes[index] ^ rolling) + (index % 256)
            bytes[index] = UInt8(mixed & 0xff)
            rolling = bytes[index]
        }
        let encoded = Data(bytes).base64EncodedString()
        if let macMachineID {
            return "\(encoded)\(machineID)/\(macMachineID)"
        }
        return "\(encoded)\(machineID)"
    }
}

enum UsageSelfTest {
    static func run() -> Bool {
        let stored = "cursor-safe-storage:v1:djEwZm8loLEB3PK5HQbjleQJ41tTclGeHdMhzq00QQ1M0z4="
        let opened = SafeStorage.open(stored: stored, password: Data("peanut-butter".utf8))
        guard opened == "eyJhbGciOiJub25lIn0.e30.sig" else {
            FileHandle.standardError.write(Data("decrypt vector failed\n".utf8))
            return false
        }
        guard UsageText.percent(4) == "4 %", UsageText.percent(68.4) == "68.4 %" else {
            FileHandle.standardError.write(Data("percent format failed\n".utf8))
            return false
        }
        let reset = UsageText.remainingPhrase(4 * 60)
        guard reset == "Осталось 4 минуты" else {
            FileHandle.standardError.write(Data("plural failed: \(reset)\n".utf8))
            return false
        }
        let iso = JSONValue.date("2026-11-02T10:17:00Z")
        let millis = JSONValue.date(1_762_000_000_000 as NSNumber)
        let secondsObject = JSONValue.date(["seconds": "1762000000", "nanos": 0])
        guard iso != nil, millis != nil, secondsObject != nil else {
            FileHandle.standardError.write(Data("date parse failed\n".utf8))
            return false
        }
        return true
    }
}
