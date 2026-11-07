import AppKit
import SwiftUI
import Security
import ServiceManagement
import UserNotifications
import SystemConfiguration
import LocalAuthentication

let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AWSUsageMonitor")
let keyService = "io.github.kamona25.aws-credit-menubar.credentials"
let keyAccount = "credit-reader"
try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

struct Settings: Codable {
    let accountID: String
    let region: String
    let cliPath: String
    let traffic: TrafficSettings?
    let payerAccount: Bool?
}
struct TrafficSettings: Codable { let instanceName: String; let region: String; let roleARN: String? }
struct Credentials: Codable { let accessKeyID: String; let secretAccessKey: String; var sessionToken: String? = nil }
enum CredentialStore {
    static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keyService, kSecAttrAccount as String: keyAccount] }
    static func save(_ data: Data) throws {
        _ = try JSONDecoder().decode(Credentials.self, from: data)
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrLabel as String] = "AWS 余量 · 只读查询密钥"
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        q[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw AppError.message("钥匙串写入失败（\(status)）；未覆盖已有密钥。") }
    }
    static func read(allowInteraction: Bool = false) throws -> Credentials {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = !allowInteraction
        q[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw AppError.message(status == errSecItemNotFound ? "尚未配置查询密钥" : "钥匙串暂不可用，请解锁 Mac 后刷新（\(status)）")
        }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }
}
enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
struct Money: Codable {
    let currencyCode: String
    let currencyAmount: String
    var decimal: Decimal? { Decimal(string: currencyAmount, locale: Locale(identifier: "en_US_POSIX")) }
}
func awsDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    let f = ISO8601DateFormatter()
    if let date = f.date(from: value) { return date }
    f.formatOptions.insert(.withFractionalSeconds)
    return f.date(from: value)
}
struct Credit: Codable, Identifiable {
    let creditId: String
    let description: String
    let initialAmount: Money
    let remainingAmount: Money
    let estimatedAmount: Money?
    let startDate: String
    let endDate: String?
    let creditStatus: String?
    var id: String { creditId }
    var expiry: Date? { awsDate(endDate) }
    func active(at date: Date) -> Bool {
        creditStatus == "ENABLED" && (expiry == nil || expiry! > date) && (awsDate(startDate) ?? .distantPast) <= date
    }
}
struct Snapshot: Codable { let credits: [Credit]; let fetchedAt: Date }
func utcMonth(_ date: Date) -> Date {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
    return cal.date(from: cal.dateComponents([.year, .month], from: date))!
}
let bytesPerGB = 1_073_741_824.0
func trafficGB(_ bytes: Double) -> String {
    (bytes / bytesPerGB).formatted(.number.precision(.fractionLength(2))) + " GB"
}
struct TrafficSnapshot: Codable {
    let instanceName: String
    let instanceARN: String
    let monthStart: Date
    let fetchedAt: Date
    let measuredThrough: Date
    let incoming: Double
    let outgoing: Double
    let allowanceGB: Double
    let incomplete: Bool
    var used: Double { incoming + outgoing }
    var limit: Double { allowanceGB * bytesPerGB }
    var remaining: Double { max(0, limit - used) }
    var ratio: Double { limit > 0 ? used / limit : 0 }
}
func money(_ value: Decimal) -> String {
    let f = NumberFormatter(); f.numberStyle = .decimal
    f.minimumFractionDigits = 2; f.maximumFractionDigits = 2
    f.locale = Locale(identifier: "en_US")
    return f.string(from: NSDecimalNumber(decimal: value)) ?? "—"
}
func compactMoney(_ value: Decimal) -> String {
    let f = NumberFormatter(); f.numberStyle = .decimal
    f.minimumFractionDigits = 0; f.maximumFractionDigits = 2
    f.locale = Locale(identifier: "en_US")
    return f.string(from: NSDecimalNumber(decimal: value)) ?? "—"
}
func compactTraffic(_ bytes: Double) -> String {
    let gb = bytes / bytesPerGB
    if gb >= 1024 { return (gb / 1024).formatted(.number.precision(.fractionLength(2))) + " TB" }
    if gb >= 1 { return gb.formatted(.number.precision(.fractionLength(1))) + " GB" }
    return (gb * 1024).formatted(.number.precision(.fractionLength(0))) + " MB"
}

enum BillingReader {
    static func run(_ config: Settings, _ arguments: [String], region: String, credentials: Credentials) throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: config.cliPath) else { throw AppError.message("找不到 AWS 命令行工具") }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: config.cliPath)
        process.arguments = arguments + ["--region", region,
            "--output", "json", "--no-cli-pager", "--no-cli-auto-prompt", "--cli-connect-timeout", "12", "--cli-read-timeout", "20",
            "--color", "off"]
        var env = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "TZ": "UTC",
            "AWS_ACCESS_KEY_ID": credentials.accessKeyID, "AWS_SECRET_ACCESS_KEY": credentials.secretAccessKey,
            "AWS_CONFIG_FILE": "/dev/null", "AWS_SHARED_CREDENTIALS_FILE": "/dev/null", "AWS_EC2_METADATA_DISABLED": "true",
            "AWS_MAX_ATTEMPTS": "1", "AWS_PAGER": "", "AWS_CLI_AUTO_PROMPT": "off"]
        if let token = credentials.sessionToken { env["AWS_SESSION_TOKEN"] = token }
        // Observe macOS proxy configuration only; never probe or control a proxy application.
        if let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any] {
            for (enable, host, port, name) in [("HTTPEnable", "HTTPProxy", "HTTPPort", "HTTP_PROXY"), ("HTTPSEnable", "HTTPSProxy", "HTTPSPort", "HTTPS_PROXY")] {
                if (proxies[enable] as? NSNumber)?.boolValue == true, let h = proxies[host] as? String, let p = proxies[port] as? NSNumber {
                    env[name] = "http://\(h):\(p)"
                }
            }
            if let bypass = proxies["ExceptionsList"] as? [String] { env["NO_PROXY"] = bypass.joined(separator: ",") }
        }
        process.environment = env
        process.standardOutput = pipe; process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); timeout.cancel()
        guard process.terminationStatus == 0 else {
            let message = String(data: data, encoding: .utf8) ?? ""
            if message.contains("AccessDenied") { throw AppError.message("AWS 拒绝读取，请检查专用只读身份权限") }
            if message.contains("InvalidClientTokenId") || message.contains("SignatureDoesNotMatch") { throw AppError.message("查询密钥无效或已停用") }
            throw AppError.message("暂时无法连接 AWS，已保留上次数据")
        }
        return data
    }
    static func fetch(_ config: Settings) throws -> [Credit] {
        let credentials = try CredentialStore.read()
        let data = try run(config, ["billing", "get-credits", "--account-id", config.accountID,
            config.payerAccount == true ? "--payer-account-flag" : "--no-payer-account-flag", "--start-date", ISO8601DateFormatter().string(from: utcMonth(Date())),
            "--query", "credits[].{creditId:creditId,description:description,initialAmount:initialAmount,remainingAmount:remainingAmount,estimatedAmount:estimatedAmount,startDate:startDate,endDate:endDate,creditStatus:creditStatus}"], region: config.region, credentials: credentials)
        guard let credits = try? JSONDecoder().decode([Credit].self, from: data) else { throw AppError.message("AWS 返回的数据格式异常，已保留上次余额") }
        guard !credits.isEmpty else { throw AppError.message("AWS 未返回抵扣金，请打开账单核对；不会将空响应当作零余额") }
        guard credits.allSatisfy({ $0.initialAmount.decimal != nil && $0.remainingAmount.decimal != nil && ($0.estimatedAmount == nil || $0.estimatedAmount?.decimal != nil) && awsDate($0.startDate) != nil && ($0.endDate == nil || $0.expiry != nil) }) else {
            throw AppError.message("AWS 金额或日期数据不完整，已保留上次余额")
        }
        return credits
    }
    static func fetchTraffic(_ config: Settings) throws -> TrafficSnapshot {
        guard let traffic = config.traffic else { throw AppError.message("尚未配置 Lightsail 流量监控") }
        let base = try CredentialStore.read()
        var credentials = base
        if let roleARN = traffic.roleARN, !roleARN.isEmpty {
            let assumed = try run(config, ["sts", "assume-role", "--role-arn", roleARN,
                "--role-session-name", "AWSCreditTraffic", "--duration-seconds", "900", "--query", "Credentials"], region: traffic.region, credentials: base)
            struct Session: Decodable { let AccessKeyId: String; let SecretAccessKey: String; let SessionToken: String }
            let session = try JSONDecoder().decode(Session.self, from: assumed)
            credentials = Credentials(accessKeyID: session.AccessKeyId, secretAccessKey: session.SecretAccessKey, sessionToken: session.SessionToken)
        }
        let info = try run(config, ["lightsail", "get-instance", "--instance-name", traffic.instanceName,
            "--query", "instance.{arn:arn,name:name,createdAt:createdAt,allowanceGB:networking.monthlyTransfer.gbPerMonthAllocated}"], region: traffic.region, credentials: credentials)
        struct Instance: Decodable { let arn: String; let name: String; let createdAt: String; let allowanceGB: Double }
        let instance = try JSONDecoder().decode(Instance.self, from: info)
        guard instance.allowanceGB > 0, instance.allowanceGB.isFinite, let created = awsDate(instance.createdAt) else { throw AppError.message("无法确认 Lightsail 实例的月流量额度") }
        let now = Date(), start = utcMonth(Date())
        let end = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 300) * 300)
        guard end > max(start, created) else { throw AppError.message("本月监控数据尚未生成，稍后自动刷新") }
        struct Metric: Decodable { let sum: Double?; let timestamp: String; let unit: String? }
        var totals = [Double](), points = [Set<Int>](), through = [Date]()
        let iso = ISO8601DateFormatter()
        for name in ["NetworkIn", "NetworkOut"] {
            let data = try run(config, ["lightsail", "get-instance-metric-data", "--instance-name", traffic.instanceName,
                "--metric-name", name, "--period", "3600", "--start-time", iso.string(from: start), "--end-time", iso.string(from: end),
                "--unit", "Bytes", "--statistics", "Sum", "--query", "metricData"], region: traffic.region, credentials: credentials)
            let values = try JSONDecoder().decode([Metric].self, from: data)
            var hours = Set<Int>(), total = 0.0
            for point in values {
                guard let date = awsDate(point.timestamp), date >= start, date < end else { continue }
                guard let sum = point.sum, sum.isFinite, sum >= 0, point.unit == "Bytes" else { throw AppError.message("流量监控返回了不完整的计量值") }
                let hour = Int(date.timeIntervalSince1970 / 3600)
                if hours.insert(hour).inserted { total += sum }
            }
            guard let latest = hours.max() else { throw AppError.message("AWS 暂未返回流量监控，保留上次数据") }
            let until = min(end, Date(timeIntervalSince1970: Double(latest + 1) * 3600))
            guard end.timeIntervalSince(until) < 7200 else { throw AppError.message("AWS 流量监控延迟较大，保留上次数据") }
            totals.append(total); points.append(hours); through.append(until)
        }
        let firstHour = Int(max(start, created).timeIntervalSince1970 / 3600)
        let finalHour = Int(through.min()!.timeIntervalSince1970 / 3600)
        let expected = Set(firstHour..<max(firstHour, finalHour))
        let incomplete = !expected.isSubset(of: points[0]) || !expected.isSubset(of: points[1])
        return TrafficSnapshot(instanceName: instance.name, instanceARN: instance.arn, monthStart: start,
            fetchedAt: now, measuredThrough: through.min()!, incoming: totals[0], outgoing: totals[1], allowanceGB: instance.allowanceGB, incomplete: incomplete)
    }
}

@MainActor final class BalanceModel: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var trafficSnapshot: TrafficSnapshot?
    @Published var trafficError: String?
    @Published var keychainNeedsAuthorization = false
    @Published var refreshing = false
    @Published var error: String?
    @Published var nextRefresh: Date?
    @Published var nextBalanceRefresh: Date?
    @Published var nextTrafficRefresh: Date?
    @Published var loginEnabled = false
    @Published var loginNeedsApproval = false
    @Published var notificationsEnabled = false
    @Published var showDetails = false
    var updated: (() -> Void)?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var lastBalanceAttempt: Date?
    private var lastTrafficAttempt: Date?
    let config: Settings?
    var monitorsTraffic: Bool { config?.traffic != nil }
    let balanceRefreshInterval: TimeInterval = 24 * 60 * 60
    var trafficRefreshInterval: TimeInterval { (currentTraffic?.ratio ?? 0) >= 0.8 ? 5 * 60 : 10 * 60 }
    private var balanceDue: Date {
        max(snapshot?.fetchedAt ?? .distantPast, lastBalanceAttempt ?? .distantPast)
            .addingTimeInterval(error == nil ? balanceRefreshInterval : 60 * 60)
    }
    private var trafficDue: Date {
        max(currentTraffic?.fetchedAt ?? .distantPast, lastTrafficAttempt ?? .distantPast)
            .addingTimeInterval(trafficRefreshInterval)
    }
    init() {
        config = (try? Data(contentsOf: support.appendingPathComponent("config.json"))).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
        snapshot = (try? Data(contentsOf: support.appendingPathComponent("balance-cache.json"))).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
        trafficSnapshot = (try? Data(contentsOf: support.appendingPathComponent("traffic-cache.json"))).flatMap { try? JSONDecoder().decode(TrafficSnapshot.self, from: $0) }
    }
    var currentTraffic: TrafficSnapshot? { monitorsTraffic ? trafficSnapshot.flatMap { $0.monthStart == utcMonth(Date()) ? $0 : nil } : nil }
    var credits: [Credit] { snapshot?.credits.filter { $0.active(at: Date()) } ?? [] }
    var usdCredits: [Credit] { credits.filter { $0.remainingAmount.currencyCode == "USD" } }
    var isEstimated: Bool { !usdCredits.isEmpty && usdCredits.allSatisfy { $0.estimatedAmount?.currencyCode == "USD" && $0.estimatedAmount?.decimal != nil } }
    var balance: Decimal? {
        guard snapshot != nil else { return nil }
        guard !usdCredits.isEmpty else { return credits.isEmpty ? Decimal(0) : nil }
        return usdCredits.reduce(Decimal(0)) { $0 + (isEstimated ? $1.estimatedAmount!.decimal! : $1.remainingAmount.decimal!) }
    }
    var granted: Decimal { usdCredits.reduce(Decimal(0)) { $0 + ($1.initialAmount.decimal ?? 0) } }
    var fraction: Double {
        guard let balance, granted > 0 else { return 0 }
        return min(1, max(0, NSDecimalNumber(decimal: balance / granted).doubleValue))
    }
    var earliestExpiry: Date? { usdCredits.filter { ($0.estimatedAmount?.decimal ?? $0.remainingAmount.decimal ?? 0) > 0 }.compactMap(\.expiry).min() }
    var daysLeft: Int? { earliestExpiry.map { max(0, Calendar.current.dateComponents([.day], from: Date(), to: $0).day ?? 0) } }
    var stale: Bool { error != nil || (snapshot.map { Date().timeIntervalSince($0.fetchedAt) > balanceRefreshInterval + 300 } ?? true) }
    var trafficStale: Bool { monitorsTraffic && (trafficError != nil || (currentTraffic.map { Date().timeIntervalSince($0.fetchedAt) > trafficRefreshInterval + 180 } ?? true)) }
    var statusText: String {
        if refreshing { return "正在同步" }
        if error != nil || trafficError != nil { return "更新受阻" }
        if snapshot == nil { return "等待查询" }
        if stale || trafficStale { return "待更新" }
        return "已同步"
    }
    var balanceText: String { balance.map(money) ?? "—" }
    var menuTitle: String {
        let amount = balance.map { "$" + compactMoney($0) } ?? "$—"
        guard monitorsTraffic else { return amount + (error != nil ? " !" : "") }
        let remaining = currentTraffic.flatMap { $0.incomplete ? nil : compactTraffic($0.remaining) } ?? "—"
        return "\(amount) · \(remaining)\(error != nil || trafficError != nil ? " !" : "")"
    }
    func start() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "didConfigureLogin") {
            setLogin(true)
            defaults.set(true, forKey: "didConfigureLogin")
        } else { updateLoginState() }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in self.readNotificationState() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                self.refresh(force: false)
            }
        }
        refresh(force: false)
    }
    func refresh(force: Bool = true) {
        guard !refreshing else { return }
        guard let config else { error = "尚未配置账户，请按 README 完成首次设置"; updated?(); writeStatus(); return }
        let now = Date()
        let queryBalance = force || now >= balanceDue
        let queryTraffic = monitorsTraffic && (force || now >= trafficDue)
        guard queryBalance || queryTraffic else { scheduleNext(); updated?(); writeStatus(); return }
        refreshing = true
        if queryBalance { lastBalanceAttempt = now }
        if queryTraffic { lastTrafficAttempt = now }
        updated?()
        DispatchQueue.global(qos: .utility).async {
            let result: Result<[Credit], Error>? = queryBalance ? Result { try BillingReader.fetch(config) } : nil
            let trafficResult: Result<TrafficSnapshot, Error>? = queryTraffic ? Result { try BillingReader.fetchTraffic(config) } : nil
            DispatchQueue.main.async {
                self.refreshing = false
                if let result {
                switch result {
                case .success(let credits):
                    let value = Snapshot(credits: credits, fetchedAt: Date())
                    withAnimation(.easeInOut(duration: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.28)) { self.snapshot = value; self.error = nil }
                    if let data = try? JSONEncoder().encode(value) { try? data.write(to: support.appendingPathComponent("balance-cache.json"), options: [.atomic, .completeFileProtectionUnlessOpen]) }
                    self.sendThresholdNotifications()
                case .failure(let failure): self.error = failure.localizedDescription
                }
                }
                if let trafficResult {
                switch trafficResult {
                case .success(let value):
                    withAnimation(.easeInOut(duration: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.28)) { self.trafficSnapshot = value; self.trafficError = nil }
                    if let data = try? JSONEncoder().encode(value) { try? data.write(to: support.appendingPathComponent("traffic-cache.json"), options: .atomic) }
                    self.sendTrafficNotifications()
                case .failure(let failure): self.trafficError = failure.localizedDescription
                }
                }
                self.keychainNeedsAuthorization = (self.error?.contains("钥匙串") == true || self.trafficError?.contains("钥匙串") == true)
                self.scheduleNext(); self.updated?(); self.writeStatus()
            }
        }
    }
    func authorizeKeychain() {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try CredentialStore.read(allowInteraction: true) }
            DispatchQueue.main.async {
                switch result {
                case .success: self.keychainNeedsAuthorization = false; self.refresh()
                case .failure: self.error = "钥匙串授权未完成，请使用本机系统提示授权"
                }
            }
        }
    }
    private func scheduleNext() {
        timer?.invalidate()
        nextBalanceRefresh = balanceDue
        nextTrafficRefresh = monitorsTraffic ? trafficDue : nil
        nextRefresh = monitorsTraffic ? min(balanceDue, trafficDue) : balanceDue
        let delay = max(1, nextRefresh!.timeIntervalSinceNow)
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in Task { @MainActor in self.refresh(force: false) } }
        timer?.tolerance = min(15, delay / 10)
    }
    func updateLoginState() {
        loginEnabled = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
        writeStatus()
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { self.error = "登录项设置未完成，请在系统设置中确认" }
        updateLoginState()
    }
    func readNotificationState() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in self.notificationsEnabled = settings.authorizationStatus == .authorized; self.writeStatus() }
        }
    }
    private func notify(_ id: String, title: String, body: String) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "notified.\(id)") else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { failure in
                if failure == nil { UserDefaults.standard.set(true, forKey: "notified.\(id)") }
            }
        }
    }
    private func sendThresholdNotifications() {
        guard let balance else { return }
        let batch = snapshot!.credits.map(\.creditId).sorted().joined(separator: "-")
        if let threshold = [0, 10, 20, 50].first(where: { balance <= Decimal($0) }) {
            notify("balance-\(batch)-\(threshold)", title: "AWS 抵扣金余额提醒", body: "\(isEstimated ? "预计" : "结算")余额为 US$\(money(balance))。请决定是否继续付费使用；应用不会操作服务器。")
        }
        if let expiry = earliestExpiry, let days = daysLeft, let threshold = [1, 7, 30].first(where: { days <= $0 }) {
            notify("expiry-\(Int(expiry.timeIntervalSince1970))-\(threshold)", title: "AWS 抵扣金即将到期", body: "最近一笔有余额的抵扣金将在 \(expiry.formatted(date: .abbreviated, time: .shortened)) 到期，请提前安排。")
        }
    }
    private func sendTrafficNotifications() {
        guard let value = currentTraffic, let threshold = [100, 95, 90, 80].first(where: { value.ratio * 100 >= Double($0) }) else { return }
        let month = Int(value.monthStart.timeIntervalSince1970)
        let remainder = value.incomplete ? "监控存在缺口，请打开 AWS 核对" : "预计剩余 \(trafficGB(value.remaining))"
        notify("traffic-\(value.instanceARN)-\(month)-\(threshold)", title: "Lightsail 实例流量提醒 · 已用 \(threshold)%",
            body: "本月预计已用 \(trafficGB(value.used))，\(remainder)。额度包含入站和出站；应用只提醒，不操作服务器。")
    }
    func writeStatus() {
        var info: [String: Any] = ["loginEnabled": loginEnabled, "loginNeedsApproval": loginNeedsApproval, "notificationsEnabled": notificationsEnabled, "refreshing": refreshing,
            "balanceIntervalHours": 24, "trafficIntervalMinutes": Int(trafficRefreshInterval / 60)]
        info["lastSuccess"] = snapshot?.fetchedAt.description
        info["balanceUSD"] = balance.map(money)
        info["error"] = error
        info["nextRefresh"] = nextRefresh?.description
        info["nextBalanceRefresh"] = nextBalanceRefresh?.description
        info["nextTrafficRefresh"] = nextTrafficRefresh?.description
        info["menuTitle"] = menuTitle
        info["trafficError"] = trafficError
        if let traffic = currentTraffic {
            info["trafficMonthUTC"] = traffic.monthStart.description
            info["trafficUsedGB"] = traffic.used / bytesPerGB
            if !traffic.incomplete { info["trafficRemainingGB"] = traffic.remaining / bytesPerGB }
            info["trafficAllowanceGB"] = traffic.allowanceGB
            info["trafficLastSuccess"] = traffic.fetchedAt.description
            info["trafficMeasuredThrough"] = traffic.measuredThrough.description
            info["trafficIncomplete"] = traffic.incomplete
        }
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: support.appendingPathComponent("status.json"), options: .atomic) }
    }
    func openBilling() { NSWorkspace.shared.open(URL(string: "https://console.aws.amazon.com/costmanagement/home?region=us-east-1#/credits")!) }
}

struct SoftButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 9).padding(.horizontal, 12)
            .background(.primary.opacity(configuration.isPressed ? 0.11 : 0.045), in: RoundedRectangle(cornerRadius: 11))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(.easeOut(duration: reduceMotion ? 0 : 0.14), value: configuration.isPressed)
    }
}
struct BalancePanel: View {
    @ObservedObject var model: BalanceModel
    @Environment(\.colorScheme) var scheme
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    let accent = Color(red: 0.23, green: 0.52, blue: 0.89)
    @State var settingsVisible = false
    @State private var panelHeight: CGFloat = 580
    var animation: Animation? { reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.88) }
    var body: some View {
        ScrollView {
            content.background(GeometryReader { g in Color.clear.preference(key: PanelHeightKey.self, value: g.size.height) })
        }
        .scrollIndicators(.hidden)
        .frame(width: 360, height: min(panelHeight, max(360, (NSScreen.main?.visibleFrame.height ?? 800) - 60)))
        .background(.regularMaterial)
        .onPreferenceChange(PanelHeightKey.self) { height in
            if abs(height - panelHeight) > 1 { withAnimation(animation) { panelHeight = height } }
        }
    }
    var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Text("余量").font(.system(size: 14, weight: .semibold))
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(model.error != nil || model.trafficError != nil ? Color.orange : accent).frame(width: 5, height: 5)
                    Text(model.statusText).font(.system(size: 10, weight: .medium))
                }.foregroundStyle(.secondary).padding(.horizontal, 9).padding(.vertical, 6).background(.primary.opacity(0.04), in: Capsule())
            }
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text(model.isEstimated ? "预计剩余抵扣金" : "剩余抵扣金 · 结算金额").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("$").font(.system(size: 25, weight: .light, design: .rounded)).foregroundStyle(.secondary)
                    Text(model.balanceText).font(.system(size: 45, weight: .medium, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText()).minimumScaleFactor(0.6).lineLimit(1)
                }.accessibilityElement(children: .ignore).accessibilityLabel("剩余 \(model.balanceText) 美元")
                GeometryReader { g in
                    Capsule().fill(accent.opacity(0.10)).overlay(alignment: .leading) {
                        Capsule().fill(LinearGradient(colors: [accent, Color(red: 0.37, green: 0.72, blue: 0.81)], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(0, g.size.width * model.fraction)).animation(animation, value: model.fraction)
                    }
                }.frame(height: 5)
                HStack {
                    Text("有效额度 $\(money(model.granted))")
                    Spacer()
                    Text(model.stale ? "以最近成功查询为准" : "账单数据有更新延迟")
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(20)
            .background {
                RoundedRectangle(cornerRadius: 20).fill(LinearGradient(colors: [accent.opacity(scheme == .dark ? 0.16 : 0.075), Color.primary.opacity(0.015)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(accent.opacity(0.12), lineWidth: 1))
            }
            if model.monitorsTraffic { trafficCard }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).transition(.opacity.combined(with: .move(edge: .top)))
            }
            if model.keychainNeedsAuthorization {
                Button("允许更新后的应用访问钥匙串") { model.authorizeKeychain() }.buttonStyle(SoftButtonStyle()).font(.system(size: 11))
            }
            VStack(spacing: 12) {
                infoRow("calendar", "最近到期", value: model.earliestExpiry?.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)) ?? "暂无有效额度", trailing: model.daysLeft.map { "约 \($0) 天" })
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    infoRow("clock", "余额更新", value: model.snapshot?.fetchedAt.formatted(date: .omitted, time: .shortened) ?? "尚未成功", trailing: model.snapshot.map { RelativeDateTimeFormatter().localizedString(for: $0.fetchedAt, relativeTo: Date()) })
                }
            }.padding(.horizontal, 3)
            HStack(spacing: 8) {
                Button { model.refresh() } label: {
                    HStack(spacing: 7) {
                        if model.refreshing { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 13, height: 13) }
                        else { Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)) }
                        Text(model.refreshing ? "正在刷新" : "刷新数据").font(.system(size: 12, weight: .medium))
                    }.frame(maxWidth: .infinity)
                }.buttonStyle(SoftButtonStyle()).disabled(model.refreshing)
                Button { model.openBilling() } label: {
                    HStack(spacing: 6) { Text("查看账单"); Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)) }
                        .font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity)
                }.buttonStyle(SoftButtonStyle())
            }
            if settingsVisible {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("登录后自动启动", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                        .toggleStyle(.switch).controlSize(.mini)
                    if model.loginNeedsApproval {
                        Button("在系统设置中允许登录项") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(.link)
                    }
                    HStack { Text("余额刷新"); Spacer(); Text("每 24 小时").foregroundStyle(.secondary) }
                    if model.monitorsTraffic {
                    HStack { Text("流量刷新"); Spacer(); Text("每 \(Int(model.trafficRefreshInterval / 60)) 分钟").foregroundStyle(.secondary) }
                    Text("流量用量达到 80% 后，每 5 分钟更新。休眠时不唤醒 Mac，恢复后补查到期数据。")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack { Text("余额提醒"); Spacer(); Text("$50 / $20 / $10").foregroundStyle(.secondary) }
                    HStack { Text("到期提醒"); Spacer(); Text("30 / 7 / 1 天").foregroundStyle(.secondary) }
                    if model.monitorsTraffic {
                    HStack { Text("流量提醒"); Spacer(); Text("已用 80 / 90 / 95%").foregroundStyle(.secondary) }
                    Text("流量为所选 Lightsail 实例 NetworkIn + NetworkOut 的估算，按 UTC 自然月累计；GB 按 1024³ 字节换算。监控延迟、共享额度及套餐变更可能使结果与账单不同。")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if !model.notificationsEnabled {
                        Button("允许通知，以接收余额和到期提醒") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) }.buttonStyle(.link)
                    }
                    Text("密钥保存在本机钥匙串。仅查询和提醒；通知不会更改任何云资源。")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let next = model.nextBalanceRefresh { Text("余额下次更新 \(next.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 10)).foregroundStyle(.secondary) }
                    if let next = model.nextTrafficRefresh { Text("流量下次更新 \(next.formatted(date: .omitted, time: .shortened))").font(.system(size: 10)).foregroundStyle(.secondary) }
                }.font(.system(size: 11)).padding(14).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            HStack {
                Spacer()
                Button { withAnimation(animation) { settingsVisible.toggle() } } label: { Image(systemName: "slider.horizontal.3").frame(width: 24, height: 20) }.help("显示设置")
                Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power").frame(width: 24, height: 20) }.help("退出")
            }.foregroundStyle(.secondary).buttonStyle(.plain)
        }
        .padding(22).frame(width: 360)
        .background(.regularMaterial)
        .animation(animation, value: model.error)
    }
    var trafficCard: some View {
        let traffic = model.currentTraffic
        let tint = (traffic?.ratio ?? 0) >= 0.8 ? Color.orange : accent
        return VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 7) {
                Image(systemName: "network").foregroundStyle(tint)
                Text("Lightsail 实例").fontWeight(.semibold)
                Spacer()
                Text("本月 · UTC").foregroundStyle(.secondary)
            }.font(.system(size: 11))
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("本月已用 · 预计").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(traffic.map { trafficGB($0.used) } ?? "—")
                        .font(.system(size: 20, weight: .medium, design: .rounded)).monospacedDigit().contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.7)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 6) {
                    Text("预计剩余").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(traffic.flatMap { $0.incomplete ? nil : trafficGB($0.remaining) } ?? "—")
                        .font(.system(size: 20, weight: .medium, design: .rounded)).monospacedDigit().contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.7)
                }.frame(maxWidth: .infinity, alignment: .trailing)
            }
            GeometryReader { g in
                Capsule().fill(tint.opacity(0.10)).overlay(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.8)).frame(width: g.size.width * min(1, max(0, traffic?.ratio ?? 0)))
                        .animation(animation, value: traffic?.ratio)
                }
            }.frame(height: 4)
            HStack {
                Text(traffic.map { "月额度 \(trafficGB($0.limit))" } ?? "等待同步")
                Spacer()
                Text(traffic.map { "已用 \(Int(($0.ratio * 100).rounded()))%" } ?? "入站 + 出站")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            if let error = model.trafficError {
                Label(error, systemImage: "exclamationmark.circle").font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if traffic?.incomplete == true {
                Text("监控数据有缺口，剩余流量暂不可估").font(.system(size: 10)).foregroundStyle(.orange)
            } else if let date = traffic?.measuredThrough {
                Text("指标截至 \(date.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .padding(17)
        .background(RoundedRectangle(cornerRadius: 17).fill(tint.opacity(scheme == .dark ? 0.075 : 0.035))
            .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(.primary.opacity(0.06), lineWidth: 1)))
    }
    func infoRow(_ icon: String, _ title: String, value: String, trailing: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 14).foregroundStyle(.tertiary)
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
            if let trailing { Text(trailing).font(.system(size: 10)).foregroundStyle(.secondary) }
        }.font(.system(size: 11))
    }
}
struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 580
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    let model = BalanceModel()
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = nil
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.target = self; button.action = #selector(togglePanel)
            button.setAccessibilityLabel("剩余抵扣金与实例剩余流量")
        }
        popover.behavior = .transient; popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let host = NSHostingController(rootView: BalancePanel(model: model))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.delegate = self
        model.updated = { [weak self] in self?.updateStatus() }
        updateStatus(); model.start()
        if !UserDefaults.standard.bool(forKey: "didShowWelcome") {
            UserDefaults.standard.set(true, forKey: "didShowWelcome")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.togglePanel() }
        }
    }
    func updateStatus() {
        statusItem.button?.title = model.menuTitle
        statusItem.button?.setAccessibilityValue(model.menuTitle)
        var tip = "剩余抵扣金：\(model.balance.map { "$" + money($0) } ?? "—")"
        if let traffic = model.currentTraffic, !traffic.incomplete { tip += "\n实例预计剩余：\(trafficGB(traffic.remaining))" }
        tip += "\n\(model.statusText) · 余额每天"
        if model.monitorsTraffic { tip += " / 流量每 \(Int(model.trafficRefreshInterval / 60)) 分钟" }
        statusItem.button?.toolTip = tip
    }
    @objc func togglePanel() {
        if popover.isShown { popover.performClose(nil); return }
        model.updateLoginState(); model.readNotificationState(); updateStatus()
        if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if !popover.isShown { togglePanel() }; return false }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound]) }
}

if CommandLine.arguments.contains("--install-credentials") {
    do {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        try CredentialStore.save(input)
        print("Credentials stored in login keychain; no secret written to files.")
        exit(0)
    } catch { fputs("Credential installation failed: \(error.localizedDescription)\n", stderr); exit(1) }
}
// Read-only machine interface for future local assistant queries. Secrets never leave the Keychain/child environment.
if CommandLine.arguments.contains("--query-json") {
    do {
        let config = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: support.appendingPathComponent("config.json")))
        var response: [String: Any] = [:]
        do {
            let credits = try BillingReader.fetch(config)
            let current = credits.filter { $0.active(at: Date()) && $0.remainingAmount.currencyCode == "USD" }
            let estimated = !current.isEmpty && current.allSatisfy { $0.estimatedAmount?.decimal != nil }
            let amount = current.reduce(Decimal(0)) { $0 + (estimated ? $1.estimatedAmount!.decimal! : $1.remainingAmount.decimal!) }
            response["balanceUSD"] = money(amount); response["isEstimated"] = estimated
        } catch { response["balanceError"] = error.localizedDescription }
        if config.traffic != nil { do {
            let traffic = try BillingReader.fetchTraffic(config)
            response["trafficUsedGB"] = traffic.used / bytesPerGB
            if !traffic.incomplete { response["trafficRemainingGB"] = traffic.remaining / bytesPerGB }
            response["trafficAllowanceGB"] = traffic.allowanceGB
            response["trafficMonthUTC"] = traffic.monthStart.description
            response["trafficMeasuredThrough"] = traffic.measuredThrough.description
            response["trafficIncomplete"] = traffic.incomplete
        } catch { response["trafficError"] = error.localizedDescription } }
        print(String(data: try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
        exit(response["balanceError"] != nil && (config.traffic == nil || response["trafficError"] != nil) ? 1 : 0)
    } catch { fputs("Read-only query failed: \(error.localizedDescription)\n", stderr); exit(1) }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
