import Foundation
import Combine

public enum NetworkScene: String, Codable, CaseIterable, Identifiable, Sendable {
    case general, agent, development, entertainment, abroad, privacy
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .general: return "综合"
        case .agent: return "海外 Agent"
        case .development: return "开发"
        case .entertainment: return "娱乐"
        case .abroad: return "出国"
        case .privacy: return "私密"
        }
    }
    public var icon: String {
        switch self {
        case .general: return "square.grid.2x2"
        case .agent: return "sparkles"
        case .development: return "curlybraces"
        case .entertainment: return "play.rectangle"
        case .abroad: return "airplane"
        case .privacy: return "lock.shield"
        }
    }
    public var detail: String {
        switch self {
        case .general: return "日常分流与常用服务"
        case .agent: return "AI 服务、API 与终端工具"
        case .development: return "依赖、代码、内网与服务器"
        case .entertainment: return "流媒体与游戏平台"
        case .abroad: return "海外网络与国内服务"
        case .privacy: return "加密解析与减少跟踪"
        }
    }
}

@MainActor
public final class NetworkScenes: ObservableObject {
    @Published public private(set) var bindings: [String: UUID] = [:]
    @Published public private(set) var active: NetworkScene?
    private let url: URL
    private struct State: Codable { var bindings: [String: UUID]; var active: NetworkScene? }

    public init(root: URL) {
        url = root.appendingPathComponent("scenes.json")
        if let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(State.self, from: data) {
            bindings = state.bindings
            active = state.active
        }
    }
    public func profileID(for scene: NetworkScene) -> UUID? { bindings[scene.rawValue] }
    public func bind(_ scene: NetworkScene, to id: UUID) throws {
        var next = bindings
        next[scene.rawValue] = id
        try save(State(bindings: next, active: active))
        bindings = next
    }
    public func markActive(_ scene: NetworkScene?) throws {
        try save(State(bindings: bindings, active: scene))
        active = scene
    }
    private func save(_ state: State) throws {
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }
}
