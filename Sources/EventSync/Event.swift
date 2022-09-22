//
//  Event.swift
//  
//
//  Created by Atulya Weise on 9/18/22.
//

import Foundation
import CloudKit

/// All event types should conform to this protocol
public protocol Event: Codable {

    /// Identifies the event type so EventSync can send it from the right publisher.
    ///
    /// DO NOT change this! If a new version of your app has a different `typeID` for the same event, devices running the older version will not be able to handle the events created in the newer version.
    ///
    /// Example: For struct `Follow`, the typeID could be "follow"
    static var typeID: String {get}

    var id: UUID { get }

    /// Gets called by EventSync when uploading this event. `record` is already initialized; set properties using the subscript. All types must conform to CKRecordValue, use a cast if necessary.
    func to(record: Record) throws

    /// Gets called by EventSync when a new event is downloaded.
    ///
    /// If decoding was not successful (fields missing, wrong types, etc), throw an error. EventSync does not handle the error; syncing continues and this event does not get processed. It is the app's responsiblity to handle any decoding errors. The error will be sent from `Sync`'s `failedDecodes` publisher. If you follow the CloudKit rules for schema updates (additive only), these errors should not occur.
    init(from record: Record) throws

}

/// Abstraction layer over `CKRecord`, used in the `Event` methods
public class Record {
    private var ckRecord: CKRecord

    init(ckRecord: CKRecord) {
        self.ckRecord = ckRecord
    }

    public subscript(key: String) -> CKRecordValue? {
        get {
            return ckRecord[key]
        }
        set {
            ckRecord[key] = newValue
        }
    }
}
