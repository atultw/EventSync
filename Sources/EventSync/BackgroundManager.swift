//
//  Manager.swift
//  
//
//  Created by Atulya Weise on 9/13/22.
//

import Foundation
import Network
import Combine

/// Works in the background to receive/send events, reacts to network changes, and delivers updates via a publisher
public class BackgroundManager {
    let sync: Sync
    let network: NWPathMonitor

    // options
    let autoDownloadWhenOnline: Bool
    let autoUploadWhenOnline: Bool

    private let errors = PassthroughSubject<Error, Never>()

    public init(managing sync: Sync,
                autoDownloadWhenOnline: Bool = true,
                autoUploadWhenOnline: Bool = true
    ) {
        self.sync = sync

        self.autoDownloadWhenOnline = autoDownloadWhenOnline
        self.autoUploadWhenOnline = autoUploadWhenOnline

        self.network = NWPathMonitor()
        let queue = DispatchQueue(label: "EventSyncNetworkMonitor")
        network.start(queue: queue)

        self.listenToNetwork()
    }

    private func listenToNetwork() {
        network.pathUpdateHandler = { newPath in
            if newPath.status == .satisfied {
                if self.autoDownloadWhenOnline {
                    Task {
                        do {
                            try await self.sync.fetchEvents()
                        } catch {
                            self.errors.send(error)
                        }
                    }
                }
                if self.autoUploadWhenOnline {
                    Task {
                        do {
                            try await self.sync.uploadQueuedEvents()
                        } catch {
                            self.errors.send(error)
                        }
                    }
                }
            }
        }
    }

    /// Returns a publisher that emits non-critical errors that arise during the background sync processes
    ///
    /// These errors are not critical as they do not break the sync process, but may be worth handling anyway (such as internet offline, iCloud signed out).
    public func nonCriticalNotices() -> AnyPublisher<Error, Never> {
        return errors.eraseToAnyPublisher()
    }

}
