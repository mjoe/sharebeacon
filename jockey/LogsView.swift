import SwiftUI

struct LogsView: View {
    @EnvironmentObject private var manager: SMBShareManager

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recent Activity")
                    .font(.title2.bold())
                Spacer()
                Button("Open Log File") {
                    manager.openLog()
                }
            }
            .padding()

            Divider()

            Table(manager.logs.reversed()) {
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
        }
    }
}
