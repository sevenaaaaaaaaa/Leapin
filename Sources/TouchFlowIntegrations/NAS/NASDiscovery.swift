import Foundation
import Network
import TouchFlowCore

/// A NAS / file server found on the local network via Bonjour.
public struct NASDevice: Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var host: String
    public var port: UInt16
    public var service: String
    public var model: String?

    public init(id: String, name: String, host: String, port: UInt16, service: String, model: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.service = service
        self.model = model
    }
}

/// Browses `_smb._tcp`, `_afpovertcp._tcp`, `_nfs._tcp` and `_http._tcp` on the
/// local domain. Results are deduplicated by host and delivered on a private
/// serial queue (the caller must hop to the main actor itself).
public final class NASDiscovery: @unchecked Sendable {
    public init() {}

    static let serviceTypes = ["_smb._tcp", "_afpovertcp._tcp", "_nfs._tcp", "_http._tcp"]

    private let queue = DispatchQueue(label: "com.touchflow.nas.discovery", qos: .userInitiated)
    private var browsers: [NWBrowser] = []
    private var found: [String: NASDevice] = [:]
    private var onUpdate: (([NASDevice]) -> Void)?
    private var running = false

    public func start(onUpdate: @escaping ([NASDevice]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.onUpdate = onUpdate
            guard self.running == false else {
                self.emit()
                return
            }
            self.running = true
            for serviceType in NASDiscovery.serviceTypes {
                let parameters = NWParameters.tcp
                parameters.includePeerToPeer = true
                let browser = NWBrowser(for: .bonjour(type: serviceType, domain: "local."), using: parameters)
                browser.stateUpdateHandler = { state in
                    if case .failed(let error) = state {
                        TFLog.shared.warn("integrations.nas", "browser \(serviceType) failed: \(error.localizedDescription)")
                    }
                }
                browser.browseResultsChangedHandler = { [weak self] results, _ in
                    guard let self else { return }
                    self.queue.async { self.merge(results, serviceType: serviceType) }
                }
                browser.start(queue: self.queue)
                self.browsers.append(browser)
            }
            TFLog.shared.info("integrations.nas", "browsing \(NASDiscovery.serviceTypes.joined(separator: ", "))")
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            for browser in self.browsers {
                browser.stateUpdateHandler = nil
                browser.browseResultsChangedHandler = nil
                browser.cancel()
            }
            self.browsers.removeAll()
            self.running = false
            self.found.removeAll()
            TFLog.shared.info("integrations.nas", "stopped")
        }
    }

    // MARK: - Internals

    private func merge(_ results: Set<NWBrowser.Result>, serviceType: String) {
        for result in results {
            guard let device = NASDiscovery.device(for: result.endpoint, serviceType: serviceType) else { continue }
            let key = device.host.lowercased()
            if let existing = found[key] {
                // A host usually advertises several services; SMB wins for mounting.
                if existing.service != "_smb._tcp", device.service == "_smb._tcp" {
                    found[key] = device
                }
            } else {
                found[key] = device
            }
        }
        emit()
    }

    private func emit() {
        let devices = found.values.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        onUpdate?(devices)
    }

    static func device(for endpoint: NWEndpoint, serviceType: String) -> NASDevice? {
        switch endpoint {
        case let .service(name, _, _, _):
            let clean = decodeBonjourName(name)
            let host = hostName(fromServiceName: clean)
            guard clean.isEmpty == false else { return nil }
            return NASDevice(id: host, name: clean, host: host,
                             port: defaultPort(forService: serviceType), service: serviceType, model: nil)
        case let .hostPort(host, port):
            let raw = String(describing: host).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            guard raw.isEmpty == false else { return nil }
            let resolved = port.rawValue == 0 ? defaultPort(forService: serviceType) : port.rawValue
            return NASDevice(id: raw, name: raw, host: raw, port: resolved, service: serviceType, model: nil)
        default:
            return nil
        }
    }

    /// Decodes Bonjour DNS-SD escapes such as `My\032NAS` or `a\.b`.
    static func decodeBonjourName(_ raw: String) -> String {
        let characters = Array(raw)
        var output = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                if index + 3 < characters.count,
                   characters[index + 1].isNumber,
                   characters[index + 2].isNumber,
                   characters[index + 3].isNumber,
                   let value = UInt8(String(characters[(index + 1)...(index + 3)])),
                   let scalar = Unicode.Scalar(UInt32(value)) {
                    output.append(Character(scalar))
                    index += 4
                    continue
                }
                if index + 1 < characters.count {
                    output.append(characters[index + 1])
                    index += 2
                    continue
                }
            }
            output.append(character)
            index += 1
        }
        return output.trimmingCharacters(in: .whitespaces)
    }

    /// Turns a Bonjour instance name into a resolvable mDNS host name.
    static func hostName(fromServiceName name: String) -> String {
        var host = name.trimmingCharacters(in: .whitespaces)
        while host.hasSuffix(".") { host.removeLast() }
        host = host.replacingOccurrences(of: " ", with: "-")
        if host.lowercased().hasSuffix(".local") { return host }
        return host + ".local"
    }

    static func defaultPort(forService service: String) -> UInt16 {
        switch service {
        case "_smb._tcp": return 445
        case "_afpovertcp._tcp": return 548
        case "_nfs._tcp": return 2049
        case "_http._tcp": return 80
        default: return 445
        }
    }
}
