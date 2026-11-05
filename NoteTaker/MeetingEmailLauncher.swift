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

    var senderAccountDefaultsKey: String {
        "meetingEmailSenderAccount.\(id)"
    }

    static func available(
        installedBundleIdentifiers: Set<String>,
        hasWebBrowser: Bool
    ) -> [MeetingEmailClient] {
        allCases.filter { client in
            if let bundleIdentifier = client.bundleIdentifier {
                return installedBundleIdentifiers.contains(bundleIdentifier)
            }
            return hasWebBrowser
        }
    }

    static func pickerValues(
        available: [MeetingEmailClient],
        selectedRawValue: String
    ) -> [String] {
        var values = available.map(\.rawValue)
        if !selectedRawValue.isEmpty, !values.contains(selectedRawValue) {
            values.append(selectedRawValue)
        }
        return values
    }

    @MainActor
    static func installed(using workspace: NSWorkspace = .shared) -> [MeetingEmailClient] {
        let installedBundleIdentifiers = Set(
            allCases.compactMap(\.bundleIdentifier).filter {
                workspace.urlForApplication(withBundleIdentifier: $0) != nil
            }
        )
        let gmailURL = URL(string: "https://mail.google.com/mail/")!
        let hasWebBrowser = workspace.urlForApplication(toOpen: gmailURL) != nil
        return available(
            installedBundleIdentifiers: installedBundleIdentifiers,
            hasWebBrowser: hasWebBrowser
        )
    }
}

struct MeetingEmailDraft: Equatable {
    let recipients: [String]
    let subject: String
    let body: String
    let senderAccount: String
}

enum MeetingNotesEmailFormatter {
    private static let nonbreakingSpace = "\u{00A0}"

    static func format(_ notes: String) -> String {
        let normalized = notes
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var output: [String] = []
        var previousWasBlank = false
        for rawLine in normalized.components(separatedBy: .newlines) {
            var line = rawLine.replacingOccurrences(
                of: #"^\s*#{1,6}\s*"#,
                with: "",
                options: .regularExpression
            )
            line = line.replacingOccurrences(of: "**", with: "")

            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !previousWasBlank, !output.isEmpty { output.append("") }
                previousWasBlank = true
                continue
            }

            previousWasBlank = false
            if let bullet = bulletComponents(in: line) {
                let level = bullet.marker == "◦"
                    ? max(1, bullet.leadingSpaces / 4)
                    : max(0, bullet.leadingSpaces / 2)
                let indentation = String(
                    repeating: nonbreakingSpace,
                    count: level * 4
                )
                let marker = level == 0 ? "•" : "◦"
                output.append("\(indentation)\(marker) \(bullet.text)")
            } else {
                output.append(line.trimmingCharacters(in: .whitespaces))
            }
        }

        while output.last == "" { output.removeLast() }
        return output.joined(separator: "\n")
    }

    private static func bulletComponents(in line: String) -> (
        leadingSpaces: Int,
        marker: String,
        text: String
    )? {
        let pattern = #"^(\s*)([-*+•◦])\s+(.+)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: line,
                range: NSRange(line.startIndex..<line.endIndex, in: line)
              ),
              let whitespaceRange = Range(match.range(at: 1), in: line),
              let markerRange = Range(match.range(at: 2), in: line),
              let textRange = Range(match.range(at: 3), in: line) else {
            return nil
        }
        let whitespace = line[whitespaceRange]
        let leadingSpaces = whitespace.reduce(0) { count, character in
            count + (character == "\t" ? 2 : 1)
        }
        return (
            leadingSpaces,
            String(line[markerRange]),
            String(line[textRange])
        )
    }

}

enum MeetingNotesRichTextFormatter {
    private static let nonbreakingSpace: Character = "\u{00A0}"
    private static let bulletIndent: CGFloat = 18
    private static let bulletGap = "\u{2003}"

    static func format(_ notes: String) -> NSAttributedString {
        let plainText = MeetingNotesEmailFormatter.format(notes)
        let result = NSMutableAttributedString(string: "")
        let lines = plainText.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            let attributedLine = formattedLine(line)
            result.append(attributedLine)
            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n"))
            }
        }
        return result
    }

    private static func formattedLine(_ line: String) -> NSAttributedString {
        let leadingSpaces = line.prefix { $0 == nonbreakingSpace }.count
        let content = String(line.dropFirst(leadingSpaces))
        if content.hasPrefix("• ") || content.hasPrefix("◦ ") {
            let level = max(content.hasPrefix("◦ ") ? 1 : 0, leadingSpaces / 4)
            let marker = level == 0 ? "•" : "◦"
            let text = String(content.dropFirst(2))
            let firstLineIndent = CGFloat(level) * bulletIndent
            let textIndent = firstLineIndent + bulletIndent
            let paragraph = NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = firstLineIndent
            paragraph.headIndent = textIndent
            paragraph.paragraphSpacing = 3
            return NSAttributedString(
                string: "\(marker)\(bulletGap)\(text)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .paragraphStyle: paragraph
                ]
            )
        }

        let trimmed = content.trimmingCharacters(in: .whitespaces)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = trimmed.isEmpty ? 0 : 4
        let isHeading = !trimmed.isEmpty
            && trimmed == trimmed.uppercased()
            && trimmed.rangeOfCharacter(from: .letters) != nil
        return NSAttributedString(
            string: trimmed,
            attributes: [
                .font: isHeading
                    ? NSFont.boldSystemFont(ofSize: 13)
                    : NSFont.systemFont(ofSize: 13),
                .paragraphStyle: paragraph
            ]
        )
    }
}

enum MeetingEmailSenderAccount {
    static func normalized(_ account: String) -> String {
        account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isValid(_ account: String) -> Bool {
        let normalizedAccount = normalized(account)
        return EmailAddressExtractor.addresses(in: normalizedAccount) == [normalizedAccount]
    }
}

enum RecipientSelectionPolicy {
    static func decodedSelection(_ value: String) -> Set<String>? {
        guard !value.isEmpty,
              let data = value.data(using: .utf8),
              let emails = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return Set(emails.map { $0.lowercased() })
    }

    static func encodedSelection(_ emails: Set<String>) -> String {
        let normalized = emails.map { $0.lowercased() }.sorted()
        guard let data = try? JSONEncoder().encode(normalized),
              let value = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return value
    }

    static func rememberedEmails(
        encodedSelection: String,
        lastSelectedEmail: String
    ) -> Set<String> {
        if let decoded = decodedSelection(encodedSelection) {
            return decoded
        }
        let remembered = lastSelectedEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        return remembered.isEmpty ? [] : [remembered.lowercased()]
    }

    static func initialSelection(
        from recipients: [MeetingEmailRecipient],
        encodedSelection: String,
        lastSelectedEmail: String
    ) -> Set<String> {
        let remembered = rememberedEmails(
            encodedSelection: encodedSelection,
            lastSelectedEmail: lastSelectedEmail
        )
        return Set(
            recipients
                .filter { remembered.contains($0.email.lowercased()) }
                .map(\.id)
        )
    }
}

enum MeetingEmailLauncherError: LocalizedError {
    case couldNotCreateDraft
    case applicationUnavailable(String)
    case applicationRejectedDraft(String)

    var errorDescription: String? {
        switch self {
        case .couldNotCreateDraft:
            return "The email draft could not be prepared."
        case .applicationUnavailable(let application):
            return "Install or enable \(application), then try again."
        case .applicationRejectedDraft(let application):
            return "macOS could not open the draft in \(application). Confirm the app is installed and selected as an email client, then retry."
        }
    }
}

enum MeetingEmailLaunchOutcome: Equatable {
    case openedWithBody
    case openedWithBodyCopied
}

enum MeetingEmailDraftPreparationError: LocalizedError, Equatable {
    case emailClientNotSelected
    case senderAccountMissing
    case recipientsMissing

    var errorDescription: String? {
        switch self {
        case .emailClientNotSelected:
            return "Select an email client in the Meeting tab before generating notes."
        case .senderAccountMissing:
            return "Enter a valid sender email account for the selected email client."
        case .recipientsMissing:
            return "Enter at least one email address under Email recipients, then select it or enable Send to everyone."
        }
    }
}

enum MeetingEmailDraftPreparation {
    static func prepare(
        notes: String,
        meetingTitle: String,
        recipients: [MeetingEmailRecipient],
        emailEveryone: Bool,
        selectedRecipientEmails: Set<String>,
        clientRawValue: String,
        senderAccount: String
    ) throws -> (draft: MeetingEmailDraft, client: MeetingEmailClient) {
        guard let client = MeetingEmailClient(rawValue: clientRawValue) else {
            throw MeetingEmailDraftPreparationError.emailClientNotSelected
        }
        guard MeetingEmailSenderAccount.isValid(senderAccount) else {
            throw MeetingEmailDraftPreparationError.senderAccountMissing
        }
        let selected = emailEveryone
            ? recipients.map(\.email)
            : recipients
                .filter {
                    selectedRecipientEmails.contains($0.email.lowercased())
                }
                .map(\.email)
        guard !selected.isEmpty else {
            throw MeetingEmailDraftPreparationError.recipientsMissing
        }
        return (
            MeetingEmailDraft(
                recipients: selected,
                subject: meetingTitle.isEmpty ? "Meeting notes" : "Meeting notes: \(meetingTitle)",
                body: MeetingNotesEmailFormatter.format(notes),
                senderAccount: senderAccount
            ),
            client
        )
    }
}

enum MeetingEmailDraftURLBuilder {
    static func url(
        for draft: MeetingEmailDraft,
        client: MeetingEmailClient,
        includeBody: Bool = true
    ) -> URL? {
        switch client {
        case .appleMail, .microsoftOutlook:
            var components = URLComponents()
            components.scheme = "mailto"
            components.path = draft.recipients.joined(separator: ",")
            components.queryItems = [
                URLQueryItem(name: "subject", value: draft.subject),
                URLQueryItem(name: "from", value: draft.senderAccount)
            ]
            if includeBody {
                components.queryItems?.append(URLQueryItem(name: "body", value: draft.body))
            }
            return components.url
        case .gmail:
            var components = URLComponents(string: "https://mail.google.com/mail/")
            components?.queryItems = [
                URLQueryItem(name: "view", value: "cm"),
                URLQueryItem(name: "fs", value: "1"),
                URLQueryItem(name: "authuser", value: draft.senderAccount),
                URLQueryItem(name: "to", value: draft.recipients.joined(separator: ",")),
                URLQueryItem(name: "su", value: draft.subject)
            ]
            if includeBody {
                components?.queryItems?.append(URLQueryItem(name: "body", value: draft.body))
            }
            return components?.url
        }
    }
}

@MainActor
enum MeetingEmailLauncher {
    static func launch(
        _ draft: MeetingEmailDraft,
        with client: MeetingEmailClient
    ) async throws -> MeetingEmailLaunchOutcome {
        let richBody = MeetingNotesRichTextFormatter.format(draft.body)
        if client != .gmail,
           isDefaultMailClient(client),
           let service = NSSharingService(named: .composeEmail),
           service.canPerform(withItems: [richBody]) {
            service.recipients = draft.recipients
            service.subject = draft.subject
            service.perform(withItems: [richBody])
            return .openedWithBody
        }

        return try await openRichTextFallback(draft, richBody: richBody, with: client)
    }

    private static func openRichTextFallback(
        _ draft: MeetingEmailDraft,
        richBody: NSAttributedString,
        with client: MeetingEmailClient
    ) async throws -> MeetingEmailLaunchOutcome {
        guard let shortDraftURL = MeetingEmailDraftURLBuilder.url(
            for: draft,
            client: client,
            includeBody: false
        ) else {
            throw MeetingEmailLauncherError.couldNotCreateDraft
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !pasteboard.writeObjects([richBody]) {
            pasteboard.setString(draft.body, forType: .string)
        }
        try await open(shortDraftURL, with: client)
        return .openedWithBodyCopied
    }

    private static func isDefaultMailClient(_ client: MeetingEmailClient) -> Bool {
        guard let bundleIdentifier = client.bundleIdentifier,
              let mailtoURL = URL(string: "mailto:"),
              let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: mailtoURL) else {
            return false
        }
        return Bundle(url: applicationURL)?.bundleIdentifier == bundleIdentifier
    }

    private static func open(_ draftURL: URL, with client: MeetingEmailClient) async throws {
        let workspace = NSWorkspace.shared
        if let bundleIdentifier = client.bundleIdentifier {
            guard let applicationURL = workspace.urlForApplication(
                withBundleIdentifier: bundleIdentifier
            ) else {
                throw MeetingEmailLauncherError.applicationUnavailable(client.rawValue)
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                workspace.open(
                    [draftURL],
                    withApplicationAt: applicationURL,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } else {
            guard workspace.open(draftURL) else {
                throw MeetingEmailLauncherError.applicationRejectedDraft(client.rawValue)
            }
        }
    }
}
