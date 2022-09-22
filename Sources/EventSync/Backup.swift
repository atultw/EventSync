//
//  Backup.swift
//  
//
//  Created by Atulya Weise on 9/15/22.
//

import Foundation
import CloudKit

public enum BackupUploadError: Error {
    /// No change token found to associate with the backup. Possibly because the device has never been synced
    case noChangeToken
}

public enum BackupRestoreError: Error {
    /// No suitable backups were found.
    ///
    /// Do one of the following:
    /// * Get a backup from elsewhere, restore from it, and call `didRestoreBackup(from:changeToken:)`; or
    /// * Call `restoreBackup(withVersion:from:)` with a different (usually newer) schema version. Require the user to update the app if necessary
    case noCandidates

    /// Restoration is already in progress
    case alreadyRestoring

    var localizedDescription: String {
        switch self {
        case .noCandidates:
            return "No backup candidates found."
        case .alreadyRestoring:
            return "Another backup is already being restored."
        }
    }
}

actor BackupManager {
    init(snapshotsZone: CKRecordZone, database: CKDatabase, storage: UserDefaults, tokenManager: TokenManager, download: Download) {
        self.snapshotsZone = snapshotsZone
        self.database = database
        self.storage = storage
        self.tokenManager = tokenManager
        self.currentTask = nil
        self.download = download
    }

    let snapshotsZone: CKRecordZone
    let database: CKDatabase
    let storage: UserDefaults
    let tokenManager: TokenManager
    let download: Download

    var currentTask: Task<CKServerChangeToken, Error>?

    public func fetchBackups(schemaVersion: Int) async throws -> [CKRecord] {
        let query = CKQuery(recordType: "SyncSnapshot", predicate: NSPredicate(format: "schemaVersion = %d", argumentArray: [schemaVersion]))
        query.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        return try await withCheckedThrowingContinuation { continuation in
            database.perform(query, inZoneWith: snapshotsZone.zoneID) { records, err in
                if let err = err {
                    continuation.resume(throwing: err)
                } else {
                    continuation.resume(returning: records ?? [])
                }

            }
        }
    }

    public func uploadBackup(schemaVersion: Int, from file: URL) async throws {
        if let tok = storage.value(forKey: "LastFetchedToken") as? Data {
            let asset: CKAsset = CKAsset.init(fileURL: file)
            let record = CKRecord(recordType: "SyncSnapshot", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: snapshotsZone.zoneID))
            record["file"] = asset
            record["token"] = tok
            record["schemaVersion"] = schemaVersion
            record["timestamp"] = Date()
            return try await withCheckedThrowingContinuation { continuation in
                database.save(record, completionHandler: {_, err in
                    if let err = err {
                        continuation.resume(throwing: err)
                    } else {
                        continuation.resume()
                    }
                })
            }
        } else {
            throw BackupUploadError.noChangeToken
        }
    }

    public func cleanBackups(keepMostRecent number: Int, of schemaVersion: Int) async throws {
        let query = CKQuery(recordType: "SyncSnapshot", predicate: NSPredicate(format: "schemaVersion = %d", argumentArray: [schemaVersion]))
        query.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        
        let idsToDelete: [CKRecord.ID] = try await withCheckedThrowingContinuation { continuation in
                database.perform(query, inZoneWith: snapshotsZone.zoneID) { records, err in
                    if let err = err {
                        continuation.resume(throwing: err)
                    } else {
                        continuation.resume(returning: records?.dropFirst(number).map{$0.recordID} ?? [])
                    }

                }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: idsToDelete)
            operation.modifyRecordsCompletionBlock = { _, _, err in
                if let err = err {
                    continuation.resume(throwing: err)
                } else {
                    continuation.resume()
                }
            }
            database.add(operation)
        }
    }

    func restoreFromBackup(with schemaVersion: Int,
                           migration: @escaping (URL) async -> Bool) async throws -> CKServerChangeToken {
        if currentTask == nil {
            currentTask = Task {
                defer {
                    currentTask = nil
                }
                for backup in try await fetchBackups(schemaVersion: schemaVersion) {
                    if let url = (backup["file"] as? CKAsset)?.fileURL,
                       let tokenData = (backup["token"] as? Data),
                       let backupToken = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: tokenData) {
                        // fetch all the future events first
                        do {
                            // just to check if the token is fine
                            let _ = try await download.fetchCKRecordsOnly(startAt: backupToken, maxResults: 1)
                        } catch {
                            // if CloudKit says the token is expired, don't bother with migration - continue to next backup
                            continue
                        }
                        let wasSuccessful = await migration(url)
                        if wasSuccessful {
                            return backupToken
                        }
                    }
                }
                throw BackupRestoreError.noCandidates
            }
            return try await currentTask!.value
        } else {
            throw BackupRestoreError.alreadyRestoring
        }
    }
}
