//
//  SideStoreClient.swift
//  SideStoreSupport
//
//  Created by s s on 2025/7/20.
//

import Foundation
import AppIntents
import OSLog

enum SideStoreIntentError: LocalizedError {
    case typeNotFound(String)
    case typeIsNotAppIntent(String)
    case actionNotFound

    var errorDescription: String? {
        switch self {
        case .typeNotFound(let name):
            return lcLocalizedFormat("lc.sidestore.typeNotFound", "SideStore refresh intent type was not found: %@", name)
        case .typeIsNotAppIntent(let name):
            return lcLocalizedFormat("lc.sidestore.typeNotIntent", "SideStore type is not an AppIntent: %@", name)
        case .actionNotFound:
            return lcLocalized("lc.sidestore.actionNotFound", "Couldn't find the SideStore refresh action. In the built-in SideStore, reinstall the LiveContainer+SideStore IPA from My Apps, then run the shortcut again.")
        }
    }
}

@available(iOS 17.0, *)
private func resolveType(_ mangledTypeName: String) throws -> any Any.Type {
    let bytes = Array(mangledTypeName.utf8)
    let resolvedType: Any.Type? = bytes.withUnsafeBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else {
            return nil
        }

        // Swift exposes the runtime symbol swift_getTypeByMangledNameInContext
        // as _getTypeByMangledNameInContext. The name intentionally omits
        // the "$s" prefix, which is the form accepted for this module.
        return _getTypeByMangledNameInContext(
            baseAddress,
            UInt(buffer.count),
            genericContext: nil,
            genericArguments: nil
        )
    }

    guard let resolvedType else {
        throw SideStoreIntentError.typeNotFound(mangledTypeName)
    }

    return resolvedType
}

@available(iOS 17.0, *)
struct SideStoreIntentCaller {
    static let shared = SideStoreIntentCaller()
    
    // call this when a IntentContext already exists (when sidestore is loaded in LiveContainer itself)
    func callRefreshIntent(mangledTypeName: String) async throws {
        let resolvedType = try resolveType(mangledTypeName)
        guard let intentType = resolvedType as? any ProgressReportingIntent.Type else {
            throw SideStoreIntentError.typeIsNotAppIntent(mangledTypeName)
        }
        
        let intent = intentType.init()
        let _ = try await intent.perform()
    }
    
    // LNPerformActionErrorCodeActionNotFound 판별
    private func isActionNotFound(_ error: Error) -> Bool {
        let ns = error as NSError
        let text = "\(ns.domain) \(ns.localizedDescription) \(String(describing: error))".lowercased()
        if text.contains("actionnotfound") || text.contains("action not found") {
            return true
        }
        return ns.domain.lowercased().contains("lnperformaction") && text.contains("not found")
    }
    
    // call this when no IntentContext exists (when sidestore is loaded in LiveProcess)
    // 업데이트 직후나 SideStore 시작 직후에는 인텐트 등록이 늦어 ActionNotFound 가 일시적으로 나올 수 있어 짧게 재시도한다
    func callRefreshIntent2(identifier: String, mangledTypeName: String, progressCallback: (Progress)->Void ) async throws {
        let maxAttempts = 3
        var attempt = 0
        while true {
            attempt += 1
            do {
                try await callRefreshIntentOnce(identifier: identifier, mangledTypeName: mangledTypeName, progressCallback: progressCallback)
                return
            } catch {
                guard isActionNotFound(error) else {
                    throw error
                }
                if attempt >= maxAttempts {
                    NSLog("[LC] SideStore 새로고침 동작을 찾지 못했습니다 (\(attempt)회 시도): \(error)")
                    // 시스템에 인텐트가 등록되지 않았더라도(Nightly 업데이트 후 Refresh All Apps 동작이 사라지는 경우 등)
                    // SideStore 프로세스 안에 인텐트 타입이 있으면 직접 실행해 새로고침을 시도한다
                    do {
                        NSLog("[LC] 인텐트 직접 실행으로 새로고침을 시도합니다")
                        try await callRefreshIntent(mangledTypeName: mangledTypeName)
                        return
                    } catch {
                        NSLog("[LC] 인텐트 직접 실행도 실패했습니다: \(error)")
                        throw SideStoreIntentError.actionNotFound
                    }
                }
                NSLog("[LC] SideStore 새로고침 동작을 찾지 못해 다시 시도합니다 (\(attempt)/\(maxAttempts)): \(error)")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }
    
    private func callRefreshIntentOnce(identifier: String, mangledTypeName: String, progressCallback: (Progress)->Void ) async throws {
        try await withUnsafeThrowingContinuation { (c: UnsafeContinuation<(), any Error>) in
            let parent = PrivateIntentRunner.run(
                        identifier: identifier,
                        mangledTypeName: mangledTypeName
                    ) { result, error in
                        print("performAction result=\(String(describing: result)), " +
                              "error=\(String(describing: error))")
                        if let error {
                            c.resume(throwing: error)
                        } else {
                            c.resume()
                        }
                    }
            if let parent {
                progressCallback(parent)
            }
        }
    }
}

@available(iOS 17.0, *)
@objc extension SideStoreClient {
    @objc(performRefreshForRealWithIdentifier:mangledTypeName:server:)
    func performRefreshForReal(identifier: String, mangledTypeName: String, server: any RefreshServer) {
        Task {
            do {
                var obs: NSKeyValueObservation? = nil
                try await SideStoreIntentCaller.shared.callRefreshIntent2(identifier: identifier, mangledTypeName: mangledTypeName) { progress in
                    obs = progress.observe(\.fractionCompleted, options: [.new]) { progress, change in
                        if let newValue = change.newValue {
                            server.updateProgress(newValue)
                        }
                    }
                }
                obs?.invalidate()
                server.finish(nil)
            } catch {
                server.finish(error.localizedDescription)
            }
        }
    }

}
