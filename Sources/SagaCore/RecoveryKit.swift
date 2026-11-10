import Foundation

/// Transient presentation material supplied by the encryption layer. Not a key generator,
/// credential validator, backup, or serializable model. PDF export is an explicit user action.
public struct RecoveryKitMaterial: Sendable, CustomReflectable {
    public let vaultID: String
    public let recoveryCode: String

    public init(vaultID: String, recoveryCode: String) {
        self.vaultID = vaultID
        self.recoveryCode = recoveryCode
    }

    public var customMirror: Mirror {
        Mirror(self, children: ["material": "<private>"], displayStyle: .struct)
    }
}

public enum RecoveryKit {
    public static func instructions(vaultID: String) -> String {
        """
        Keep this kit private and separate from your archive. Anyone with this kit and the encrypted archive can read its protected contents. This kit is not a backup.

        To recover on this Mac or a new Mac:
        1. Install a compatible version of Saga.
        2. Open or select the archived folder with archive ID \(vaultID).
        3. Choose recovery and enter the complete recovery code.
        4. After unlocking, optionally set a new passphrase and remember the unlock on this Mac.

        The kit alone cannot recreate lost archive files or repair corruption. Keep a separate archive backup. If your passphrase, Recovery Kit, and remembered unlock are all unavailable, Saga cannot recover the encrypted contents.
        """
    }

    public static let kitVersion = 1
    public static let title = "Saga Recovery Kit"

    /// Content of the printable page: version, archive ID, code and instructions only.
    public static func pageText(for material: RecoveryKitMaterial) -> (header: [String], code: String, body: String) {
        ([title, "Kit version \(kitVersion)", "Archive ID: \(material.vaultID)"],
         material.recoveryCode, instructions(vaultID: material.vaultID))
    }
}

public enum RecoveryKitExportResult: Sendable, Equatable {
    case saved, cancelled, failed
}

public enum RecoveryKitConfirmationError: Error, Equatable, Sendable {
    case notSaved          // no successful export/print yet
    case notAcknowledged   // "I stored this kit" not ticked
    case emptyCode         // nothing typed
}

/// Pure gate state for the kit screen. It never judges the typed code: the full code goes to the
/// Core `confirmRecovery` callback, so no weaker normalization exists in the UI layer.
/// A throwing callback leaves the state unconfirmed so the user can retry.
public struct RecoveryKitConfirmation: Sendable {
    public var typedCode = ""
    public var hasSavedCopy = false          // user acknowledgement
    public private(set) var hasExported = false
    public private(set) var isConfirmed = false
    public private(set) var lastExport: RecoveryKitExportResult?

    public init() {}

    public var canConfirm: Bool {
        hasExported && hasSavedCopy && !typedCode.isEmpty && !isConfirmed
    }

    /// A save/print attempt. Cancel/failure never counts; each attempt resets the acknowledgement.
    public mutating func recordExport(_ result: RecoveryKitExportResult) {
        lastExport = result
        hasSavedCopy = false
        if result == .saved { hasExported = true }
    }

    public mutating func confirm(_ onConfirm: (String) throws -> Void) throws {
        guard hasExported else { throw RecoveryKitConfirmationError.notSaved }
        guard hasSavedCopy else { throw RecoveryKitConfirmationError.notAcknowledged }
        guard !typedCode.isEmpty else { throw RecoveryKitConfirmationError.emptyCode }
        try onConfirm(typedCode)
        isConfirmed = true
        clear()
    }

    /// Clears transient secret-bearing view state (best effort; not memory zeroization).
    public mutating func clear() {
        typedCode = ""
        hasSavedCopy = false
    }
}
