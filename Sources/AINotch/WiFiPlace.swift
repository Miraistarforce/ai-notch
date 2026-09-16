import AppKit
import Combine
import CoreLocation
import CoreWLAN

/// つないでいるWi-Fiから「いまどこにいるか」を出す。
///
/// **macOS 14以降、現在のSSIDは位置情報の許可がないプロセスには伏せられる。**
/// 許可がないと `CWInterface.ssid()` は nil を返し（CLIでは `ipconfig getsummary en0` が
/// `SSID : <redacted>` を返すのと同じ制限）、スタバも自宅も区別がつかなくなる。
/// なので CoreLocation の許可を取ってから CoreWLAN で読む。
///
/// 位置情報そのもの（緯度経度）は取らない。許可はSSIDの秘匿を外すためだけに使う。
final class WiFiPlace: NSObject, ObservableObject {
    static let shared = WiFiPlace()

    private static let namesKey = "wifiPlaceNames"
    /// SSIDの変化はイベントで拾うが、取りこぼし（スリープ復帰・許可を後から出した等）に備えて定期的にも見る
    private static let pollInterval: TimeInterval = 15

    /// 接続中のSSID。未接続・Wi-Fiオフ・未許可のときは nil
    @Published private(set) var ssid: String?
    /// SSIDから決めた場所の名前（例：スタバ）。当てられなければ nil
    @Published private(set) var placeName: String?
    /// 位置情報の許可状態
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    /// Wi-Fiがオンかどうか
    @Published private(set) var wifiPowerOn = false
    /// SSIDが最後に変わった時刻（＝この場所に来た時刻）
    @Published private(set) var changedAt: Date?

    /// ユーザーが付けた名前（SSID → 場所名）。組み込みルールより優先する
    @Published private(set) var customNames: [String: String]

    private let manager = CLLocationManager()
    private let client = CWWiFiClient.shared()
    private var timer: Timer?
    private let timestampFormatter = ISO8601DateFormatter()

    private override init() {
        customNames = (UserDefaults.standard.dictionary(forKey: Self.namesKey) as? [String: String]) ?? [:]
        super.init()
        manager.delegate = self
        authorization = manager.authorizationStatus
    }

    // MARK: - 開始と更新

    /// 起動時に一度だけ呼ぶ。許可を求め、SSIDの監視を始める。
    func start() {
        requestAuthorizationIfNeeded()

        client.delegate = self
        // SSIDが変わった／Wi-Fiの電源が変わったら即反映する（0.144 時点のCoreWLANはどちらも通知してくれる）
        try? client.startMonitoringEvent(with: .ssidDidChange)
        try? client.startMonitoringEvent(with: .powerDidChange)

        // メニューを開いている間やドラッグ中（.eventTracking）も止まらないよう .common に入れる
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }

        refresh()
    }

    /// いまのSSIDを読み直す。許可が出た直後・ネットワーク切替直後にも呼ばれる。
    func refresh() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.refresh() }
            return
        }
        let interface = client.interface()
        let current = interface?.ssid()
        if current != ssid {
            ssid = current
            changedAt = Date()
        }
        wifiPowerOn = interface?.powerOn() ?? false
        authorization = manager.authorizationStatus
        placeName = current.flatMap { Self.name(for: $0, custom: customNames) }
    }

    /// 位置情報が未許可ならダイアログを出す。一度拒否されていると二度と出ないので、
    /// そのときは設定画面から `openLocationSettings()` に誘導する。
    func requestAuthorizationIfNeeded() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// システム設定の「位置情報サービス」を開く
    func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 場所の名前

    /// 表示用の名前。名前が付いていない場所はSSIDをそのまま出す（「不明」で潰さない）。
    var label: String {
        if let placeName { return placeName }
        if let ssid, !ssid.isEmpty { return ssid }
        if !isAuthorized { return "位置情報の許可待ち" }
        return wifiPowerOn ? "Wi-Fi未接続" : "Wi-Fiオフ"
    }

    /// SSIDを読める状態か（許可が出ていればtrue）
    var isAuthorized: Bool {
        switch authorization {
        case .authorizedAlways, .authorizedWhenInUse: return true
        default: return false
        }
    }

    /// いまのSSIDに名前を付ける（自宅・実家など、組み込みルールで当たらない場所用）。
    /// 空文字を渡すと登録を消す。
    func setName(_ name: String, for ssid: String) {
        guard !ssid.isEmpty else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            customNames.removeValue(forKey: ssid)
        } else {
            customNames[ssid] = trimmed
        }
        UserDefaults.standard.set(customNames, forKey: Self.namesKey)
        refresh()
    }

    /// SSIDから場所を当てる組み込みルール（部分一致・大文字小文字は無視）。
    /// 店舗ごとに末尾の番号やアンダースコアが変わるので、完全一致ではなく「含む」で見る。
    /// 上から順に当たった最初のものを採用するため、広いパターン（wi2）は下に置く。
    private static let rules: [(pattern: String, name: String)] = [
        ("starbucks", "スタバ"),
        ("mcd", "マック"),
        ("mcdonald", "マック"),
        ("komeda", "コメダ"),
        ("seattle", "シアトルズ"),
        ("tully", "タリーズ"),
        ("doutor", "ドトール"),
        ("excelsior", "エクセルシオール"),
        ("veloce", "ベローチェ"),
        ("pronto", "プロント"),
        ("saint-marc", "サンマルク"),
        ("7spot", "セブン"),
        ("famima", "ファミマ"),
        ("lawson", "ローソン"),
        ("jr-east", "JR東日本"),
        ("shinkansen", "新幹線"),
        ("freespot", "FREESPOT"),
        // どの店かまでは決まらないが「屋外のWi2系スポット」だとは分かる。必ず最後に評価する
        ("wi2", "Wi2スポット"),
    ]

    /// ユーザーが付けた名前 → 組み込みルール、の順で解決する
    static func name(for ssid: String, custom: [String: String]) -> String? {
        if let named = custom[ssid] { return named }
        let lower = ssid.lowercased()
        return rules.first { lower.contains($0.pattern) }?.name
    }

    // MARK: - 外部公開

    /// `GET /place` の中身。hookやスクリプトから「いまどこにいるか」を引ける。
    func placeJSON() -> Data {
        var info: [String: Any] = [
            "ok": true,
            "place": label,
            "ssid": ssid ?? "",
            // ユーザーが自分で名前を付けた場所か
            "named": ssid.map { customNames[$0] != nil } ?? false,
            // 名前が付いている（組み込みルールを含む）か。false ならSSIDをそのまま出している
            "recognized": placeName != nil,
            "wifi_on": wifiPowerOn,
            "location_authorized": isAuthorized,
            "authorization": Self.authorizationText(authorization),
        ]
        if let changedAt {
            info["changed_at"] = timestampFormatter.string(from: changedAt)
        }
        if !isAuthorized {
            // denied は「拒否した」だけでなく「位置情報サービス自体がオフ」でも返る。
            // その場合は一覧にアプリが出ないので、先に大元のスイッチを入れてもらう必要がある。
            info["note"] = "位置情報が未許可のあいだ、macOSはSSIDを伏せます（システム設定 > プライバシーとセキュリティ > 位置情報サービス をオンにし、一覧の AI Notch もオン）"
        }
        return (try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted])) ?? Data("{}".utf8)
    }

    static func authorizationText(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "authorizedAlways"
        case .authorizedWhenInUse: return "authorizedWhenInUse"
        @unknown default: return "unknown"
        }
    }
}

extension WiFiPlace: CLLocationManagerDelegate {
    /// 許可が出た／取り消された瞬間にSSIDの見え方が変わるので読み直す
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async { self.refresh() }
    }
}

extension WiFiPlace: CWEventDelegate {
    func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        DispatchQueue.main.async { self.refresh() }
    }

    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        DispatchQueue.main.async { self.refresh() }
    }
}
