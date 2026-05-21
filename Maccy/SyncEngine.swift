import Foundation
import Network
import AppKit

extension Notification.Name {
    static let didReceiveRemoteClipboard = Notification.Name("didReceiveRemoteClipboard")
}

class SyncEngine {
    static let shared = SyncEngine()
    
    private let serviceType = "_maccy-sync._tcp"
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var txtRecord = NWTXTRecord()
    
    // Explicitly track our local machine's ID as a plain string for easy comparisons
    private let localMachineID: String
    
    // Tracks the last synced string payload to guarantee we don't form infinite echo loops
    private var lastSyncedContent: String?

    init() {
        let machineName = Host.current().localizedName ?? UUID().uuidString
        self.localMachineID = machineName
        txtRecord["id"] = machineName
    }

    // MARK: - Server (Listen for incoming clipboard data)
    func startServer() {
        do {
            let parameters = NWParameters.tcp
            listener = try NWListener(using: parameters)
            
            // Create the Service definition
            let service = NWListener.Service(name: nil, type: serviceType, domain: nil, txtRecord: txtRecord.data)
            listener?.service = service
            
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleIncomingConnection(connection)
            }
            
            listener?.start(queue: .main)
            print("Maccy Sync Engine: Server listening for peers...")
        } catch {
            print("Maccy Sync Engine: Failed to start listener: \(error)")
        }
    }

    private func handleIncomingConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        var incomingData = Data()
        
        func readNext() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                if let data = data, !data.isEmpty {
                    incomingData.append(data)
                }
                
                if isComplete {
                    if let content = String(data: incomingData, encoding: .utf8) {
                        DispatchQueue.main.async {
                            self?.processIncomingClipboard(content)
                        }
                    }
                    connection.cancel()
                } else if error == nil {
                    readNext() // Keep chunking data if payload isn't done
                }
            }
        }
        readNext()
    }

    private func processIncomingClipboard(_ content: String) {
        guard content != lastSyncedContent else { return }
        self.lastSyncedContent = content
        
        // Notify the Maccy Clipboard observer to ingest this text
        NotificationCenter.default.post(name: .didReceiveRemoteClipboard, object: content)
    }

    // MARK: - Client (Broadcast local clipboard copies out to network)
    func broadcastItem(_ content: String) {
        guard content != lastSyncedContent else { return }
        self.lastSyncedContent = content
        
        guard let data = content.data(using: .utf8) else { return }
        
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        
        browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: parameters)
        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self else { return }
            for result in results {
                // Ignore our own machine instance broadcasting by comparing plain strings
                if case .bonjour(let record) = result.metadata,
                   record["id"] == self.localMachineID {
                    continue
                }
                self.sendData(data, to: result.endpoint)
            }
        }
        browser?.start(queue: .main)
        
        // Keep browser scanning alive for 3 seconds then tear down to save battery/CPU
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.browser?.cancel()
        }
    }

    private func sendData(_ data: Data, to endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.start(queue: .main)
        
        connection.send(content: data, completion: .contentProcessed({ error in
            if let error = error {
                print("Maccy Sync Engine: Send failure: \(error)")
            }
            connection.cancel()
        }))
    }
}
