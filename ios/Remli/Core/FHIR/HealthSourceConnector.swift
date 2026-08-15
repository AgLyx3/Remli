import Foundation

/// The acquisition seam.
///
/// Everything above this file — normalizer, proposal engine, UI — is written against
/// `HealthSourceConnector` and never against a particular transport. v1 ships a connector that
/// reads bundled FHIR JSON; the SMART on FHIR connector that replaces it later implements the
/// same three members and changes nothing above.
///
/// Foundation only, on purpose: the whole clinical core has to be runnable in a plain
/// command-line harness so it can be verified without a simulator.

// MARK: - Descriptor

/// Who a set of records came from, as shown to the user.
struct HealthSourceDescriptor: Codable, Hashable, Identifiable {
    /// Stable identifier. Used in proposal identity, so it must not change between imports.
    let id: String
    /// e.g. "Remli Demo Primary Care".
    let displayName: String
    /// One line describing *how* Remli is connected, e.g. "Sample file bundled with the app".
    /// Shown under the source name so a demo audience can never mistake a file for a live chart.
    let subtitle: String
    /// What kind of data this connection yields.
    let dataOrigin: DataOrigin

    init(id: String, displayName: String, subtitle: String, dataOrigin: DataOrigin) {
        self.id = id
        self.displayName = displayName
        self.subtitle = subtitle
        self.dataOrigin = dataOrigin
    }

    /// A copy of this descriptor with a different origin. Used when a bundle declares its own
    /// origin via `meta.tag` and that declaration should win over the connector's default.
    func withOrigin(_ origin: DataOrigin) -> HealthSourceDescriptor {
        HealthSourceDescriptor(
            id: id,
            displayName: displayName,
            subtitle: subtitle,
            dataOrigin: origin
        )
    }
}

// MARK: - Errors

enum HealthSourceError: LocalizedError, Equatable {
    /// The named JSON file is not in the app bundle. Missing sample data must surface as a clear
    /// message, never as a crash on a stage.
    case bundledResourceNotFound(name: String, bundleDescription: String)
    case fileUnreadable(path: String, underlying: String)
    case decodingFailed(source: String, underlying: String)
    /// The connector exists to prove the seam and does not perform network work in v1.
    case notImplementedInV1(capability: String)
    case notAuthorized(source: String)

    var errorDescription: String? {
        switch self {
        case .bundledResourceNotFound(let name, let bundleDescription):
            return "Remli could not find the sample health file “\(name).json” in \(bundleDescription)."
        case .fileUnreadable(let path, let underlying):
            return "Remli could not read the health file at \(path). (\(underlying))"
        case .decodingFailed(let source, let underlying):
            return "Remli could not read the health records from \(source). (\(underlying))"
        case .notImplementedInV1(let capability):
            return "\(capability) is not part of this version of Remli."
        case .notAuthorized(let source):
            return "Remli is not connected to \(source) yet."
        }
    }
}

// MARK: - Protocol

protocol HealthSourceConnector {
    var source: HealthSourceDescriptor { get }
    func authorize() async throws
    func fetch() async throws -> [FHIRResource]

    /// Fetch plus the descriptor that actually applies to the returned records.
    ///
    /// This exists as a protocol requirement rather than only a protocol-extension helper so a
    /// connector can correct its own origin after reading the payload — `SyntheaBundleConnector`
    /// honours a bundle's declared `data-origin` tag here. Declaring it in the protocol keeps the
    /// call dynamically dispatched through `any HealthSourceConnector`.
    func importedSource() async throws -> ImportedSource
}

extension HealthSourceConnector {
    func importedSource() async throws -> ImportedSource {
        ImportedSource(descriptor: source, resources: try await fetch())
    }
}

// MARK: - Bundled JSON connector

/// Reads a FHIR JSON bundle shipped inside the app (or, in tests and the verification harness, a
/// file on disk) through exactly the decoding path production data will use. Only the transport
/// is stubbed.
///
/// Named for its v1 role — carrying real MITRE Synthea output — but it will load any FHIR R4
/// bundle, including Remli's authored demo export.
final class SyntheaBundleConnector: HealthSourceConnector {
    enum Location: Hashable {
        /// A `.json` resource inside an app bundle.
        case bundledResource(name: String, bundle: Bundle)
        /// A file on disk. Used by tests and the offline verification harness.
        case fileURL(URL)

        var describedSource: String {
            switch self {
            case .bundledResource(let name, _): return "\(name).json"
            case .fileURL(let url): return url.lastPathComponent
            }
        }
    }

    let source: HealthSourceDescriptor
    private let location: Location

    /// The origin the last successful fetch actually applied, after honouring the bundle's own
    /// `meta.tag` declaration. Nil until a fetch succeeds.
    private(set) var resolvedOrigin: DataOrigin?

    init(source: HealthSourceDescriptor, location: Location) {
        self.source = source
        self.location = location
    }

    /// Reading a local file needs no authorization. Implemented as a no-op rather than omitted so
    /// the call site is identical to the SMART on FHIR path.
    func authorize() async throws {}

    func fetch() async throws -> [FHIRResource] {
        try await importedSource().resources
    }

    func importedSource() async throws -> ImportedSource {
        let data = try loadData()
        let decoder = FHIRDecoder.make()
        let bundle: FHIRBundle
        do {
            bundle = try decoder.decode(FHIRBundle.self, from: data)
        } catch {
            throw HealthSourceError.decodingFailed(
                source: location.describedSource,
                underlying: String(describing: error)
            )
        }
        let origin = bundle.declaredOrigin ?? source.dataOrigin
        resolvedOrigin = origin
        return ImportedSource(
            descriptor: source.withOrigin(origin),
            resources: bundle.resources
        )
    }

    private func loadData() throws -> Data {
        switch location {
        case .bundledResource(let name, let bundle):
            guard let url = bundle.url(forResource: name, withExtension: "json") else {
                throw HealthSourceError.bundledResourceNotFound(
                    name: name,
                    bundleDescription: bundle.bundleURL.lastPathComponent
                )
            }
            return try read(url)
        case .fileURL(let url):
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw HealthSourceError.fileUnreadable(
                    path: url.path,
                    underlying: "No file at that path."
                )
            }
            return try read(url)
        }
    }

    private func read(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw HealthSourceError.fileUnreadable(
                path: url.path,
                underlying: error.localizedDescription
            )
        }
    }
}

extension SyntheaBundleConnector {
    /// Real MITRE Synthea R4 output. Sparse on purpose: no dosage text, no time of day, no PT
    /// detail — which is exactly the case the reminder policy is written for.
    static func syntheaGlover(bundle: Bundle = .main) -> SyntheaBundleConnector {
        SyntheaBundleConnector(
            source: HealthSourceDescriptor(
                id: "sample.synthea.glover",
                displayName: "Remli Demo Hospital",
                subtitle: "Synthetic Synthea record bundled with the app",
                dataOrigin: .syntheaSynthetic
            ),
            location: .bundledResource(name: "synthea-glover", bundle: bundle)
        )
    }

    /// Authored export exercising fields Synthea never populates: verbatim instruction text,
    /// `additionalInstruction`, a `Timing.repeat.when` code, real PT detail, and a deliberate
    /// cross-source disagreement.
    static func portalExportDemo(bundle: Bundle = .main) -> SyntheaBundleConnector {
        SyntheaBundleConnector(
            source: HealthSourceDescriptor(
                id: "sample.portal.export",
                displayName: "Remli Demo Primary Care",
                subtitle: "Sample portal export bundled with the app",
                dataOrigin: .authoredDemo
            ),
            location: .bundledResource(name: "portal-export-demo", bundle: bundle)
        )
    }

    /// Same connector, reading from disk. Used by the offline verification harness and tests.
    static func file(_ url: URL, descriptor: HealthSourceDescriptor) -> SyntheaBundleConnector {
        SyntheaBundleConnector(source: descriptor, location: .fileURL(url))
    }
}

// MARK: - SMART on FHIR seam

/// The production acquisition path, deliberately unimplemented in v1.
///
/// This type exists to prove the seam holds: it satisfies `HealthSourceConnector` with no changes
/// to the normalizer or the proposal engine. Nothing above this file would need to move when the
/// real flow lands.
///
/// **What the real implementation will do** (Epic / MyChart patient-facing app, OAuth 2.0
/// authorization code grant with PKCE, per the design doc's Data Acquisition section):
///
/// 1. `GET {iss}/metadata` (or `/.well-known/smart-configuration`) to discover the
///    `authorization_endpoint` and `token_endpoint` for the chosen organization.
/// 2. Generate a cryptographically random `code_verifier`; send
///    `code_challenge = BASE64URL(SHA256(code_verifier))` with `code_challenge_method=S256`.
///    PKCE, not a client secret — a shipped mobile app cannot keep a secret.
/// 3. Open the authorization endpoint in `ASWebAuthenticationSession` so the user types MyChart
///    credentials into the provider's own web view. Remli never sees the password.
/// 4. Exchange the returned `code` plus `code_verifier` at the token endpoint over the
///    allowlisted egress host. Store `access_token` / `refresh_token` in the Keychain with
///    `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, never in the vault file and never on disk
///    in the clear.
/// 5. Page `Bundle`s from the FHIR API, decode them with `FHIRDecoder.make()`, and hand them to
///    the same `CareRecordNormalizer` the bundled connector already feeds.
///
/// **Scopes it would request** (read-only, narrowest set that supports the v1 reminder loop):
///
/// - `launch/patient`, `openid`, `fhirUser`, `offline_access`
/// - `patient/Patient.read`
/// - `patient/MedicationRequest.read`, `patient/MedicationStatement.read`
/// - `patient/CarePlan.read`
/// - `patient/AllergyIntolerance.read`
/// - `patient/Appointment.read`
/// - `patient/Condition.read`
///
/// No write scopes are requested in any version. Remli never writes to a chart.
struct SMARTOnFHIRConnector: HealthSourceConnector {
    let source: HealthSourceDescriptor

    /// The FHIR base URL (`iss`) for the organization. Kept so the descriptor and the future
    /// discovery step already agree on what "this source" means.
    let issuer: URL

    /// Scopes the real implementation will request. Declared now so the seam documents itself and
    /// so a reviewer can check the request stays read-only.
    static let requestedScopes: [String] = [
        "launch/patient",
        "openid",
        "fhirUser",
        "offline_access",
        "patient/Patient.read",
        "patient/MedicationRequest.read",
        "patient/MedicationStatement.read",
        "patient/CarePlan.read",
        "patient/AllergyIntolerance.read",
        "patient/Appointment.read",
        "patient/Condition.read"
    ]

    init(source: HealthSourceDescriptor, issuer: URL) {
        self.source = source
        self.issuer = issuer
    }

    /// Intentionally throws. There is no partial OAuth implementation here to half-work in a demo.
    func authorize() async throws {
        throw HealthSourceError.notImplementedInV1(
            capability: "Connecting directly to \(source.displayName)"
        )
    }

    func fetch() async throws -> [FHIRResource] {
        throw HealthSourceError.notAuthorized(source: source.displayName)
    }
}
