import Foundation
import Combine

@MainActor
final class AIPIMAccountSourceModel: ObservableObject {
    @Published private(set) var statuses: [AIPIMSource: AIPIMSourceStatus]
    @Published private(set) var busySource: AIPIMSource?

    private let connector: any AIPIMSourceConnecting

    init(connector: any AIPIMSourceConnecting = AIPIMClient()) {
        self.connector = connector
        self.statuses = Dictionary(
            uniqueKeysWithValues: AIPIMSource.allCases.map { ($0, AIPIMSourceStatus.unchecked($0)) }
        )
    }

    func status(for source: AIPIMSource) -> AIPIMSourceStatus {
        statuses[source] ?? .unchecked(source)
    }

    func actionTitle(for source: AIPIMSource) -> String {
        status(for: source).authenticated ? "Reconnect" : "Connect"
    }

    func refreshAll() async {
        async let outlookStatus = connector.status(for: .outlook)
        async let slackStatus = connector.status(for: .slack)
        async let teamsStatus = connector.status(for: .teams)
        statuses[.outlook] = await outlookStatus
        statuses[.slack] = await slackStatus
        statuses[.teams] = await teamsStatus
    }

    func refresh(_ source: AIPIMSource) async {
        busySource = source
        statuses[source] = await connector.status(for: source)
        busySource = nil
    }

    func connect(_ source: AIPIMSource) async {
        busySource = source
        statuses[source] = await connector.login(to: source)
        busySource = nil
    }
}
