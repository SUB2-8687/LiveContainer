//
//  SideStore.swift
//  SideStoreSupport
//
//  Created by s s on 2025/7/20.
//

import Foundation
import AppIntents
import UserNotifications

@available(iOS 17.0, *)
func performIntentRefresh(identifier: String, mangledTypeName: String, intentProgress: Progress) async throws {
    intentProgress.totalUnitCount = 100
    if UserDefaults.isSideStore() {
        try await SideStoreIntentCaller.shared.callRefreshIntent(mangledTypeName: mangledTypeName)
    } else {
        RefreshHandler.shared.progress = intentProgress
        try await RefreshHandler.shared.startRefresh(identifier: identifier, mangledName: mangledTypeName)
    }
}

@available(iOS 17.0, *)
public struct RefreshAllAppsWidgetIntent: AppIntent, ProgressReportingIntent
{
    public static var title: LocalizedStringResource { "Refresh Apps via Widget" }
    public static var isDiscoverable: Bool { false } // Don't show in Shortcuts or Spotlight.
    
    public init() {}
    
    public func perform() async throws -> some IntentResult
    {
        try await performIntentRefresh(identifier: "RefreshAllAppsWidgetIntent", mangledTypeName: "9SideStore26RefreshAllAppsWidgetIntentV", intentProgress: progress)
        return .result()
    }
}

@available(iOS 17.0, *)
public struct RefreshAllAppsIntent: AppIntent, CustomIntentMigratedAppIntent, PredictableIntent, ProgressReportingIntent, ForegroundContinuableIntent
{
    public static let intentClassName = "RefreshAllIntent"
    
    public static var title: LocalizedStringResource = "Refresh All Apps"
    public static var description = IntentDescription("Refreshes your sideloaded apps to prevent them from expiring.")
    
    public init() {}
    
    public static var parameterSummary: some ParameterSummary {
        Summary("Refresh All Apps")
    }
    
    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction {
            DisplayRepresentation(
                title: "Refresh All Apps",
                subtitle: ""
            )
        }
    }
    
    public func perform() async throws -> some IntentResult & ProvidesDialog
    {
        try await performIntentRefresh(identifier: "RefreshAllIntent", mangledTypeName: "9SideStore20RefreshAllAppsIntentV", intentProgress: progress)
        return .result(dialog: "All apps have been refreshed.")
    }
    
}


// LiveProcess(SideStore 실행 중) 안에서는 lcMainBundle 이 LiveProcess.appex 번들이라 번역 파일이 없어
// 영문 기본값이 그대로 나온다. 그 경우 LiveContainer 앱 번들(appex 의 두 단계 위)에서 번역을 찾는다.
func lcLocalizedBundles() -> [Bundle] {
    var bundles = [UserDefaults.lcMainBundle()]
    if UserDefaults.isLiveProcess() {
        let appURL = UserDefaults.lcMainBundle().bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        if let appBundle = Bundle(url: appURL) {
            bundles.insert(appBundle, at: 0)
        }
    }
    return bundles
}

func lcLocalized(_ key: String, _ fallback: String) -> String {
    for bundle in lcLocalizedBundles() {
        let text = bundle.localizedString(forKey: key, value: "", table: nil)
        if !text.isEmpty && text != key {
            return text
        }
    }
    return fallback
}

func lcLocalizedFormat(_ key: String, _ fallback: String, _ args: CVarArg...) -> String {
    return String(format: lcLocalized(key, fallback), arguments: args)
}

func lcRefreshError(_ key: String, _ fallback: String) -> NSError {
    return NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: lcLocalized(key, fallback)])
}

class RefreshHandler: NSObject, RefreshServer {
    var refreshToken: UUID? = nil
    var c: UnsafeContinuation<(), any Error>? = nil
    var launchContinuation: UnsafeContinuation<(), any Error>? = nil
    var progress: Progress? = nil
    var listener: NSXPCListener? = nil
    var sideStorePid: Int32 = 0
    var client: RefreshClient? = nil
    var ext: NSExtension? = nil
    
    static var shared = RefreshHandler()
    
    func startRefresh(identifier: String, mangledName: String) async throws {
        if sideStorePid <= 0 || getpgid(sideStorePid) <= 0, let c {
            c.resume(throwing: lcRefreshError("lc.sidestore.quitUnexpectedly", "Built-in SideStore quit unexpectedly"))
            self.c = nil
        }
        
        if c != nil {
            throw lcRefreshError("lc.sidestore.refreshInProgress", "Another refresh task is in progress.")
        }
        
        if listener == nil {
            // 조용히 return 하면 단축어가 "새로고침 완료"로 오인하므로 오류를 던진다
            guard let listener = startAnonymousListener(self) else {
                NSLog("[LC] SideStore 새로고침: XPC 리스너를 시작하지 못했습니다")
                throw lcRefreshError("lc.sidestore.notReady", "Couldn't connect to the built-in SideStore. Please try again.")
            }
            self.listener = listener
        }
        guard let listener = self.listener else {
            throw lcRefreshError("lc.sidestore.notReady", "Couldn't connect to the built-in SideStore. Please try again.")
        }

        // launch SideStore if it's not running
        if (sideStorePid <= 0 || getpgid(sideStorePid) <= 0) && launchContinuation == nil {
            guard let lcHomePtr = getenv("LC_HOME_PATH") else {
                NSLog("[LC] SideStore 새로고침: LC_HOME_PATH 환경 변수가 없습니다")
                throw lcRefreshError("lc.sidestore.homeMissing", "Couldn't find the built-in SideStore data folder. Open the built-in SideStore once, then try again.")
            }
            let lcHome = String(cString: lcHomePtr)
            let sideStoreHomeURL = URL(fileURLWithPath: lcHome).appendingPathComponent("Documents/SideStore")
            guard let bookmarkData = bookmarkForURL(sideStoreHomeURL) else {
                NSLog("[LC] SideStore 새로고침: 데이터 폴더 북마크를 만들지 못했습니다 (\(sideStoreHomeURL.path))")
                throw lcRefreshError("lc.sidestore.homeMissing", "Couldn't find the built-in SideStore data folder. Open the built-in SideStore once, then try again.")
            }

            // start LiveProcess
            let extensionItem = NSExtensionItem()
            extensionItem.userInfo = [
                "selected": "builtinSideStore",
                "bookmarks": [bookmarkData],
                "endpoint": listener.endpoint
            ]

            guard let liveProcessURL = UserDefaults.lcMainBundle().builtInPlugInsURL?.appendingPathComponent("LiveProcess.appex"),
                  let liveProcessBundle = Bundle(url: liveProcessURL)
            else {
                NSLog("Unable to locate LiveProcess bundle")
                throw lcRefreshError("lc.sidestore.liveProcessMissing", "Unable to locate LiveProcess bundle. Reinstall LiveContainer+SideStore with all app extensions kept.")
            }
            
            var ext : NSExtension?
            do {
                ext = try NSExtension(identifier: liveProcessBundle.bundleIdentifier)
            } catch {
                NSLog("Failed to start extension \(error)")
                throw NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: lcLocalizedFormat("lc.sidestore.extensionFailed", "Failed to start extension %@. Reinstall LiveContainer+SideStore with all app extensions kept.", String(describing: error))])
            }
            guard let ext else {
                throw lcRefreshError("lc.sidestore.notReady", "Couldn't connect to the built-in SideStore. Please try again.")
            }
            self.ext = ext
            
            ext.setRequestInterruptionBlock { uuid in
                self.c?.resume(throwing: lcRefreshError("lc.sidestore.quitUnexpectedly", "Built-in SideStore quit unexpectedly"))
                self.c = nil
                self.sideStorePid = 0
                self.client = nil
                // 시작 대기 중이던 continuation 도 반드시 깨워서 단축어가 멈춰 있지 않게 한다
                self.launchContinuation?.resume(throwing: lcRefreshError("lc.sidestore.quitUnexpectedly", "Built-in SideStore quit unexpectedly"))
                self.launchContinuation = nil
            }
            
            let uuid = await ext.beginRequest(withInputItems: [extensionItem])
            sideStorePid = ext.pid(forRequestIdentifier: uuid)
            
            try await withUnsafeThrowingContinuation { c in
                self.launchContinuation = c
                DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
                    if let c = self.launchContinuation {
                        c.resume(throwing: lcRefreshError("lc.sidestore.startTimeout", "Built-in SideStore failed to start in reasonable time"))
                        self.launchContinuation = nil
                        ext._kill(9)
                    }
                }
            }
        }
        // client 가 없으면 요청이 전달되지 않고 영원히 대기하게 되므로 오류로 처리
        guard let client = self.client else {
            NSLog("[LC] SideStore 새로고침: SideStore 와의 연결(client)이 없습니다")
            throw lcRefreshError("lc.sidestore.notReady", "Couldn't connect to the built-in SideStore. Please try again.")
        }
        
        try await withUnsafeThrowingContinuation { c in
            self.c = c
            // 응답이 끝내 오지 않는 경우를 대비한 안전장치 (15분)
            let token = UUID()
            self.refreshToken = token
            DispatchQueue.main.asyncAfter(deadline: .now() + 900) {
                if self.refreshToken == token, let pending = self.c {
                    pending.resume(throwing: lcRefreshError("lc.sidestore.refreshTimeout", "The refresh took too long and was cancelled."))
                    self.c = nil
                }
            }
            client.refreshAllApps(withIdentifier: identifier, mangledTypeName: mangledName)
        }
        
    }
    
    func updateProgress(_ value: Double) {
        progress?.completedUnitCount = Int64(value*100)
    }
    
    func finish(_ error: String?) {
        if let error {
            c?.resume(throwing: NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: error]))
            c = nil
        } else {
            c?.resume()
            c = nil
        }
    }
    
    func onConnection(_ connection: NSXPCConnection!) {
        connection.remoteObjectInterface = NSXPCInterface(with: RefreshClient.self)
        client = connection.remoteObjectProxy as? RefreshClient
    }
    
    func finishedLaunching() {
        launchContinuation?.resume()
        launchContinuation = nil
    }

    func add(_ request: UNNotificationRequest) {
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("Failed to add SideStore notification: \(error)")
            }
        }
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }
    
}
