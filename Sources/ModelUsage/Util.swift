import Foundation
import UserNotifications

// Alertes système (80 % / 95 % / épuisement avant reset).
enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func send(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

func mlog(_ s: String) {
    let line = "\(Date()) \(s)\n"
    let url = URL(fileURLWithPath: "/tmp/modelusage.log")
    if let fh = try? FileHandle(forWritingTo: url) {
        fh.seekToEndOfFile(); fh.write(Data(line.utf8)); try? fh.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

// Tout process externe passe par ici : un binaire qui ne rend pas la main
// (prompt TCC, lsof coincé) est tué au timeout au lieu de geler l'app.
enum Proc {
    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 10) -> (status: Int32, output: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }

        let sem = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in sem.signal() }
        var data = Data()
        let reader = DispatchQueue(label: "proc.read")
        reader.async { data = pipe.fileHandleForReading.readDataToEndOfFile() }

        if sem.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            mlog("TIMEOUT \(path) \(args.first ?? "")")
            return nil
        }
        reader.sync {}
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
