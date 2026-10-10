import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The same compact file surface is used during writing and after completion.
struct GeneratedFileCard: View {
    let file: VirtualFile
    var isWriting = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var expanded = false
    @State private var copied = false
    @State private var exporting = false
    @State private var exportDocument = GeneratedTextDocument(text: "")
    @State private var exportError: String?
    @State private var copyReset: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 20)).foregroundStyle(Color.conduitAccent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.path).font(.subheadline.weight(.semibold))
                        .lineLimit(1).truncationMode(.middle)
                    Text(isWriting ? "Writing…" : "Ready")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    UIPasteboard.general.string = file.content
                    copied = true
                    copyReset?.cancel()
                    copyReset = Task { @MainActor in
                        do {
                            try await Task.sleep(for: .seconds(1.5))
                            copied = false
                        } catch { }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copied ? Color.green : Color.primary)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel(copied ? "Copied \(file.path)" : "Copy \(file.path)")
                .disabled(file.content.isEmpty)
                Button {
                    // Snapshot the current code so an export never changes mid-save.
                    exportDocument = GeneratedTextDocument(text: file.content)
                    exporting = true
                } label: {
                    Image(systemName: "arrow.down.to.line").frame(width: 36, height: 36)
                }
                .accessibilityLabel("Download \(file.path)")
                .disabled(file.content.isEmpty)
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 32, height: 36)
                }
                .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(file.path)")
            }
            .buttonStyle(.plain)
            .padding(12)

            if expanded {
                Divider().padding(.horizontal, 12)
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(file.content)
                        .font(.system(size: 13 * Appearance.textScale, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(14)
                }
            }
        }
        .background(Color(white: colorScheme == .dark ? 0.18 : 0.93), in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.1)) }
        .fileExporter(isPresented: $exporting, document: exportDocument,
                      contentType: UTType(filenameExtension: (file.path as NSString).pathExtension) ?? .plainText,
                      defaultFilename: (file.path as NSString).lastPathComponent) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .alert("Could not save file", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: { Text(exportError ?? "") }
        .onDisappear { copyReset?.cancel() }
    }
}

private struct GeneratedTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
