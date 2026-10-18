import SwiftUI

struct ImportJobReviewView: View {
    let job: ImportJob
    let language: AppLanguage
    let confirm: ([Int]) async throws -> Void
    let cancelJob: () async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIndices: Set<Int>
    @State private var errorText: String?
    @State private var isWorking = false

    init(
        job: ImportJob,
        language: AppLanguage,
        confirm: @escaping ([Int]) async throws -> Void,
        cancelJob: @escaping () async throws -> Void
    ) {
        self.job = job
        self.language = language
        self.confirm = confirm
        self.cancelJob = cancelJob
        _selectedIndices = State(initialValue: Set(job.pendingConfirmIndexes ?? job.preview.map(\.index)))
    }

    var body: some View {
        ZStack {
            NodusPalette.background.ignoresSafeArea()
            Backdrop()

            VStack(alignment: .leading, spacing: 18) {
                NodusSheetDragIndicator().frame(maxWidth: .infinity)
                Text(language.localizedString("Review import"))
                    .font(.cormorant(32, weight: .light, italic: true))
                    .foregroundStyle(NodusPalette.primary)
                Text(job.fileName ?? "")
                    .font(.system(size: 13))
                    .foregroundStyle(NodusPalette.secondary)

                if job.statusRaw == "ready" {
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(job.preview, id: \.index) { node in
                                Toggle(isOn: binding(for: node.index)) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(node.title).foregroundStyle(NodusPalette.primary)
                                        Text([node.date, node.time].compactMap { $0 }.joined(separator: " · "))
                                            .font(.system(size: 12))
                                            .foregroundStyle(NodusPalette.secondary)
                                    }
                                }
                                .tint(NodusPalette.accent)
                                .disabled(job.pendingConfirmKey != nil)
                            }
                        }
                    }
                    if !job.previewIssues.isEmpty {
                        Text("Some rows could not be imported: \(job.previewIssues.count)")
                            .font(.system(size: 13))
                            .foregroundStyle(NodusPalette.secondary)
                    }
                    NodusSheetFooterButton(
                        title: "Import selected",
                        isDisabled: isWorking || selectedIndices.isEmpty
                    ) {
                        Task { await confirmSelection() }
                    }
                } else if let error = job.error {
                    Text(language.localizedString(errorMessageKey(error)))
                        .foregroundStyle(NodusPalette.secondary)
                } else if job.statusRaw == "completed", let result = job.result {
                    Text(String(format: language.localizedString("Imported knots: %lld."), result.createdNodes))
                        .foregroundStyle(NodusPalette.secondary)
                    Text(String(format: language.localizedString("Skipped duplicates: %lld · inactive: %lld"), result.skippedDuplicates, result.skippedInactive))
                        .font(.system(size: 13))
                        .foregroundStyle(NodusPalette.secondary)
                } else if job.statusRaw == "expired" {
                    Text(language.localizedString("This preview has expired. Import the file again."))
                        .foregroundStyle(NodusPalette.secondary)
                } else {
                    Text(language.localizedString(job.statusRaw == "failed" ? "Import failed" : job.statusRaw == "cancelled" ? "Import cancelled" : "Import is being processed"))
                        .foregroundStyle(NodusPalette.secondary)
                }

                if let errorText {
                    Text(errorText).font(.system(size: 13)).foregroundStyle(NodusPalette.secondary)
                }
                if ["queued", "processing", "ready", "failed"].contains(job.statusRaw) {
                    Button(language.localizedString("Cancel import")) {
                        Task { await cancelImport() }
                    }
                    .disabled(isWorking)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(NodusPalette.secondary)
                }
            }
            .padding(24)
        }
        .presentationDetents([.large])
    }

    private func binding(for index: Int) -> Binding<Bool> {
        Binding(
            get: { selectedIndices.contains(index) },
            set: { isSelected in
                if isSelected { selectedIndices.insert(index) }
                else { selectedIndices.remove(index) }
            }
        )
    }

    private func confirmSelection() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await confirm(selectedIndices.sorted())
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func cancelImport() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await cancelJob()
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func errorMessageKey(_ code: String) -> String {
        switch code {
        case "ai_unavailable", "ai_temporarily_unavailable", "timed_out": "AI processing is unavailable. Try again later or import a Nodus file."
        case "invalid_ai_response", "nothing_recognized": "No knots were recognized. Try again later or import a Nodus file."
        case "input_expired", "expired": "This preview has expired. Import the file again."
        default: code
        }
    }
}
