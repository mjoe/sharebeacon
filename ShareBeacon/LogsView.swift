import SwiftUI

struct LogsView: View {
    @Environment(AppLogger.self) private var logger
    @State private var minimumLevel: LogLevel = .debug

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Level", selection: $minimumLevel) {
                    Text("All").tag(LogLevel.debug)
                    Text("Warnings").tag(LogLevel.warning)
                    Text("Errors").tag(LogLevel.error)
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                .help("Show entries at this level or above")

                Spacer()

                Button {
                    NSWorkspace.shared.open(AppLogger.shared.logURL)
                } label: {
                    Label("Open Full Log", systemImage: "doc.text")
                }
                .help("Open the complete log file in a text editor")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            Table(filteredEntries) {
                TableColumn("Time") { entry in
                    Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                }
                .width(min: 90, ideal: 110)

                TableColumn("Level") { entry in
                    Text(entry.level.rawValue)
                }
                .width(min: 70, ideal: 80)

                TableColumn("Message") { entry in
                    Text(entry.message)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .frame(minWidth: 560, minHeight: 360)
    }

    private var filteredEntries: [AppLogEntry] {
        logger.recentEntries
            .filter { Self.severity(of: $0.level) >= Self.severity(of: minimumLevel) }
            .reversed()
    }

    private static func severity(of level: LogLevel) -> Int {
        switch level {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }
}
