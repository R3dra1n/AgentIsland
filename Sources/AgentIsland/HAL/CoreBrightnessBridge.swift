import Foundation
import os.log

private let logger = Logger(subsystem: "com.antigravity.AgentIsland", category: "CoreBrightnessBridge")

@MainActor
public final class CoreBrightnessBridge: BacklightDevice {
    public static let shared = CoreBrightnessBridge()

    private var client: AnyObject?
    private var keyboardID: UInt64?

    // Function signatures
    private typealias GetBrightnessFunc = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias SetBrightnessFunc = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
    private typealias EnableAutoBrightnessFunc = @convention(c) (AnyObject, Selector, Bool, UInt64) -> Bool
    private typealias IsAutoBrightnessEnabledFunc = @convention(c) (AnyObject, Selector, UInt64) -> Bool

    private var getBrightnessFn: GetBrightnessFunc?
    private var setBrightnessFn: SetBrightnessFunc?
    private var enableAutoBrightnessFn: EnableAutoBrightnessFunc?
    private var isAutoBrightnessEnabledFn: IsAutoBrightnessEnabledFunc?

    private let getBrightnessSel = NSSelectorFromString("brightnessForKeyboard:")
    private let setBrightnessSel = NSSelectorFromString("setBrightness:forKeyboard:")
    private let enableAutoBrightnessSel = NSSelectorFromString("enableAutoBrightness:forKeyboard:")
    private let isAutoBrightnessEnabledSel = NSSelectorFromString("isAutoBrightnessEnabledForKeyboard:")


    private init() {
        setupBridge()
    }

    private func setupBridge() {
        guard let bundle = Bundle(path: "/System/Library/PrivateFrameworks/CoreBrightness.framework") else {
            logger.error("Failed to find CoreBrightness.framework bundle")
            return
        }

        if !bundle.isLoaded {
            bundle.load()
        }

        guard let clientClass = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else {
            logger.error("Failed to load KeyboardBrightnessClient class")
            return
        }

        let instance = clientClass.init()
        self.client = instance

        // Setup methods
        if let method = class_getInstanceMethod(type(of: instance), getBrightnessSel) {
            self.getBrightnessFn = unsafeBitCast(method_getImplementation(method), to: GetBrightnessFunc.self)
        }
        if let method = class_getInstanceMethod(type(of: instance), setBrightnessSel) {
            self.setBrightnessFn = unsafeBitCast(method_getImplementation(method), to: SetBrightnessFunc.self)
        }
        if let method = class_getInstanceMethod(type(of: instance), enableAutoBrightnessSel) {
            self.enableAutoBrightnessFn = unsafeBitCast(method_getImplementation(method), to: EnableAutoBrightnessFunc.self)
        }
        if let method = class_getInstanceMethod(type(of: instance), isAutoBrightnessEnabledSel) {
            self.isAutoBrightnessEnabledFn = unsafeBitCast(method_getImplementation(method), to: IsAutoBrightnessEnabledFunc.self)
        }

        // Obtain keyboard IDs
        guard instance.responds(to: NSSelectorFromString("copyKeyboardBacklightIDs")) else { return }
        if let ids = instance.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [UInt64],
           let firstID = ids.first {
            self.keyboardID = firstID
            logger.info("Discovered keyboard backlight ID: \(firstID)")


        } else {
            logger.warning("No keyboard backlight IDs discovered on this machine")
        }
    }

    public var isAvailable: Bool {
        return client != nil && keyboardID != nil && setBrightnessFn != nil && getBrightnessFn != nil && enableAutoBrightnessFn != nil && isAutoBrightnessEnabledFn != nil
    }

    public func getBrightness() -> Float? {

        guard let client = client, let kbdID = keyboardID, let fn = getBrightnessFn else {
            return nil
        }
        let value = fn(client, getBrightnessSel, kbdID)
        return value.isFinite && (0...1).contains(value) ? value : nil
    }

    @discardableResult
    public func setBrightness(_ value: Float) -> Bool {

        guard let client = client, let kbdID = keyboardID, let fn = setBrightnessFn else {
            return false
        }
        guard value.isFinite else { return false }
        let clamped = max(0.0, min(1.0, value))
        return fn(client, setBrightnessSel, clamped, kbdID)
    }

    public func getAutoBrightness() -> Bool? {
        guard let client, let keyboardID, let fn = isAutoBrightnessEnabledFn else { return nil }
        return fn(client, isAutoBrightnessEnabledSel, keyboardID)
    }

    public func setAutoBrightness(_ enabled: Bool) -> Bool {
        guard let client, let keyboardID, let fn = enableAutoBrightnessFn else { return false }
        return fn(client, enableAutoBrightnessSel, enabled, keyboardID)
    }
}
