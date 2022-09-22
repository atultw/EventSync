//
//  Upload.swift
//  
//
//  Created by Atulya Weise on 9/15/22.
//

import CloudKit
import Combine

enum UploadError: Error {
    /// An error  occurred while trying to save the event to a local offline queue. The event was not saved.
    case offlineQueueError(Error)
}

enum UploadQueuedError: Error {
    /// Failed to load an event from the local queue. The event was not uploaded to CloudKit.
    case decodeError(Error)

    /// Failed to upload the event to CloudKit.
    case whileUploading(Error)

    /// Failed to delete the event (before uploading). No more events were uploaded.
    case whileDeleting(Error)
}

actor Upload {
    let eventsZone: CKRecordZone
    let snapshotsZone: CKRecordZone
    let ckDatabase: CKDatabase
    var subscriptions: [AnyCancellable] = []
    let options: SyncOptions
    let storage: UserDefaults

    private var uploadQueuedEventsTask: Task<Void, Error>?

    init(ckDatabase: CKDatabase,
         eventsZone: CKRecordZone,
         snapshotsZone: CKRecordZone,
         options: SyncOptions) {

        self.ckDatabase = ckDatabase
        self.eventsZone = eventsZone
        self.snapshotsZone = snapshotsZone
        self.options = options

        self.storage = UserDefaults(suiteName: options.userDefaultsSuiteName)!
        //        self.ordering = Ordering(userDefaults: storage)

        // create the queued events directory if it doesn't yet exist
        if !FileManager.default.fileExists(atPath: options.localQueuedEventsDirectory.absoluteString) {
            try! FileManager.default.createDirectory(at: options.localQueuedEventsDirectory, withIntermediateDirectories: true)
        }

    }

    func uploadEvent<T: Event>(_ event: T, recordsPublisher: PassthroughSubject<CKRecord, Never>) async throws -> Error? {

        let record = CKRecord(recordType: T.typeID, recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: eventsZone.zoneID))
        try event.to(record: Record(ckRecord: record))
        record["sync_client"] = await getClientID()
        //        record["happened_after"] = await ordering.getLastEventID()

        return try await withCheckedThrowingContinuation { continuation in
            ckDatabase.save(record, completionHandler: {res, err in
                if let err = err {
                    do {
                        // the record is still being queued so this isn't a critical error
                        let encoded = try NSKeyedArchiver.archivedData(withRootObject: record,
                                                                       requiringSecureCoding: true)
                        try encoded.write(to: self.options.localQueuedEventsDirectory.appendingPathComponent("/\(event.id.uuidString)"))
                        DispatchQueue.main.async {
                            recordsPublisher.send(record)
                        }
                        // return the non critical error
                        continuation.resume(returning: err)
                    } catch {
                        continuation.resume(throwing: UploadError.offlineQueueError(error))
                    }
                } else if let rec = res {
                    DispatchQueue.main.async {
                        recordsPublisher.send(rec)
                    }
                    continuation.resume(returning: nil)
                }
            })
        }
    }

    func uploadQueuedEvents() async throws {
        if let uploadTask = uploadQueuedEventsTask {
            uploadTask.cancel()
            uploadQueuedEventsTask = nil
        }
        uploadQueuedEventsTask = Task {
            defer {
                uploadQueuedEventsTask = nil
            }
            for url in try FileManager.default.contentsOfDirectory(at: options.localQueuedEventsDirectory, includingPropertiesForKeys: nil, options: []) {
                if Task.isCancelled {
                    return
                }

                var record: CKRecord?
                // decode record from file
                do {
                    record = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: Data(contentsOf: url))
                } catch {
                    throw UploadQueuedError.decodeError(error)
                }
                if let record = record {

                    // try to upload the record
                    do {
                        let _: Void = try await withCheckedThrowingContinuation { continuation in
                            ckDatabase.save(record, completionHandler: {_, err in
                                if let err = err {
                                    continuation.resume(throwing: err)
                                } else {
                                    continuation.resume()
                                }
                            })
                        }
                    } catch {
                        throw UploadQueuedError.whileUploading(error)
                    }

                    // delete the file if upload was successful
                    do {
                        try FileManager.default.removeItem(at: url)
                    } catch {
                        throw UploadQueuedError.whileDeleting(error)
                    }

                }

                // don't continue if the task is cancelled
                if Task.isCancelled {
                    return
                }
            }
        }

        // safe to unwrap
        return try await uploadQueuedEventsTask!.value
    }

}
