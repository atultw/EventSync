//
//  File.swift
//  
//
//  Created by Atulya Weise on 9/15/22.
//
import CloudKit
import Combine

public enum FetchError: Error {
    /// No internet connection. Events may continue to be "uploaded" to EventSync and will be queued locally, then uploaded when the internet connection is back online.
    case noInternet

    /// Another fetch operation is already running.
    case alreadyFetching

    /// A backup restore is in progress. EventSync does not fetch new events while restoring from a backup. Try again later
    case restoringFromBackup

    /// The instance of `Sync` has `readyToFetch` set to false. Make sure you are calling Ready
    case notReadyToFetch

    var localizedDescription: String {
        switch self {
        case .noInternet:
            return "The internet connection is offline."
        case .alreadyFetching:
            return "A fetch operation is already running."
        case .restoringFromBackup:
            return "A backup restore is in progress."
        case .notReadyToFetch:
            return "The app has not indicated that it is ready to receive events."
        }
    }
}

actor Download {
    init(eventsZone: CKRecordZone, database: CKDatabase, tokenManager: TokenManager) {
        self.eventsZone = eventsZone
        self.database = database
        self.tokenManager = tokenManager
    }

    let eventsZone: CKRecordZone
    let database: CKDatabase
    let tokenManager: TokenManager
    var currentTask: Task<[CKRecord], Error>?

    /// Returns new records
    ///
    /// all records changed/created after the change token are returned. Change token is the one provided (if present), or else defaults to the one from `tokenManager`. Sets the new token in `tokenManager` after fetching is complete. If the function throws and does not return, `tokenManager` is not updated.
    func fetchCKRecordsAndSetToken(startAt changeToken: CKServerChangeToken? = nil) async throws -> [CKRecord] {
        if currentTask == nil {
            currentTask = Task {
                defer {
                    self.currentTask?.cancel()
                    self.currentTask = nil
                }

                let defaultToken = await tokenManager.ckToken

                let (results, token) = try await fetchCKRecordsOnly(startAt: changeToken ?? defaultToken)

                await self.tokenManager.setToken(token)
                return results
            }
            return try await currentTask!.value
        } else {
            throw FetchError.alreadyFetching
        }
    }

    /// Returns all events after the provided token, but does not save the new token.
    ///
    /// If `changeToken` is nil, fetches all records from the beginning. No default token is read from disk.
    func fetchCKRecordsOnly(startAt changeToken: CKServerChangeToken?, maxResults: Int = 0) async throws -> ([CKRecord], CKServerChangeToken?) {
        let clientID = await getClientID()

        return try await withCheckedThrowingContinuation { continuation in

            var results = [CKRecord]()
            let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            configuration.previousServerChangeToken = changeToken
            configuration.resultsLimit = maxResults
            // https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitQuickStart/MaintainingaLocalCacheofCloudKitRecords/MaintainingaLocalCacheofCloudKitRecords.html#//apple_ref/doc/uid/TP40014987-CH12-SW7
            let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [eventsZone.zoneID], configurationsByRecordZoneID: [eventsZone.zoneID: configuration])

            operation.fetchAllChanges = true
            operation.recordChangedBlock = { (record) in
                if record["sync_client"] as? String != clientID {
                    results.append(record)
                }
            }

            operation.recordZoneChangeTokensUpdatedBlock = { (_, _, _) in

            }

            operation.recordZoneFetchCompletionBlock = { (_, newToken, _, _, error) in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                let results = results
                continuation.resume(returning: (results, newToken))
            }

            let config = CKOperation.Configuration()
            config.timeoutIntervalForRequest = 5
            config.qualityOfService = .userInitiated
            operation.configuration = config
            database.add(operation)
        }
    }
}
