import SwiftUI

struct LogsView: View {
    @Environment(AppLogger.self) private var logger

    var body: some View {
        Table(logger.recentEntries.reversed()) {
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
        .frame(minWidth: 560, minHeight: 360)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Open Log File", systemImage: "doc.text") {
                    NSWorkspace.shared.open(AppLogger.shared.logURL)
                }
                .help("Open the log file in a text editor")
            }
        }
    }
}
