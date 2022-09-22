import Foundation
import EventSync

struct TodoCreationEvent {
    
    var id: UUID = UUID()
    
    var model: Todo
}

extension TodoCreationEvent: Event {
    static let typeID = "TodoCreationEvent"
    
    func to(record: Record) throws {
        record["id"] = self.id.uuidString as NSString
        record["todo_id"] = self.model.id as NSString
        record["todo_name"] = self.model.name as NSString
        record["todo_createdAt"] = self.model.createdAt as NSDate
        record["todo_dueDate"] = self.model.dueDate as NSDate
    }
    
    init(from record: Record) throws {
        self.id = UUID(uuidString: record["id"] as! String)!
        self.model = Todo(id: record["todo_id"] as! String,
                          name: record["todo_name"] as! String,
                          createdAt: record["todo_createdAt"] as! Date,
                          dueDate: (record["todo_dueDate"] as? Date) ?? Date.distantPast)
    }
}

struct TodoDeletionEvent {
    var id: UUID = UUID()
    
    var modelId: String
}

extension TodoDeletionEvent: Event {
    static let typeID = "TodoDeletionEvent"
    
    init(from record: Record) {
        self.id = UUID(uuidString: record["id"] as! String)!
        self.modelId = record["modelId"] as! String
    }
    
    func to(record: Record) throws {
        record["id"] = self.id.uuidString as NSString
        record["modelId"] = self.modelId as NSString
    }
    
}

struct TodoUpdateEvent {
    var id: UUID
    
    var modelId: String
    var newModel: Todo
}

extension TodoUpdateEvent: Event {
    
    static let typeID = "TodoUpdateEvent"
    
    init(from record: Record) throws {
        self.id = UUID(uuidString: record["id"] as! String)!
        self.modelId = record["modelId"] as! String
        self.newModel = try JSONDecoder().decode(Todo.self, from: record["model"] as! Data)
    }
    
    func to(record: Record) throws {
        record["id"] = self.id.uuidString as NSString
        record["modelId"] = self.modelId as NSString
        record["newModel"] = try JSONEncoder().encode(self.newModel) as NSData
    }
}
