import Foundation

/// Parses pairing codes printed by `modelmatrix-agent link` on the
/// remote host. The `mode` query token is the single kind signal on the wire:
/// - SSH tunnel: `modelmatrix-gateway://user@host?name=gpu&agent_port=7700&mode=ssh`
/// - Direct (e.g. Tailscale MagicDNS): `modelmatrix-gateway://host.example.ts.net?name=gpu&agent_port=7700&mode=direct`
/// The kind is never re-derived from the URL shape (user@host presence); the
/// only legacy fallback is a missing `mode` on links printed before the token
/// existed, which default to `.ssh` here at the boundary.
public enum GatewayLinkCode {
    public static let scheme = "modelmatrix-gateway"

    static func queryValue(_ query: [URLQueryItem], _ name: String) -> String? {
        query.first { $0.name == name }?.value
    }

    static func isValidPort(_ port: Int) -> Bool {
        TCPPort.isValid(port)
    }
}
