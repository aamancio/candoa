import CryptoKit
import Foundation

/// The WebAuthn pieces of the built-in authenticator that are pure
/// computation: relying-party validation, authenticator data, the "none"
/// attestation object, and ES256 assertion signatures (issue #506). Presenting
/// consent and storing credentials live elsewhere; everything here is
/// deterministic and unit-tested.
enum PasskeyCeremony {
    /// ES256, the one algorithm the authenticator implements — required by
    /// WebAuthn and accepted everywhere.
    static let supportedAlgorithm = -7

    /// All zeros: "none" attestation deliberately identifies no authenticator
    /// model, matching what privacy-preserving platform authenticators send.
    static let aaguid = Data(count: 16)

    enum Failure: Error {
        /// The relying party asked only for algorithms we don't implement.
        case unsupportedAlgorithms
        /// The requested rpId isn't one the calling origin may act for.
        case invalidRelyingParty
    }

    // MARK: - Relying-party scope

    /// Registrable-domain suffixes that are really public registries; a site
    /// may not scope credentials to them. The full public-suffix list is
    /// enormous — this covers the exact-match single labels implicitly (no
    /// dot) plus the common multi-part registries.
    private static let multiPartPublicSuffixes: Set<String> = [
        "ac.uk", "co.uk", "gov.uk", "ltd.uk", "me.uk", "net.uk", "org.uk", "plc.uk", "sch.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "id.au",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp",
        "com.br", "net.br", "org.br", "gov.br",
        "co.nz", "net.nz", "org.nz",
        "co.in", "net.in", "org.in", "gen.in", "firm.in", "ind.in",
        "com.mx", "com.ar", "com.tr", "com.cn", "com.tw", "com.hk", "com.sg", "com.my",
        "co.za", "co.kr", "or.kr", "github.io", "gitlab.io", "pages.dev", "vercel.app",
        "netlify.app", "web.app", "firebaseapp.com", "herokuapp.com", "azurewebsites.net",
        "cloudfront.net", "amazonaws.com", "s3.amazonaws.com"
    ]

    /// WebAuthn scoping: the effective rpId defaults to the caller's host and
    /// may otherwise be any registrable suffix of it. `https` origins only,
    /// with localhost allowed for development, as in every browser.
    static func effectiveRelyingParty(requested: String?, origin: URL) throws -> String {
        guard let host = origin.host?.lowercased(), !host.isEmpty else {
            throw Failure.invalidRelyingParty
        }
        let scheme = origin.scheme?.lowercased()
        let isLocalhost = host == "localhost" || host.hasSuffix(".localhost")
        guard scheme == "https" || (isLocalhost && scheme == "http") else {
            throw Failure.invalidRelyingParty
        }

        guard let requested = requested?.lowercased(), !requested.isEmpty else { return host }
        if requested == host { return requested }

        // A suffix claim must leave at least one label of the host in front,
        // must itself look like a registrable domain (contain a dot), and must
        // not be a public registry.
        guard host.hasSuffix("." + requested),
              requested.contains("."),
              !multiPartPublicSuffixes.contains(requested)
        else {
            throw Failure.invalidRelyingParty
        }
        return requested
    }

    // MARK: - Client data

    static func clientDataJSON(type: String, challenge: String, origin: URL) -> Data {
        // Serialized by hand so the field order matches what verifiers expect
        // from every other authenticator implementation. The origin field is
        // the web origin — scheme, host, and any non-default port — never the
        // full URL.
        var serialized = "\(origin.scheme ?? "https")://\(origin.host ?? "")"
        if let port = origin.port { serialized += ":\(port)" }
        let escaped = { (value: String) -> String in
            value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let json = "{\"type\":\"\(escaped(type))\",\"challenge\":\"\(escaped(challenge))\","
            + "\"origin\":\"\(escaped(serialized))\",\"crossOrigin\":false}"
        return Data(json.utf8)
    }

    // MARK: - Authenticator data

    struct Flags: OptionSet {
        let rawValue: UInt8
        static let userPresent = Flags(rawValue: 0x01)
        static let userVerified = Flags(rawValue: 0x04)
        static let backupEligible = Flags(rawValue: 0x08)
        static let backedUp = Flags(rawValue: 0x10)
        static let attestedCredentialIncluded = Flags(rawValue: 0x40)
    }

    /// Sign counter stays zero forever: credentials sync between devices via
    /// the keychain, and the spec's guidance for synced passkeys is a
    /// constant counter rather than one that fights itself across copies.
    static func authenticatorData(
        relyingParty: String,
        flags: Flags,
        attestedCredential: (id: Data, publicKey: P256.Signing.PublicKey)? = nil
    ) -> Data {
        var data = Data(SHA256.hash(data: Data(relyingParty.utf8)))
        data.append(flags.rawValue)
        data.append(contentsOf: [0, 0, 0, 0])
        if let attested = attestedCredential {
            data.append(Self.aaguid)
            data.append(UInt8(attested.id.count >> 8))
            data.append(UInt8(attested.id.count & 0xFF))
            data.append(attested.id)
            data.append(coseKey(for: attested.publicKey))
        }
        return data
    }

    /// The credential public key as a COSE_Key map (EC2, P-256, ES256).
    static func coseKey(for publicKey: P256.Signing.PublicKey) -> Data {
        let raw = publicKey.rawRepresentation
        let x = raw.prefix(32)
        let y = raw.suffix(32)
        var map = Data([0xA5]) // map, 5 entries
        map.append(contentsOf: [0x01, 0x02])              // kty: EC2
        map.append(contentsOf: [0x03, 0x26])              // alg: -7 (ES256)
        map.append(contentsOf: [0x20, 0x01])              // crv: P-256
        map.append(contentsOf: [0x21, 0x58, 0x20]); map.append(x) // x
        map.append(contentsOf: [0x22, 0x58, 0x20]); map.append(y) // y
        return map
    }

    /// attestationObject with fmt "none": canonical CTAP2 CBOR, encoded by
    /// hand because the shape is fixed.
    static func attestationObject(authenticatorData: Data) -> Data {
        var object = Data([0xA3]) // map, 3 entries
        object.append(contentsOf: [0x63]); object.append(Data("fmt".utf8))
        object.append(contentsOf: [0x64]); object.append(Data("none".utf8))
        object.append(contentsOf: [0x67]); object.append(Data("attStmt".utf8))
        object.append(contentsOf: [0xA0]) // empty map
        object.append(contentsOf: [0x68]); object.append(Data("authData".utf8))
        object.append(cborByteString(authenticatorData))
        return object
    }

    static func cborByteString(_ data: Data) -> Data {
        var encoded = Data()
        switch data.count {
        case 0...23:
            encoded.append(0x40 | UInt8(data.count))
        case 24...255:
            encoded.append(contentsOf: [0x58, UInt8(data.count)])
        default:
            encoded.append(0x59)
            encoded.append(UInt8(data.count >> 8))
            encoded.append(UInt8(data.count & 0xFF))
        }
        encoded.append(data)
        return encoded
    }

    // MARK: - Assertion

    static func assertionSignature(
        privateKey: P256.Signing.PrivateKey,
        authenticatorData: Data,
        clientDataJSON: Data
    ) throws -> Data {
        var message = authenticatorData
        message.append(Data(SHA256.hash(data: clientDataJSON)))
        return try privateKey.signature(for: message).derRepresentation
    }

    // MARK: - Base64URL

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ text: String) -> Data? {
        var base64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }
}
