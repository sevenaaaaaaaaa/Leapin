import Foundation
import LeapinCore

public struct ManagedPolicy: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let selected: String
    public let members: [String]
    public let type: String
}

public extension LeapinEngine {
    func managedPolicies() async throws -> [ManagedPolicy] {
        let data = try await managedKernel.request("proxies")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let proxies = json["proxies"] as? [String: [String: Any]] else {
            throw LeapinError.protocolError("内核返回了无法识别的策略数据")
        }
        return proxies.keys.sorted().compactMap { name in
            guard let object = proxies[name], let members = object["all"] as? [String], !members.isEmpty else { return nil }
            return ManagedPolicy(name: name, selected: object["now"] as? String ?? "自动",
                                 members: members, type: object["type"] as? String ?? "")
        }
    }

    func selectManagedPolicy(group: String, member: String, persist: Bool = true) async throws {
        guard !persist || !configurationBusy else {
            throw LeapinError.invalidConfiguration("正在切换配置，请稍后再选择线路")
        }
        let profileID = profile.id
        let kernelPort = managedKernel.proxyPort
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))
        guard let path = group.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw LeapinError.invalidConfiguration("策略组名称无效")
        }
        let data = try JSONSerialization.data(withJSONObject: ["name": member])
        _ = try await managedKernel.request("proxies/\(path)", method: "PUT", body: data)
        guard profile.id == profileID, managedKernel.proxyPort == kernelPort else {
            throw LeapinError.invalidConfiguration("内核已切换，请刷新后重试")
        }
        if persist, var source = try store.kernelSource(for: profileID) {
            if source.selections == nil { source.selections = [:] }
            source.selections?[group] = member
            try store.saveKernelSource(source, for: profileID)
        }
    }
}
