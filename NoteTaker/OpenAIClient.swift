import Foundation

struct OpenAIClient {
    let apiKey: String

    func transcribe(audioURL: URL, sourceLabel: String) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let data = try Data(contentsOf: audioURL)
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", "gpt-4o-transcribe")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\r\nContent-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (responseData, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: responseData)
        let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        let text = object?["text"] as? String ?? ""
        return "[\(sourceLabel)]\n\(text)"
    }

    func generateNotes(title: String, startedAt: Date, endedAt: Date, attendees: [String], manualNotes: String, transcript: String) async throws -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        let prompt = """
        Create executive-quality meeting notes using the Pyramid Principle. Lead with the answer/conclusion, then group supporting points logically and mutually exclusively where practical. Do not bury the most important outcome.

        REQUIRED FORMAT (Markdown):
        # <meeting title>
        **Date & time:** ...
        **Attendees:** ... (say "Not available" if none were supplied)

        ## Executive takeaway
        2-5 sentences stating the most important conclusion, outcome, or current state first.

        ## What matters most
        Group the supporting discussion into 2-5 logically distinct themes. Each theme starts with a conclusion-led heading, followed by concise evidence/context bullets.

        ## Decisions
        List explicit decisions only. If none, say "No explicit decisions captured."

        ## Action items
        Use a Markdown table with columns Owner | Action | Due date | Status. Never invent an owner or due date. Use "Unassigned" or "Not specified" when missing.

        ## Open questions / risks
        List unresolved questions, blockers, dependencies, or risks.

        ## Meeting metadata
        Include meeting title, start/end time, and attendee list.

        Rules:
        - Distinguish firm decisions from proposals or ideas.
        - Do not invent attendees, dates, commitments, owners, or facts.
        - Give manual notes extra weight because they reflect the user's perspective.
        - The microphone transcript is primarily the local user's speech. The system-audio transcript is primarily remote participants / meeting output; because tracks are separate, do not claim exact chronology unless clearly supported.
        - Keep notes concise and useful for follow-through.

        Meeting title: \(title.isEmpty ? "Untitled meeting" : title)
        Start: \(formatter.string(from: startedAt))
        End: \(formatter.string(from: endedAt))
        Attendees supplied: \(attendees.isEmpty ? "Not available" : attendees.joined(separator: ", "))

        USER'S MANUAL NOTES:
        \(manualNotes.isEmpty ? "None" : manualNotes)

        TRANSCRIPTS:
        \(transcript)
        """

        let payload: [String: Any] = [
            "model": "gpt-5-mini",
            "store": false,
            "input": prompt
        ]
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let output = object?["output"] as? [[String: Any]] {
            for item in output {
                guard let content = item["content"] as? [[String: Any]] else { continue }
                for part in content {
                    if let text = part["text"] as? String, !text.isEmpty { return text }
                }
            }
        }
        throw NSError(domain: "NoteTaker", code: 20, userInfo: [NSLocalizedDescriptionKey: "The notes response did not contain text."])
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "Unknown API error"
            throw NSError(domain: "NoteTaker", code: 21, userInfo: [NSLocalizedDescriptionKey: detail])
        }
    }
}
