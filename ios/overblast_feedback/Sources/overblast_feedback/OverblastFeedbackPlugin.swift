import CryptoKit
import DeviceCheck
import Flutter
import MetricKit
import Security
import UIKit

/// The iOS half of the `overblast_feedback/device` channel (docs/feedback-reports.md §8).
///
/// Two kinds of key live here, and the Dart side decides which one a device uses:
///
/// - **App Attest** (`attestApple`, `assertApple`): a key in the Secure Enclave that Apple attests,
///   naming `TEAMID.bundleId`. The worker checks the attestation against Apple's root and the app ids
///   on the feedback key, so the device can be `attested`. Needs iOS 14, real hardware (the simulator
///   says unsupported), and the App Attest capability on the app target. An App Attest key cannot be
///   deleted, only forgotten; the Dart side forgets it.
/// - **A plain P-256 key** (`createPlainKey`, `sign`, `deleteKey`) for the proof-of-work fallback:
///   in the Secure Enclave where there is one, otherwise in the keychain, this device only, never
///   backed up. Its public half goes to the worker as SPKI; reports are signed with
///   `ecdsaSignatureMessageX962SHA256`, which is DER.
///
/// It also answers `lastExit` (docs/feedback-reports.md §3.4): the newest MetricKit crash diagnostic
/// not yet handed over, kept by a subscriber registered with the plugin (see `CrashDiagnostics`).
///
/// Every answer is base64url without padding, except `keyId` and `attestation`, which go to the
/// worker as Apple gives them (standard base64). Errors carry one of the codes the Dart side reads:
/// `unsupported`, `invalid_key`, `bad_args`, `failed`.
public class OverblastFeedbackPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "overblast_feedback/device", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(OverblastFeedbackPlugin(), channel: channel)
    if #available(iOS 14.0, *) { CrashDiagnostics.shared.start() }
  }

  /// Key generation and signing can take a moment in the Secure Enclave; none of it runs on the main
  /// thread, and every result is delivered back on it, as Flutter requires.
  private let queue = DispatchQueue(label: "app.overblast.feedback.device", qos: .userInitiated)

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let reply: (Any?) -> Void = { value in DispatchQueue.main.async { result(value) } }
    switch call.method {
    case "capabilities":
      reply([
        "appAttest": Self.appAttestSupported,
        "androidKeyAttestation": false,
        "plainKey": true,
        "secureHardware": Self.secureEnclaveAvailable,
      ])
    case "attestApple":
      guard let nonce = (args["nonce"] as? String).flatMap(Self.decode) else { return reply(Self.badArgs("nonce")) }
      attestApple(nonce: nonce, reply: reply)
    case "assertApple":
      guard let keyId = args["keyId"] as? String,
        let hash = (args["clientDataHash"] as? String).flatMap(Self.decode)
      else { return reply(Self.badArgs("keyId, clientDataHash")) }
      assertApple(keyId: keyId, clientDataHash: hash, reply: reply)
    case "createPlainKey":
      guard let alias = args["alias"] as? String, !alias.isEmpty else { return reply(Self.badArgs("alias")) }
      queue.async { reply(Self.createPlainKey(alias: alias)) }
    case "sign":
      guard let alias = args["alias"] as? String,
        let data = (args["data"] as? String).flatMap(Self.decode)
      else { return reply(Self.badArgs("alias, data")) }
      queue.async { reply(Self.sign(alias: alias, data: data)) }
    case "lastExit":
      if #available(iOS 14.0, *) {
        reply(CrashDiagnostics.take())
      } else {
        reply(nil)
      }
    case "deleteKey":
      guard let alias = args["alias"] as? String else { return reply(Self.badArgs("alias")) }
      queue.async {
        SecItemDelete(Self.keyQuery(alias) as CFDictionary)
        reply(nil)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: App Attest

  private static var appAttestSupported: Bool {
    if #available(iOS 14.0, *) { return DCAppAttestService.shared.isSupported }
    return false
  }

  private func attestApple(nonce: Data, reply: @escaping (Any?) -> Void) {
    guard #available(iOS 14.0, *), DCAppAttestService.shared.isSupported else {
      return reply(FlutterError(code: "unsupported", message: "App Attest is not available on this device", details: nil))
    }
    let service = DCAppAttestService.shared
    service.generateKey { keyId, error in
      guard let keyId = keyId, error == nil else { return reply(Self.attestError(error, "generateKey")) }
      // §8.2: clientDataHash = SHA-256(nonce bytes); Apple folds it into the attestation's nonce.
      let clientDataHash = Data(SHA256.hash(data: nonce))
      service.attestKey(keyId, clientDataHash: clientDataHash) { attestation, error in
        guard let attestation = attestation, error == nil else { return reply(Self.attestError(error, "attestKey")) }
        reply(["keyId": keyId, "attestation": attestation.base64EncodedString()])
      }
    }
  }

  private func assertApple(keyId: String, clientDataHash: Data, reply: @escaping (Any?) -> Void) {
    guard #available(iOS 14.0, *), DCAppAttestService.shared.isSupported else {
      return reply(FlutterError(code: "unsupported", message: "App Attest is not available on this device", details: nil))
    }
    DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash) { assertion, error in
      guard let assertion = assertion, error == nil else { return reply(Self.attestError(error, "generateAssertion")) }
      reply(Self.encode(assertion))
    }
  }

  private static func attestError(_ error: Error?, _ step: String) -> FlutterError {
    let message = "\(step): \(error?.localizedDescription ?? "no result")"
    if #available(iOS 14.0, *), let dc = error as? DCError {
      switch dc.code {
      case .featureUnsupported: return FlutterError(code: "unsupported", message: message, details: nil)
      case .invalidKey: return FlutterError(code: "invalid_key", message: message, details: nil)
      default: break
      }
    }
    // Includes a missing App Attest entitlement and Apple's servers being unreachable: the Dart side
    // falls back to the proof of work either way.
    return FlutterError(code: "failed", message: message, details: nil)
  }

  // MARK: The plain key (proof-of-work fallback)

  private static var secureEnclaveAvailable: Bool {
    #if targetEnvironment(simulator)
      return false
    #else
      return CryptoKit.SecureEnclave.isAvailable
    #endif
  }

  private static func tag(_ alias: String) -> Data { Data("app.overblast.feedback.\(alias)".utf8) }

  private static func keyQuery(_ alias: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassKey,
      kSecAttrApplicationTag as String: tag(alias),
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
    ]
  }

  private static func createPlainKey(alias: String) -> Any? {
    SecItemDelete(keyQuery(alias) as CFDictionary)  // a fresh key under this alias, never an old one
    var key: SecKey?
    var lastError: Unmanaged<CFError>?
    if secureEnclaveAvailable,
      let access = SecAccessControlCreateWithFlags(
        nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, nil)
    {
      let attributes: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeySizeInBits as String: 256,
        kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
        kSecPrivateKeyAttrs as String: [
          kSecAttrIsPermanent as String: true,
          kSecAttrApplicationTag as String: tag(alias),
          kSecAttrAccessControl as String: access,
        ] as [String: Any],
      ]
      key = SecKeyCreateRandomKey(attributes as CFDictionary, &lastError)
    }
    if key == nil {
      // The simulator, or a Secure Enclave that refused: a keychain key, this device only.
      let attributes: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeySizeInBits as String: 256,
        kSecPrivateKeyAttrs as String: [
          kSecAttrIsPermanent as String: true,
          kSecAttrApplicationTag as String: tag(alias),
          kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as [String: Any],
      ]
      key = SecKeyCreateRandomKey(attributes as CFDictionary, &lastError)
    }
    guard let privateKey = key, let publicKey = SecKeyCopyPublicKey(privateKey),
      let point = SecKeyCopyExternalRepresentation(publicKey, &lastError) as Data?, point.count == 65
    else {
      let reason = lastError.map { ($0.takeRetainedValue() as Error).localizedDescription } ?? "no key"
      return FlutterError(code: "failed", message: "createPlainKey: \(reason)", details: nil)
    }
    // SecKey exports the uncompressed point (0x04 || X || Y); the worker wants SPKI, which for P-256
    // is this fixed 26-byte header in front of it.
    return encode(spkiHeader + point)
  }

  private static let spkiHeader = Data([
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a,
    0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
  ])

  private static func sign(alias: String, data: Data) -> Any? {
    var query = keyQuery(alias)
    query[kSecReturnRef as String] = true
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let found = item else {
      return FlutterError(code: "invalid_key", message: "sign: no key under \(alias)", details: nil)
    }
    let key = found as! SecKey  // swiftlint:disable:this force_cast — kSecReturnRef on kSecClassKey is a SecKey
    var error: Unmanaged<CFError>?
    guard
      let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, data as CFData, &error)
        as Data?
    else {
      let reason = error.map { ($0.takeRetainedValue() as Error).localizedDescription } ?? "no signature"
      return FlutterError(code: "failed", message: "sign: \(reason)", details: nil)
    }
    return encode(signature)
  }

  // MARK: Helpers

  private static func badArgs(_ names: String) -> FlutterError {
    FlutterError(code: "bad_args", message: "missing or malformed: \(names)", details: nil)
  }

  /// base64url without padding.
  private static func encode(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  /// base64 or base64url, padded or not.
  private static func decode(_ text: String) -> Data? {
    var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while s.count % 4 != 0 { s += "=" }
    return Data(base64Encoded: s)
  }
}

/// Keeps the newest MetricKit crash diagnostic until the Dart side takes it.
///
/// MetricKit delivers a crash at a later launch (on iOS 15 and later, usually the next one), on its
/// own queue and at its own time, so the subscriber is registered when the plugin is, and the
/// diagnostics already delivered (`pastDiagnosticPayloads`) are read at the same moment. One
/// diagnostic is kept in UserDefaults, small: the exception and signal, the termination reason, and
/// the crashed thread's frames as `binary +offset` lines (no symbols: the app has none at run time).
/// `take()` hands it over once; the time of the last one taken is remembered, so a payload MetricKit
/// delivers again is not offered twice.
@available(iOS 14.0, *)
final class CrashDiagnostics: NSObject, MXMetricManagerSubscriber {
  static let shared = CrashDiagnostics()
  private static let keptKey = "app.overblast.feedback.crash"
  private static let takenKey = "app.overblast.feedback.crashTakenAt"
  private var started = false

  func start() {
    guard !started else { return }
    started = true
    MXMetricManager.shared.add(self)
    keep(MXMetricManager.shared.pastDiagnosticPayloads)
  }

  func didReceive(_ payloads: [MXDiagnosticPayload]) { keep(payloads) }

  static func take() -> [String: Any]? {
    let defaults = UserDefaults.standard
    guard let kept = defaults.dictionary(forKey: keptKey) else { return nil }
    defaults.removeObject(forKey: keptKey)
    if let at = kept["at"] as? NSNumber { defaults.set(at.int64Value, forKey: takenKey) }
    return kept
  }

  private func keep(_ payloads: [MXDiagnosticPayload]) {
    var newest: (Date, MXCrashDiagnostic)?
    for payload in payloads {
      for diagnostic in payload.crashDiagnostics ?? [] where newest == nil || payload.timeStampEnd > newest!.0 {
        newest = (payload.timeStampEnd, diagnostic)
      }
    }
    guard let found = newest else { return }
    let (date, diagnostic) = found
    let at = Int64(date.timeIntervalSince1970 * 1000)
    let defaults = UserDefaults.standard
    if defaults.object(forKey: Self.takenKey) != nil, at <= Int64(defaults.integer(forKey: Self.takenKey)) { return }
    if let kept = defaults.dictionary(forKey: Self.keptKey), let keptAt = kept["at"] as? NSNumber,
      keptAt.int64Value >= at
    {
      return
    }
    var record: [String: Any] = ["kind": "crash", "source": "metrickit", "at": at]
    let message = Self.message(diagnostic)
    if !message.isEmpty { record["message"] = message }
    if let stack = Self.stack(diagnostic) { record["stack"] = stack }
    defaults.set(record, forKey: Self.keptKey)
  }

  private static func message(_ d: MXCrashDiagnostic) -> String {
    var parts: [String] = []
    if #available(iOS 17.0, *), let reason = d.exceptionReason {
      parts.append("\(reason.exceptionName): \(reason.composedMessage)")
    }
    if let type = d.exceptionType { parts.append(machException(type.intValue)) }
    if let signal = d.signal { parts.append(signalName(signal.intValue)) }
    if let termination = d.terminationReason, !termination.isEmpty { parts.append(termination) }
    return String(parts.joined(separator: ", ").prefix(2000))
  }

  /// The attributed thread's frames, outermost call last, at most 60 lines.
  private static func stack(_ d: MXCrashDiagnostic) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: d.callStackTree.jsonRepresentation()) as? [String: Any],
      let stacks = json["callStacks"] as? [[String: Any]]
    else { return nil }
    let thread = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks.first
    var frame = (thread?["callStackRootFrames"] as? [[String: Any]])?.first
    var lines: [String] = []
    while let f = frame, lines.count < 60 {
      let binary = f["binaryName"] as? String ?? "?"
      let offset = (f["offsetIntoBinaryTextSegment"] as? NSNumber)?.int64Value ?? 0
      lines.append("\(lines.count) \(binary) +\(offset)")
      frame = (f["subFrames"] as? [[String: Any]])?.first
    }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
  }

  private static func machException(_ type: Int) -> String {
    switch type {
    case 1: return "EXC_BAD_ACCESS"
    case 2: return "EXC_BAD_INSTRUCTION"
    case 3: return "EXC_ARITHMETIC"
    case 5: return "EXC_SOFTWARE"
    case 6: return "EXC_BREAKPOINT"
    case 10: return "EXC_CRASH"
    case 11: return "EXC_RESOURCE"
    case 12: return "EXC_GUARD"
    default: return "exception \(type)"
    }
  }

  private static func signalName(_ signal: Int) -> String {
    switch signal {
    case 4: return "SIGILL"
    case 5: return "SIGTRAP"
    case 6: return "SIGABRT"
    case 8: return "SIGFPE"
    case 9: return "SIGKILL"
    case 10: return "SIGBUS"
    case 11: return "SIGSEGV"
    case 13: return "SIGPIPE"
    default: return "signal \(signal)"
    }
  }
}
