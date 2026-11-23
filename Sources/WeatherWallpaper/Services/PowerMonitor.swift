import Foundation
import IOKit.ps

/// Native power-source notifications, not a battery polling timer or an external process.
@MainActor
final class PowerMonitor {
    private var source: CFRunLoopSource?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) { self.onChange = onChange }

    static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return type as String == kIOPSBatteryPowerValue
    }

    func start() {
        guard source == nil else { return }
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            // This source is installed exclusively on the main run loop.
            MainActor.assumeIsolated {
                Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue().onChange()
            }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }
}
