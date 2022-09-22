//
//  Helpers.swift
//  
//
//  Created by Atulya Weise on 9/18/22.
//

#if !os(macOS)
import UIKit
#else
import IOKit
#endif

import Foundation

func getClientID() async -> String {
#if !os(macOS)
    return await UIDevice.current.identifierForVendor!.uuidString

#else
    return macSerialNumber()
#endif
}

func getDocumentsDirectory() -> URL {
    let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
    let documentsDirectory = paths[0]
    return documentsDirectory
}

#if os(macOS)
func macSerialNumber() -> String {

        // Get the platform expert
        let platformExpert: io_service_t = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        // Get the serial number as a CFString ( actually as Unmanaged<AnyObject>! )
    let serialNumberAsCFString = IORegistryEntryCreateCFProperty(platformExpert, kIOPlatformSerialNumberKey as CFString, kCFAllocatorDefault, 0)

        // Release the platform expert (we're responsible)
        IOObjectRelease(platformExpert)

        // Take the unretained value of the unmanaged-any-object
        // (so we're not responsible for releasing it)
        // and pass it back as a String or, if it fails, an empty string
    return "mac_" + (serialNumberAsCFString!.takeUnretainedValue() as! String)

    }
#endif
