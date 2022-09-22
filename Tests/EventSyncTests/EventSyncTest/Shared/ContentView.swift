//
//  ContentView.swift
//  Shared
//
//  Created by Atulya Weise on 9/13/22.
//

import SwiftUI
import GRDB
import Combine
import CloudKit

struct Todo: Codable, Identifiable, FetchableRecord, PersistableRecord {
    var id: String
    var name: String
    var createdAt: Date
    var dueDate: Date
}

struct ContentView: View {
    @State var todos: [Todo] = []
    
    @State var title: String = ""
    
    @State var notice: String?
    
    var body: some View {
        VStack {
            TextField("Title", text: $title)
            Button("Add") {
                let event = TodoCreationEvent(model: Todo(id: UUID().uuidString, name: title, createdAt: Date(), dueDate: Date().addingTimeInterval(86_400)))
                Task {
                    do {
                        try await Repository.shared.sync.uploadQueuedEvents()
                    } catch {
                        notice = error.localizedDescription
                    }
                    do {
                        if let unimportantError = try await Repository.shared.sync.uploadEvent(event) {
                            notice = unimportantError.localizedDescription
                        }
                    } catch {
                        print("failed to upload or queue event:", error)
                    }
                }
            }
            Button("Reset") {
                Task {
                    try await Repository.shared.sync.reset()
                    try Repository.shared.db.close()
                    do {
                    try FileManager.default.removeItem(at: getDocumentsDirectory().appendingPathComponent("/db.sqlite"))
                    } catch {
                        print(error)
                    }
                    print("reset")
                }
            }
            Button("Refresh") {
                Task {
                    do {
                        try await Repository.shared.sync.fetchEvents()
                    } catch CKError.changeTokenExpired {
                        do {
                        try await Repository.shared.restoreFromBackup()
                        } catch {
                            print("no backups available. Find a different backup source or start fresh")
                            try await Repository.shared.sync.reset()
                        }
                    }
                }
            }
            List {
                ForEach(todos.sorted(by: {$0.createdAt < $1.createdAt}), id: \.id) { todo in
                    VStack(alignment: .leading) {
                        Text(todo.name)
                        Text("Due:" + todo.dueDate.description)
                    }
                }
                .onDelete(perform: { offsets in
                    for offset in offsets {
                        let event = TodoDeletionEvent(modelId: todos[offset].id)
                        Task {
                            do {
                                do {
                                    try await Repository.shared.sync.uploadQueuedEvents()
                                } catch {
                                    notice = error.localizedDescription
                                }
                                if let unimportantError = try await Repository.shared.sync.uploadEvent(event) {
                                    notice = unimportantError.localizedDescription
                                }
                            } catch {
                                print("failed to upload or queue event:", error)
                            }
                        }
                    }
                })
            }
        }
        .onAppear(perform: listTodos)
        .onReceive(Repository.shared.sync.backupWasRestored(), perform: listTodos)
        .onReceive(Repository.shared.sync.publisher(for: TodoCreationEvent.self)) {
            todos.append($0.model)
        }
        .onReceive(Repository.shared.sync.publisher(for: TodoDeletionEvent.self)) { event in
            todos.removeAll(where: {$0.id==event.modelId})
        }
        .alert(item: $notice, content: {n in Alert(title: Text(n))})
    }
    
    func listTodos() {
        Task {
            do {
                todos = try Repository.shared
                    .list("SELECT * FROM todo", with: [])
            } catch {
                print(error)
            }
        }
    }
}

extension String: Identifiable {
    public var id: String {
        return self
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

func getDocumentsDirectory() -> URL {
    let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
    let documentsDirectory = paths[0]
    return documentsDirectory
}

