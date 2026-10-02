import Combine
import Network
import SwiftUI
import UIKit

/// Battery level and network type of the phone – shown in fullscreen, where iOS hides the
/// status bar. (iOS gives regular apps no access to Wi-Fi signal strength, so only the
/// connection type is shown.)
@MainActor
final class DeviceStatusMonitor: ObservableObject {
    enum Connection {
        case wifi
        case cellular
        case wired
        case other
        case offline
    }

    @Published private(set) var batteryLevel: Int?
    @Published private(set) var isCharging = false
    @Published private(set) var connection: Connection = .other

    private let pathMonitor = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        updateBattery()

        let names = [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification]
        for name in names {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateBattery()
                }
            }
            observers.append(observer)
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let connection = DeviceStatusMonitor.connection(for: path)
            MainActor.assumeIsolated {
                self?.connection = connection
            }
        }
        pathMonitor.start(queue: .main)
    }

    deinit {
        pathMonitor.cancel()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func updateBattery() {
        let device = UIDevice.current
        batteryLevel = device.batteryLevel >= 0 ? Int((device.batteryLevel * 100).rounded()) : nil
        isCharging = device.batteryState == .charging || device.batteryState == .full
    }

    private nonisolated static func connection(for path: NWPath) -> Connection {
        guard path.status == .satisfied else { return .offline }
        if path.usesInterfaceType(.wifi) {
            return .wifi
        }
        if path.usesInterfaceType(.cellular) {
            return .cellular
        }
        if path.usesInterfaceType(.wiredEthernet) {
            return .wired
        }
        return .other
    }
}

/// Compact "status bar" pill: connection icon + battery percentage and icon.
struct DeviceStatusView: View {
    @StateObject private var monitor = DeviceStatusMonitor()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: connectionSymbol)
                .foregroundStyle(monitor.connection == .offline ? Color.red : Color.white)
            if let level = monitor.batteryLevel {
                HStack(spacing: 4) {
                    Text("\(level)%")
                        .monospacedDigit()
                    Image(systemName: batterySymbol(for: level))
                        .foregroundStyle(batteryColor(for: level))
                }
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Capsule().fill(Color.black.opacity(0.5)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var connectionSymbol: String {
        switch monitor.connection {
        case .wifi: return "wifi"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .wired: return "cable.connector"
        case .other: return "network"
        case .offline: return "wifi.slash"
        }
    }

    private func batterySymbol(for level: Int) -> String {
        if monitor.isCharging {
            return "battery.100percent.bolt"
        }
        switch level {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private func batteryColor(for level: Int) -> Color {
        if monitor.isCharging {
            return .green
        }
        return level <= 20 ? .red : .white
    }

    private var accessibilityText: String {
        let connection: String
        switch monitor.connection {
        case .wifi: connection = "Wi-Fi"
        case .cellular: connection = "Sieć komórkowa"
        case .wired: connection = "Sieć przewodowa"
        case .other: connection = "Sieć"
        case .offline: connection = "Brak sieci"
        }
        guard let level = monitor.batteryLevel else { return connection }
        return "\(connection), bateria \(level)%" + (monitor.isCharging ? ", ładowanie" : "")
    }
}
