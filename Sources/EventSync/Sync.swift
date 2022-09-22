import Foundation
import CloudKit
import Combine
import Network

public struct SyncOptions {

    /// The UserDefaults suite to be used by EventSync.
    ///
    /// This suite should only be touched by EventSync. Do NOT manually access this suite from your app.
    let userDefaultsSuiteName: String

    /// The directory in which EventSync  stores queued events.
    ///
    /// This directory should only be touched by EventSync. Do NOT manually access this directory from your app.
    let localQueuedEventsDirectory: URL

    public init(userDefaultsSuiteName: String = "SyncSuite",
                localQueuedEventsDirectory: URL? = nil) {
        self.userDefaultsSuiteName = userDefaultsSuiteName
        self.localQueuedEventsDirectory = localQueuedEventsDirectory ?? getDocumentsDirectory().appendingPathComponent("/queued_events")
    }
}

public class Sync {
    private let recordsPublisher = PassthroughSubject<CKRecord, Never>()
    private let decodeFailures: PassthroughSubject<DecodeError, Never>

    private let uploadManager: Upload
    private let backupManager: BackupManager
    private let tokenManager: TokenManager
    private let downloadManager: Download

    /// Whether the device has previously synced
    public let previouslySynced: Bool
    /// Whether EventSync can fetch events. You must set this to true using `setReadyToFetch()`
    private(set) public var readyToFetch: Bool
    private let backupRestored: PassthroughSubject<Void, Never>

    let storage: UserDefaults
    let eventsZone: CKRecordZone
    let snapshotsZone: CKRecordZone
    let database: CKDatabase

    public init(database: CKDatabase, eventsZone: CKRecordZone, snapshotsZone: CKRecordZone, options: SyncOptions) {

        self.database = database
        self.storage = UserDefaults(suiteName: options.userDefaultsSuiteName)!
        decodeFailures = PassthroughSubject<DecodeError, Never>()
        backupRestored = PassthroughSubject<Void, Never>()
        self.snapshotsZone = snapshotsZone
        self.eventsZone = eventsZone

        if let data = storage.value(forKey: "LastFetchedToken") as? Data {
            tokenManager = TokenManager(storage: storage, initialToken: try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data))
            previouslySynced = true
        } else {
            tokenManager = TokenManager(storage: storage, initialToken: nil)
            previouslySynced = false
        }

        // the app must set this
        readyToFetch = false

        self.uploadManager = Upload(ckDatabase: database, eventsZone: eventsZone, snapshotsZone: snapshotsZone, options: options)
        self.downloadManager = Download(eventsZone: eventsZone, database: database, tokenManager: self.tokenManager)
        self.backupManager = BackupManager(snapshotsZone: snapshotsZone, database: database, storage: storage, tokenManager: tokenManager, download: downloadManager)

    }
    
    public func backupWasRestored() -> AnyPublisher<Void, Never> {
        return backupRestored.eraseToAnyPublisher()
    }
    
    /// Tell EventSync you're ready to receive events. This must be called once per app lifecycle to receive events.
    public func setReadyToFetch() {
        self.readyToFetch = true
    }

    /// Remove old backups.
    ///
    /// Call this at least once every app run.
    public func cleanBackups(keepMostRecent number: Int, version: Int) async throws {
        try await backupManager.cleanBackups(keepMostRecent: number, of: version)
    }

    /// Upload a backup which can be used to initialize a new installation of the app.
    public func uploadBackup(schemaVersion: Int, from file: URL) async throws {
        try await backupManager.uploadBackup(schemaVersion: schemaVersion, from: file)
    }

    /// Returns a publisher that emits events of type `T` as they are fetched.
    ///
    /// * Events created locally are also sent, once uploaded.
    /// * Errors encountered while fetching events are NOT handled by this publisher. Listen to `failedDecodes` to handle those.
    public func publisher<T: Event>(for _: T.Type) -> AnyPublisher<T, Never> {
        return recordsPublisher
            .filter{$0.recordType == T.typeID}
            .compactMap {
            do {
                return try T.init(from: Record(ckRecord: $0))
            } catch {
                self.decodeFailures.send(DecodeError(record: $0, error: error))
                return nil
            }
        }
        .eraseToAnyPublisher()
    }

    /// Returns a publisher that emits a `DecodeError` whenever a remote event cannot be decoded into the corresponding event type.
    ///
    /// Such errors should never come up, as CloudKit enforces the schema - any inconsistency is handled at upload time.
    public func failedDecodes() -> AnyPublisher<DecodeError, Never> {
        return decodeFailures.eraseToAnyPublisher()
    }

    /// If online, uploads `event`. If offline, queues `event` locally to be uploaded later.
    ///
    /// - Returns: `nil` if the upload was successful, or an `Error` if the event is queued for uploading later. This is NOT a fatal error - it was handled by the framework and is being returned in case you want to act on it.
    /// - Throws: If the event was not uploaded or saved. The event was not, and will not be, processed by EventSync
    public func uploadEvent<T: Event>(_ event: T) async throws -> Error? {
        return try await uploadManager.uploadEvent(event, recordsPublisher: recordsPublisher)
    }

    /// Fetches new events from the server.
    ///
    public func fetchEvents() async throws {
        if await backupManager.currentTask != nil {
            throw FetchError.restoringFromBackup
        }
        if !readyToFetch {
            throw FetchError.notReadyToFetch
        }

        let records = try await downloadManager.fetchCKRecordsAndSetToken()
        for record in records.sorted(by: {
            $0.creationDate! > $1.creationDate!
        }) {
            DispatchQueue.main.async {
                self.recordsPublisher.send(record)
            }
        }
    }

    /// Uploads all locally queued events
    ///
    /// Call when the device goes online and/or at regular intervals
    public func uploadQueuedEvents() async throws {
        try await uploadManager.uploadQueuedEvents()
    }

    /// Subscribes to notifications from CloudKit, if not already subscribed
    ///
    public func subscribeToNotifications() async throws {
        if storage.string(forKey: "CKSubscriptionID") == nil {
            let newSubscription = CKRecordZoneSubscription(zoneID: eventsZone.zoneID)
            let notification = CKSubscription.NotificationInfo()
            notification.shouldSendContentAvailable = true

            newSubscription.notificationInfo = notification

            return try await withCheckedThrowingContinuation { continuation in
                database.save(newSubscription) { (subscription, error) in
                    if let sub = subscription {
                        self.storage.set(sub.subscriptionID, forKey: "CKSubscriptionID")
                    }
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// Calls `fetchEvents` if `userInfo` is a CloudKit notification.
    ///
    /// - Throws: any error from `fetchEvents`
    public func handleNotification(_ userInfo: [AnyHashable: Any]) async throws {
        if CKNotification(fromRemoteNotificationDictionary: userInfo) != nil {
            try await fetchEvents()
        }
    }

    /// Deletes the stored change token, last event ID, and subscription.
    ///
    public func reset() async throws {

        await tokenManager.setToken(nil)

        if let subscriptionID = storage.string(forKey: "CKSubscriptionID") {
            let _: Void = try await withCheckedThrowingContinuation { continuation in
                database.delete(withSubscriptionID: subscriptionID) { _, err in
                    if let err = err {
                        continuation.resume(throwing: err)
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            }
        }

        storage.removeObject(forKey: "CKSubscriptionID")
    }

    /// Checks to make sure `eventsZone` and `snapshotsZone` exist. If not, creates the missing zones.
    public func createZones() async throws {
        for zone in [eventsZone, snapshotsZone] {
            let _: Void = try await withCheckedThrowingContinuation { continuation in
                database.fetch(withRecordZoneID: zone.zoneID) { res, err in
//                    if let err = err, (err as? CKError)?.code != CKError.zoneNotFound {
//                        continuation.resume(throwing: CreateZonesError.whileChecking(err))
//                    } else {
                        if res == nil {
                            self.database.save(zone) { _, err in
                                if let err = err {
                                    continuation.resume(throwing: CreateZonesError.whileSaving(err))
                                } else {
                                    continuation.resume()
                                }
                            }
                        } else {
                            continuation.resume()
                        }
//                    }
                }
            }
        }
    }

    /// Attempts to restore from a backup with the specified `schemaVersion`.
    /// - Parameters:
    ///     - schemaVersion: only tries backups with this schema version
    ///     - migration: closure called for every matching backup. Takes a `URL` pointing to the backup file. Returns a `Bool` indicating if the migration was successful. Return `true` if you are done restoring. If you return `false`, EventSync will try another backup if available.
    ///
    /// New events may have occurred since the backup was taken. Make sure to call `fetchEvents()` after this function returns.
    public func restoreFromBackup(version: Int, migration: @escaping (URL) async -> Bool) async throws {
        let token = try await backupManager.restoreFromBackup(with: version, migration: migration)
        try await didRestoreBackup(with: token)
    }

    /// Updates the current change token to match the backup that was just restored from. Fetches all events that happened after,
    ///
    /// Call this method only after backing up from a custom source. EventSync calls
    /// Errors that arise while fetching events are wrapped in `BackupRestoreError.whileFetchingChanges`
    public func didRestoreBackup(with changeToken: CKServerChangeToken) async throws {
        await self.tokenManager.setToken(changeToken)
        backupRestored.send()
    }
}

// MARK: Errors

enum CreateZonesError: Error {
    /// The error happened while checking for zone existence
    case whileChecking(Error)

    /// The error happened while saving the zone to CloudKit
    case whileSaving(Error)
}

/// Relates a decoding error to its `CKRecord`.
///
/// Should not happen since CloudKit enforces 
public struct DecodeError {
    /// The record involved
    var record: CKRecord

    /// The error
    var error: Error
}

/// Enforces serial access to the server change token
actor TokenManager {
    init(storage: UserDefaults, initialToken: CKServerChangeToken? = nil) {
        self.storage = storage
        self.ckToken = initialToken
    }

    let storage: UserDefaults
    var ckToken: CKServerChangeToken?

    public func setToken(_ t: CKServerChangeToken?) {

        self.ckToken = t
        if let tok = t {
            let data = try! NSKeyedArchiver.archivedData(withRootObject: tok, requiringSecureCoding: false)
            storage.set(data, forKey: "LastFetchedToken")
        } else {
            storage.removeObject(forKey: "LastFetchedToken")
        }
    }
}
