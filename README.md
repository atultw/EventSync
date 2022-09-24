# EventSync



## Why CloudKit?

Many apps don't involve sharing data between users, so setting up a backend is overkill. CloudKit allows developers to sync data between a user's devices without an app server; everything is stored in iCloud.

## Why Event Sourcing?

For consistency.

CloudKit is great, but doesn't have offline caching built-in so operations fail when offline. Apple's answer is Core Data with CloudKit. However, CoreData is very opaque and hides a lot of "magic". To have more control, a custom solution like EventSync is needed. You could take the CoreData/CloudKit route and map your db models to cloudkit 1:1, but that gets messy. There is no good way to merge automatically with conflicts. Even git leaves it up to the human. Thus, EventSync takes a different route: Event sourcing. 

What is it that leads to each record creation, update, and deletion? An action by the user (an event). Just like the events on a UIView. This action results in changes to the database state, view updates, etc. Instead of trying to keep the state of all these affected resources in sync, why not just notify other devices of **the cause** and not the effects? This is event sourcing: <u>**state as a function of an event sequence.**</u> The following example shows the benefits of event sourcing.

Consider a music app with this model:

```swift
struct Track {
  let id: Int
  let plays: Int
}
```

Every time the track is played, `plays` is incremented. Specifically, an sql statement along the lines of `UPDATE track SET plays = plays + 1 WHERE id = $0` is run. 

A given track has one play. The user's phone is offline for an extended period and plays the track 10 times on their phone, 5 times on their laptop. **With a traditional state-syncing model, when the phone comes online, only one version "wins"**: either 11 plays or 6 plays. And both are <u>wrong</u>! The correct number is 16 (1+10+5). Let's solve this with event sourcing:

```swift
struct PlayEvent: Event {
  let trackID: Int
}
```

Each time the track is played, a `PlayEvent` is added to the phone's local queue. The same SQL statement is executed as well.

When the phone comes online, the 10 queued events are uploaded. Laptop finds out about the 10 plays and updates its local sqlite store accordingly. Phone learns of the laptop's 5 plays and does the same. Both devices have the right number of plays. Great. 



## Backups

It's not practical to build the current state from an entire event history with potentially tens of thousands of events. That's why taking snapshots, or backups, of the current state for use with new devices is helpful. The example code below shows how you can initialize a new installation from a backup, and process all necessary events. 



## Get Started

It's easy to integrate EventSync into your app:

* Make your event types conform to the `Event` protocol. 

* Listen for new events and handle them:
  * Create/Update/Delete in your local database:

    ```swift
    sync.publisher(for: TodoCreationEvent.self)
    	.sink { val in
    		do {
    			try db.write { 
    				try val.model.insert($0)
    			}
    		} catch {
    			print("Could not process remote event: \(error)")
    		}
    	}
    	.store(in: &subscriptions)
    ```

  * Update views:

    ```swift
    someView.onReceive(sync.publisher(for: TodoCreationEvent.self)) {
    	todos.append($0.model)
    }
    ```

* Send events (like "todo created") using `Sync.uploadEvent(_:)`

  * **Only** call this method. EventSync will send it to your listeners automatically. Do not write to disk, upload views etc outside of event listeners. 

* Implement the flow described in "App Lifecycle" below

* (Optional) Enable automatic sync:

  * Enable the remote notifications entitlement
  * Call `subscribeToNotifications()` every app launch
  * Call `handleNotification(_:)` inside the application delegate's `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)` 

## App Lifecycle

Do the following early on in the app lifecycle (for example in app delegate's `application(_:didFinishLaunchingWithOptions:)`). Why isn't this wrapped into one "startup" function? So that you can handle errors accurately. No magic.

1. Attach combine subscribers for each event type
2. Call `Sync.createZones()` - checks that the zones exist and creates them if not
3. Call `Sync.subscribeToNotifications()` only if you want automatic event fetches
4. Restore from backup (if necessary), upload, clean up backups
5. IMPORTANT: tell EventSync you are ready to receive events: `Sync.setReadyToFetch(true)`
6. Call `Sync.fetchEvents()` 

Example implementation:

```swift
// 1
sync.publisher(for: TodoCreationEvent.self)
	.sink { value in
  	saveToDatabase(value.model)
  }
	.store(in: &self.subscriptions)

// 2
try await sync.createZones()

// 3
try await sync.subscribeToNotifications()

// 4
if !sync.previouslySynced {
  do {
    try await sync.restoreFromBackup(version: 1) { ... }
  } catch {
    do {
      // try a backup from another source
      let token = try getBackupManually()
      sync.didRestoreBackup(with: token)
    } catch {
      // no backups at all. start fresh
      initializeDb()
    }
  }
} else {
  try await sync.uploadBackup(schemaVersion: 1, from: URL(string: db.path)!)
  try await sync.cleanBackups(keepMostRecent: 5, version: 1)
}

// 5
sync.setReadyToFetch(true)

// 6
try await sync.fetchEvents()
```



## Migration

As you add features to your app, your data models will change. EventSync is based on CloudKit, which requires schema changes to be additive (meaning you should not delete fields from your event types). Keep in mind the following:
* Only add new fields. Do not rename or remove existing ones.
* Some users may be running older versions which cannot handle new events if you remove/rename fields.

Follow this general process for schema updates:
1. Declare the new field in your swift event struct

2. Update the `to(record:)` implementation

3. Update the `init(from record:)` implementation. Make sure to include default values for new fields;  some events may be created on older versions

Ex: 

```swift
init(from record: Record) throws {
	self.id = UUID(uuidString: record["id"] as! String)!
	self.model = Todo(
    id: record["todo_id"] as! String,
		name: record["todo_name"] as! String,
		createdAt: record["todo_createdAt"] as! Date,
		dueDate: (record["todo_dueDate"] as? Date) ?? Date.distantPast // default value
  )
}
```

4.  Write migrations for your local database. For example, run `ALTER TABLE`s for sqlite. This is not necessary if you use Realm or another schemaless store - although you may want to insert default values for existing objects. 
4.  IMPORTANT! Change the `schemaVersion` that gets passed to EventSync's backup functions. If a user starts using the new features on one device, and later updates their other device, you want the second device not to use default values but to pick up where device 1 left off. This can be achieved through updating the schemaVersion.
