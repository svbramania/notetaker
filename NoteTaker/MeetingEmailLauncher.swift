import AppKit
import Foundation

enum MeetingEmailClient: String, CaseIterable, Identifiable {
    case appleMail = "Apple Mail"
    case microsoftOutlook = "Microsoft Outlook"
    case gmail = "Gmail in Browser"

    var id: String { rawValue }

    var bundleIdentifier: String? {
        switch self {
        case .appleMail:
            return "com.apple.mail"
        case .microsoftOutlook:
            return "com.microsoft.Outlook"
        case .gmail:
            return nil
        }
    }
}

struct MeetingEmailDraft: Equatable {
    let recipients: [String]
    let subject: String
    let body: String
}

enum RecipientSelectionPolicy {
    static func initialSelection(
        from recipients: [MeetingEmailRecipient],
        lastSelectedEmail: String
    ) -> Set<String> {
        let remembered = lastSelectedEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remembered.isEmpty else { return [] }
        return Set(
            recipients
                .filter { $0.email.localizedCaseInsensitiveCompare(remembered) == .orderedSame }
                .map(\.id)
        )
    }
}

enum MeetingEmailLauncherError: LocalizedError {
    case couldNotCreateDraft
    case applicationUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .couldNotCreateDraft:
            return "The email draft could not be prepared."
        case .applicationUnavailable(let application):
            return "Install or enable \(application), then try again."
        }
    }
}

enum MeetingEmailDraftURLBuilder {
    static func url(for draft: MeetingEmailDraft, client: MeetingEmailClient) -> URL? {
        switch client {
        case .appleMail, .microsoftOutlook:
            var components = URLComponents()
            components.scheme = "mailto"
            components.path = draft.recipients.joined(separator: ",")
            components.queryItems = [
                URLQueryItem(name: "subject", value: draft.subject),
                URLQueryItem(name: "body", value: draft.body)
            ]
            return components.url
        case .gmail:
            var components = URLComponents(string: "https://mail.google.com/mail/")
            components?.queryItems = [
                URLQueryItem(name: "view", value: "cm"),
                URLQueryItem(name: "fs", value: "1"),
                URLQueryItem(name: "to", value: draft.recipients.joined(separator: ",")),
                URLQueryItem(name: "su", value: draft.subject),
                URLQueryItem(name: "body", value: draft.body)
            ]
            return components?.url
        }
    }
}

@MainActor
enum MeetingEmailLauncher {
    static func launch(_ draft: MeetingEmailDraft, with client: MeetingEmailClient) throws {
        guard let draftURL = MeetingEmailDraftURLBuilder.url(for: draft, client: client) else {
            throw MeetingEmailLauncherError.couldNotCreateDraft
        }

        let workspace = NSWorkspace.shared
        if let bundleIdentifier = client.bundleIdentifier {
            guard let applicationURL = workspace.urlForApplication(
                withBundleIdentifier: bundleIdentifier
            ) else {
                throw MeetingEmailLauncherError.applicationUnavailable(client.rawValue)
            }
            workspace.open(
                [draftURL],
                withApplicationAt: applicationURL,
                configuration: NSWorkspace.OpenConfiguration(),
                completionHandler: nil
            )
        } else {
            workspace.open(draftURL)
        }
    }
}
