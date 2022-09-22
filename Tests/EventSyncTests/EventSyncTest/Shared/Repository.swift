//
//  Repository.swift
//  EventSyncTest
//
//  Created by Atulya Weise on 9/13/22.
//

import SwiftUI
import EventSync
import CloudKit
import GRDB
import Combine

class Repository: ObservableObject {
    
    static let shared: Repository = {
        let sync = Sync(database: CKContainer.default().privateCloudDatabase, eventsZone: CKRecordZone(zoneName: "eventsZone"), snapshotsZone: CKRecordZone(zoneName: "snapshotsZone"), options: SyncOptions())
        
        return Repository(db: try! DatabaseQueue(path: getDocumentsDirectory().absoluteString+"/db.sqlite"), sync: sync)
    }()
    
    let db: DatabaseQueue
    let sync: Sync
    let manager: BackgroundManager
    var subscriptions: Set<AnyCancellable> = []
    
    init(db: DatabaseQueue, sync: Sync) {
        self.db = db
        self.sync = sync
        self.manager = BackgroundManager(managing: sync,
                                         autoDownloadWhenOnline: true,
                                         autoUploadWhenOnline: true)
        Task {
            listenForEvents()
            if !sync.previouslySynced {
                // populate the device with a backup
                do {
                    try await restoreFromBackup()
                } catch {
                    // no available backups.
                    
                    // ask the user if they want to restore manually (for example via airdrop from another device)
                    
                    // if not, set up a blank db (this is probably the first device)
                    initializeDb()
                }
            } else {
                do {
                    try await sync.cleanBackups(keepMostRecent: 1, version: 1)
                    try await sync.uploadBackup(schemaVersion: 1, from: URL(string: db.path)!)
                } catch {
                    print("error while uploading or cleaning backups:", error)
                }
            }

            // required: tell EventSync we're ready to fetch events
            sync.setReadyToFetch()
            try await sync.fetchEvents()
        }
        
    }
    
    func restoreFromBackup() async throws {
        try await sync.restoreFromBackup(version: 1) { url in
            do {
                try DatabaseQueue(path: url.absoluteString).backup(to: self.db)
                // successful
                return true
            } catch {
                print(error)
                // try another one
                return false
            }
        }
    }
    
    func initializeDb() {
        do {
            try db.write {
                try $0.execute(sql: "CREATE TABLE todo (id TEXT PRIMARY KEY, name TEXT);")
            }
        } catch {
            print("table already exists: ", error.localizedDescription)
        }
        
        do {
            try db.write {
                // migration
                try $0.execute(sql: "ALTER TABLE todo ADD COLUMN createdAt NOT NULL DEFAULT 0")
            }
        } catch {
            print("migration failed: ", error.localizedDescription)
        }
        
        do {
            try db.write {
                // migration
                try $0.execute(sql: "ALTER TABLE todo ADD COLUMN dueDate NOT NULL DEFAULT 0")
            }
        } catch {
            print("migration failed: ", error.localizedDescription)
        }
    }
    
    func listenForEvents() {
        sync.publisher(for: TodoCreationEvent.self)
            .sink { val in
                do {
                    try self.db.write { wr in
                        try val.model.insert(wr)
                    }
                } catch {
                    print("Could not process remote event: \(error)")
                }
                
            }
            .store(in: &self.subscriptions)
        
        sync.publisher(for: TodoDeletionEvent.self)
            .sink { val in
                do {
                    try self.db.write { wr in
                        try Todo.deleteOne(wr, key: ["id": val.modelId])
                    }
                } catch {
                    print("Could not process remote event: \(error)")
                }
                
            }
            .store(in: &self.subscriptions)
    }
    
    func list<T: FetchableRecord>(_ query: String, with values: StatementArguments, offset: Int = 0, limit: Int = 20) throws -> [T] {
        return try db.read {
            try T.fetchAll($0, sql: query, arguments: values)
        }
    }
    
    func getOne<T: FetchableRecord>(from query: String, with values: StatementArguments) throws -> T? {
        return try db.read {
            try T.fetchOne($0, sql: query, arguments: values)
        }
    }
    
    func backup() async throws {
        let exportPath = FileManager.default.temporaryDirectory.appendingPathComponent("/app_db_backup_\(UUID().uuidString)")
        
        // copy the contents to export path
        try db.backup(to: DatabaseQueue(path: exportPath.absoluteString))
        
        try await sync.uploadBackup(schemaVersion: 1, from: exportPath)
        try FileManager.default.removeItem(at: exportPath)
    }
}
