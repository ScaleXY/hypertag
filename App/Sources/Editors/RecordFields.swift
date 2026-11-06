import SwiftUI

/// The rows for one record. Lives inside a Form section.
struct RecordFields: View {
    @Binding var record: EditableRecord

    var body: some View {
        Picker("Type", selection: $record.kind) {
            ForEach(EditableRecord.Kind.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Record type")

        switch record.kind {
        case .url:
            TextField("https://example.com", text: $record.url)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Web address")
        case .text:
            TextField("Text", text: $record.text, axis: .vertical)
                .lineLimit(2...8)
            LabeledContent("Language") {
                TextField("en", text: $record.language)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        case .contact:
            TextField("Name", text: $record.contact.name)
                .textContentType(.name)
            TextField("Phone", text: $record.contact.phone)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
            TextField("Email", text: $record.contact.email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Organization", text: $record.contact.organization)
                .textContentType(.organizationName)
        case .mime:
            TextField("application/json", text: $record.mimeType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Media type")
            Toggle("Content is hex", isOn: $record.mimeBodyIsHex)
            TextField(record.mimeBodyIsHex ? "0A FF 3C" : "Content", text: $record.mimeBody, axis: .vertical)
                .lineLimit(3...10)
                .font(record.mimeBodyIsHex ? .body.monospaced() : .body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Content")
        }

        if let message = record.validationMessage {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }
}
