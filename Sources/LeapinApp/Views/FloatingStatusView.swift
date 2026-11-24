import SwiftUI
import Combine
import LeapinCore
import LeapinRuntime

/// 常驻层的第三级信息（PRODUCT-v4 §2.1）：明细。
///
/// 它读 `ResidentStatusStore`，和菜单栏面板是同一个对象、同一份速率——
/// 这里不再持有任何字节基准，也不再自己差分。视图里剩下的 `ticker` 只负责
/// 「什么时候取一帧」，不再负责「一帧是多少」。
struct FloatingStatusView: View {
    @ObservedObject var engine: LeapinEngine
    @ObservedObject var controller: FloatingPanelController
    @ObservedObject private var resident = ResidentStatusStore.shared

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var status: ResidentStatus { resident.status }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            speedRow
            // 同一条「路」的缩略：浮窗回答「现在走哪」，不只是一组速度数字。
            RouteLine(nodes: [
                .init("你"),
                .init(judgeShort, state: resident.status.exit == nil ? .idle : .current),
                .init(exitShort),
            ], axis: .horizontal, onInk: false, compact: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lpAnimation(LPMotion.quick, value: judgeShort)
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
        .onAppear { resident.update(from: engine) }
        .onReceive(ticker) { now in resident.update(from: engine, at: now) }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(LP.accentFill)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 17, height: 17)

            Text("Leapin")
                .font(LPFont.display(11.5, weight: .semibold))
                .foregroundStyle(LP.text)

            HStack(spacing: 4) {
                Circle()
                    .fill(status.tone.ink)
                    .frame(width: 5, height: 5)
                Text(status.title)
                    .font(.system(size: 11))
                    .foregroundStyle(LP.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button {
                controller.hide()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(LP.textTertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭浮窗（可在菜单栏重新打开）")
        }
    }

    private var judgeShort: String {
        guard engine.state == .running else { return "尚未接管" }
        return status.exitGroup ?? "规则模式"
    }

    private var exitShort: String {
        guard engine.state == .running, let exit = status.exit else { return "—" }
        return exit
    }

    private var speedRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            rate(label: "下载", value: status.rates.downText, symbol: "arrow.down")
            rate(label: "上传", value: status.rates.upText, symbol: "arrow.up")
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(status.connections)")
                    .font(LPFont.num(13, weight: .semibold))
                    .foregroundStyle(LP.text)
                Text("连接")
                    .font(.system(size: 11))
                    .foregroundStyle(LP.textTertiary)
            }
        }
    }

    private func rate(label: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(LP.accent)
                Text(value)
                    .font(LPFont.num(12.5, weight: .semibold))
                    .foregroundStyle(LP.text)
                    .monospacedDigit()
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(LP.textTertiary)
        }
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 3) {
            let recent = status.recent
            if recent.isEmpty {
                Text("还没有连接")
                    .font(.system(size: 11))
                    .foregroundStyle(LP.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                // 设计只给两条：浮窗是第三级信息，再多就变成另一个窗口了。
                ForEach(recent.prefix(2)) { flow in
                    HStack(spacing: 5) {
                        Text(flow.host)
                            .font(LPFont.mono(11))
                            .foregroundStyle(LP.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(flow.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(policyColor(flow.kind))
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
                        .font(.system(size: 11, weight: .bold))
                    Text(engine.state == .running ? "停止" : "启动")
                        .font(.system(size: 11, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(LPPrimaryButtonStyle(tint: engine.state == .running ? LP.dangerFill : nil))

            Button {
                openMainWindow()
            } label: {
                Text("打开")
                    .font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(LPGhostButtonStyle())
        }
    }

    // MARK: - Helpers

    private func policyColor(_ kind: ResidentFlowKind) -> Color {
        switch kind {
        case .blocked: return LP.danger
        case .direct: return LP.mint
        case .proxy: return LP.accent
        case .other: return LP.textTertiary
        }
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
