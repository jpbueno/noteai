import SwiftUI

/// Setup sheet for T5T subject line configuration (vertical, region, job function).
struct T5TConfigSheet: View {
    @Binding var config: T5TConfig
    var onSave: (T5TConfig) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Configure T5T")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Set up your T5T subject line. This determines how your report is sorted and identified.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Subject line format:")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                Text("Top 5 Things - \(config.vertical.isEmpty ? "[Vertical]" : config.vertical) | \(config.region.isEmpty ? "[Region]" : config.region) | \(config.jobFunction.isEmpty ? "[Job Function]" : config.jobFunction)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.hoverBG, in: RoundedRectangle(cornerRadius: 6))
            }

            Form {
                TextField("Vertical / Platform / Account", text: $config.vertical)
                    .textFieldStyle(.roundedBorder)
                Text("e.g., Cloud Native AI, Strategics, DGX, Healthcare, Drive")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)

                TextField("Region / Overlay", text: $config.region)
                    .textFieldStyle(.roundedBorder)
                Text("e.g., NALA, EMEA, Japan, GAM")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)

                TextField("Job Function", text: $config.jobFunction)
                    .textFieldStyle(.roundedBorder)
                Text("e.g., SA, AM, DevRel, OS, FAE, PBM")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                Button("Save") {
                    onSave(config)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!config.isComplete)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Theme.contentBG)
    }
}

/// Embeddable version for Settings tab (no dismiss/save buttons).
struct T5TConfigEditor: View {
    @Binding var config: T5TConfig
    var onSave: (T5TConfig) -> Void

    var body: some View {
        Form {
            Section("T5T Subject Line") {
                TextField("Vertical / Platform / Account", text: $config.vertical)
                Text("e.g., Cloud Native AI, Strategics, DGX, Healthcare")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Region / Overlay", text: $config.region)
                Text("e.g., NALA, EMEA, Japan, GAM")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Job Function", text: $config.jobFunction)
                Text("e.g., SA, AM, DevRel, OS, FAE")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if config.isComplete {
                Section("Preview") {
                    Text(config.subjectLine)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: config) { _, newValue in
            if newValue.isComplete {
                onSave(newValue)
            }
        }
    }
}
