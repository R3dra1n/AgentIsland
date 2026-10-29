import Foundation
import Combine

public enum LightingMode: Equatable, Sendable {
    case idle, dimmed, flashing, steadyBright
}

@MainActor
protocol BacklightDevice: AnyObject {
    var isAvailable: Bool { get }
    func getBrightness() -> Float?
    @discardableResult func setBrightness(_ value: Float) -> Bool
    func getAutoBrightness() -> Bool?
    @discardableResult func setAutoBrightness(_ enabled: Bool) -> Bool
}

struct BacklightSnapshot: Codable, Equatable {
    let brightness: Float
    let automatic: Bool
}

/// Every state change and hardware write runs on the main actor, including shutdown.
@MainActor
public final class BacklightEngine: ObservableObject {
    public static let shared = BacklightEngine(device: CoreBrightnessBridge.shared)
    private let device: any BacklightDevice
    private let defaults: UserDefaults
    private let recoveryKey = "backlightRecoverySnapshot"
    private var snapshot: BacklightSnapshot?
    private var animation: Task<Void, Never>?
    private var lastWritten: Float?
    private var generation: UInt64 = 0
    private var suspended = false
    private var manualOverride = false
    @Published public private(set) var status = "待命"
    public var isAvailable: Bool { device.isAvailable }

    public var isEnabled = true {
        didSet {
            guard oldValue != isEnabled else { return }
            if isEnabled { manualOverride = false }
            applyCurrentMode()
        }
    }
    public var dimmedBrightness: Float = 0.10 {
        didSet { if currentMode == .dimmed { applyCurrentMode() } }
    }
    public var brightBrightness: Float = 0.85 {
        didSet { if currentMode == .steadyBright { applyCurrentMode() } }
    }
    public private(set) var currentMode: LightingMode = .idle

    init(device: any BacklightDevice, defaults: UserDefaults = .standard) {
        self.device = device; self.defaults = defaults
        if let data = defaults.data(forKey: recoveryKey),
           let saved = try? JSONDecoder().decode(BacklightSnapshot.self, from: data),
           saved.brightness.isFinite, (0...1).contains(saved.brightness) {
            snapshot = saved
            restore()
        }
        if !device.isAvailable { status = "背光接口不可用" }
    }

    public func setMode(_ mode: LightingMode) {
        guard currentMode != mode else { return }
        currentMode = mode
        applyCurrentMode()
    }

    public func suspend() { suspended = true; stopAnimation(); restore() }
    public func resume() { suspended = false; applyCurrentMode() }
    public func shutdown() { suspended = true; currentMode = .idle; stopAnimation(); restore() }

    private func stopAnimation() {
        generation &+= 1
        animation?.cancel(); animation = nil
    }

    private func acquire() -> Bool {
        if snapshot != nil { return device.setAutoBrightness(false) }
        guard device.isAvailable, let level = device.getBrightness(), let auto = device.getAutoBrightness() else {
            status = "无法读取背光状态，未接管"; return false
        }
        snapshot = BacklightSnapshot(brightness: level, automatic: auto)
        defaults.set(try? JSONEncoder().encode(snapshot), forKey: recoveryKey)
        guard device.setAutoBrightness(false) else {
            status = "无法关闭自动调光"; restore(); return false
        }
        return true
    }

    private func restore(preserveManualBrightness: Bool = false) {
        guard let snapshot else { return }
        let levelOK = preserveManualBrightness || device.setBrightness(snapshot.brightness)
        let autoOK = device.setAutoBrightness(snapshot.automatic)
        if levelOK && autoOK {
            defaults.removeObject(forKey: recoveryKey)
            self.snapshot = nil
            lastWritten = nil
            status = "已恢复背光设置"
        } else { status = "恢复失败；保留恢复记录，下次启动重试" }
    }

    func checkManualOverride() -> Bool {
        guard let lastWritten, let current = device.getBrightness(), abs(current - lastWritten) > 0.05 else { return false }
        manualOverride = true
        stopAnimation()
        restore(preserveManualBrightness: true)
        status = "检测到手动或系统调光；关闭再开启背光联动以恢复"
        return true
    }

    private func write(_ brightness: Float) -> Bool {
        guard brightness.isFinite else { status = "亮度设置无效"; return false }
        let level = min(1, max(0, brightness))
        guard device.setBrightness(level) else {
            status = "背光写入失败"; return false
        }
        lastWritten = level
        return true
    }

    private func applyCurrentMode() {
        stopAnimation()
        guard isEnabled, !suspended, currentMode != .idle, !manualOverride else { restore(); return }
        guard !checkManualOverride(), acquire() else { return }
        let initial = currentMode == .dimmed ? dimmedBrightness : brightBrightness
        guard write(initial) else { restore(); return }
        status = "背光联动中"
        let token = generation
        let start = ProcessInfo.processInfo.systemUptime
        animation = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard let self, self.generation == token, self.isEnabled, !self.suspended else { return }
                guard !self.checkManualOverride() else { return }
                if self.currentMode == .flashing {
                    let phase = (ProcessInfo.processInfo.systemUptime - start).truncatingRemainder(dividingBy: 1.4)
                    let pulse = phase < 0.2 ? sin(phase / 0.2 * .pi) : (phase >= 0.3 && phase < 0.5 ? sin((phase - 0.3) / 0.2 * .pi) : 0)
                    if !self.write(Float(pulse) * self.brightBrightness) { self.restore(); return }
                } else {
                    do { try await Task.sleep(for: .milliseconds(950)) } catch { return }
                }
            }
        }
    }
}
