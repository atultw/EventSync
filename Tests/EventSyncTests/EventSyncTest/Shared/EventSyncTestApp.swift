//
//  EventSyncTestApp.swift
//  Shared
//
//  Created by Atulya Weise on 9/13/22.
//

import SwiftUI

@main
struct EventSyncTestApp: App {
    #if !os(macOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    #else
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    #endif
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

#if !os(macOS)
import UIKit
class AppDelegate: NSObject, UIApplicationDelegate
{
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        
        application.registerForRemoteNotifications()
        
        // Check if the zones exist and create them if necessary - to avoid errors later on
        Task {
            do {
                try await Repository.shared.sync.createZones()
            } catch {
                print("while checking/creating zones: \(error)")
            }
            try await Repository.shared.sync.subscribeToNotifications()
        }
        
        return true
    }
    
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task {
            do {
                try await Repository.shared.sync.handleNotification(userInfo)
            } catch {
                print("failed to handle the notification", error)
            }
        }
        completionHandler(.newData)
    }
}
#else
import AppKit
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
        
        // Check if the zones exist and create them if necessary - to avoid errors later on
        Task {
            do {
                try await Repository.shared.sync.createZones()
            } catch {
                print("while checking/creating zones: \(error)")
            }
            try await Repository.shared.sync.subscribeToNotifications()
        }
    }
    
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String : Any]) {
        Task {
            do {
                try await Repository.shared.sync.handleNotification(userInfo)
            } catch {
                print("failed to handle the notification", error)
            }
        }
    }
}
#endif
