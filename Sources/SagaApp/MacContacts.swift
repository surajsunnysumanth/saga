import Contacts
import SagaCore

/// Names from the Mac Contacts app (asks permission once). Returns [] if access is denied.
enum MacContacts {
    static func load() async -> [String: String] {
        let store = CNContactStore()
        guard (try? await store.requestAccess(for: .contacts)) == true else { return [:] }
        return await Task.detached { () -> [String: String] in
            var out: [String: String] = [:]
            let keys = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactPhoneNumbersKey as CNKeyDescriptor]
            let req = CNContactFetchRequest(keysToFetch: keys)
            try? store.enumerateContacts(with: req) { c, _ in
                guard let name = CNContactFormatter.string(from: c, style: .fullName), !name.isEmpty else { return }
                for p in c.phoneNumbers {
                    let n = normalizePhone(p.value.stringValue)
                    if !n.isEmpty, out[n] == nil { out[n] = name }
                }
            }
            return out
        }.value
    }
}
