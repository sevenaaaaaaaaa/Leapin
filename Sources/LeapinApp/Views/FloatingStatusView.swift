import SwiftUI
import LeapinCore
import LeapinRuntime

/// Live traffic while the main window is closed: speed, recent connections and a
/// one-click stop. Deliberately small — it sits on top of whatever you are doing.
struct FloatingStatusView: View {
    @ObservedObject var engine: LeapinEngine
    @ObservedObject var controller: FloatingPanelController

    @State private var downRate: Double = 0
    @State private var upRate: Double = 0
    @State private var lastBytesIn: Int = 0
    @State private var lastBytesOut: Int = 0
    @State private var lastSample = Date()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            speedRow
            Divider().overlay(LP.stroke)
            recentList
            footer
        }
        .padding(12)
        .frame(width: 272, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(LP.strokeStrong, lineWidth: 1)
        )
        .onReceive(ticker) { now in
            sample(now)
        }
        .onAppear {
            let live = engine.liveTraffic
            lastBytesIn = live.bytesIn
            lastBytesOut = live.bytesOut
            lastSample = Date()
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(LP.accentFill)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 17, height: 17)

            Text("Leapin")
                .font(LPFont.display(11.5, weight: .semibold))
                .foregroundStyle(LP.text)

            HStack(spacing: 4) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 5, height: 5)
                Text(engine.state.label)
                    .font(.system(size: 9))
                    .foregroundStyle(LP.textTertiary)
            }

            Spacer(minLength: 0)

            Button {
                controller.hide()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(LP.textTertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭浮窗（可在菜单栏重新打开）")
        }
    }

    private var speedRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            rate(label: "下载", value: downRate, symbol: "arrow.down")
            rate(label: "上传", value: upRate, symbol: "arrow.up")
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(engine.activeConnections)")
                    .font(LPFont.num(13, weight: .semibold))
                    .foregroundStyle(LP.text)
                Text("连接")
                    .font(.system(size: 9))
                    .foregroundStyle(LP.textTertiary)
            }
        }
    }

    private func rate(label: String, value: Double, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(LP.accent)
                Text(Fmt.rate(value))
                    .font(LPFont.num(12.5, weight: .semibold))
                    .foregroundStyle(LP.text)
                    .monospacedDigit()
            }
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(LP.textTertiary)
        }
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 3) {
            let recent = engine.flows.suffix(3).reversed()
            if recent.isEmpty {
                Text("还没有连接")
                    .font(.system(size: 10))
                    .foregroundStyle(LP.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ForEach(Array(recent)) { flow in
                    HStack(spacing: 5) {
                        Text(flow.host)
                            .font(LPFont.mono(9.5))
                            .foregroundStyle(LP.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(policyLabel(flow))
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(policyColor(flow))
                    }
                }
            }
        }
        .frame(height: 46, alignment: .top)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                if engine.state == .running {
                    engine.stop()
                } else {
                    Task { await engine.start() }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: engine.state == .running ? "stop.fill" : "play.fill")
                        .font(.system(size: 8, weight: .bold))
                    Text(engine.state == .running ? "停止" : "启动")
                        .font(.system(size: 10, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(LPPrimaryButtonStyle(tint: engine.state == .running ? LP.dangerFill : nil))

            Button {
                openMainWindow()
            } label: {
                Text("打开")
                    .font(.system(size: 10, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(LPGhostButtonStyle())
        }
    }

    // MARK: - Helpers

    private var stateColor: Color {
        switch engine.state {
        case .running: return LP.mint
        case .starting: return LP.amber
        case .failed: return LP.danger
        case .stopped: return LP.textTertiary
        }
    }

    private func policyLabel(_ flow: FlowEvent) -> String {
        if flow.blockedBy != nil { return "拦截" }
        return flow.policy.isEmpty ? "—" : flow.policy
    }

    private func policyColor(_ flow: FlowEvent) -> Color {
        if flow.blockedBy != nil { return LP.danger }
        switch flow.policy.lowercased() {
        case "direct": return LP.mint
        case "proxy", "global": return LP.accent
        default: return LP.textTertiary
        }
    }

    private func sample(_ now: Date) {
        let live = engine.liveTraffic
        let elapsed = max(now.timeIntervalSince(lastSample), 0.2)
        // bytesIn is client -> remote (upload); bytesOut is remote -> client (download).
        let downDelta = max(live.bytesOut - lastBytesOut, 0)
        let upDelta = max(live.bytesIn - lastBytesIn, 0)
        downRate = Double(downDelta) / elapsed
        upRate = Double(upDelta) / elapsed
        lastBytesIn = live.bytesIn
        lastBytesOut = live.bytesOut
        lastSample = now
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

extension Fmt {
    /// Bytes per second, one decimal below 10 so idle traffic does not read as "0 KB/s".
    static func rate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1 { return "0 B/s" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = bytesPerSecond
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return value < 10 ? String(format: "%.1f %@", value, units[index])
                          : String(format: "%.0f %@", value, units[index])
    }
}
