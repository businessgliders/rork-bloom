import Foundation

/// The App Group shared by Bloom and its widget extension.
nonisolated enum AppGroup {
    static let id = "group.app.businessgliders.bloom"
    /// Darwin notification posted whenever another process changed the shared state file.
    static let stateChangedNotification = "app.businessgliders.bloom.state-changed"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    private static let viewerKey = "bloom.viewerID"

    /// The signed-in user's id (shared with the widget so it can tell whose activity it shows).
    static var viewerID: String? {
        UserDefaults(suiteName: id)?.string(forKey: viewerKey)
    }

    static func setViewerID(_ value: String?) {
        let defaults = UserDefaults(suiteName: id)
        if let value { defaults?.set(value, forKey: viewerKey) } else { defaults?.removeObject(forKey: viewerKey) }
    }

    static func postStateChanged() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(stateChangedNotification as CFString),
            nil, nil, true
        )
    }
}

/// The subset of Bloom's saved state that widgets and the Live Activity need.
/// Decoding ignores everything else in the file (milestones, photos, settings).
nonisolated struct SharedSnapshot: Decodable {
    var profile: PregnancyProfile?
    var onboardingComplete: Bool
    var medications: [Medication]
    var doseLogs: [DoseLog]

    static let empty = SharedSnapshot(profile: nil, onboardingComplete: false, medications: [], doseLogs: [])

    init(profile: PregnancyProfile?, onboardingComplete: Bool, medications: [Medication], doseLogs: [DoseLog]) {
        self.profile = profile
        self.onboardingComplete = onboardingComplete
        self.medications = medications
        self.doseLogs = doseLogs
    }

    private enum CodingKeys: String, CodingKey { case profile, onboardingComplete, medications, doseLogs, liveMedicationIDs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = try c.decodeIfPresent(PregnancyProfile.self, forKey: .profile)
        onboardingComplete = try c.decodeIfPresent(Bool.self, forKey: .onboardingComplete) ?? false
        let all = try c.decodeIfPresent([Medication].self, forKey: .medications) ?? []
        // When shared, widgets only show the meds this person follows with a Live Activity.
        if let live = try? c.decodeIfPresent([UUID].self, forKey: .liveMedicationIDs) {
            let ids = Set(live)
            medications = all.filter { ids.contains($0.id) }
        } else {
            medications = all
        }
        doseLogs = try c.decodeIfPresent([DoseLog].self, forKey: .doseLogs) ?? []
    }

    func instances(on day: Date) -> [DoseInstance] {
        MedsEngine.instances(on: day, medications: medications, logs: doseLogs)
    }

    func carryOver(into day: Date) -> [DoseInstance] {
        MedsEngine.carryOver(into: day, medications: medications, logs: doseLogs)
    }
}

/// Bloom's single state file, stored in the App Group so the widget can read it.
/// All access is coordinated so the app and the extension never see half-written data.
nonisolated enum SharedStateFile {
    static let filename = "bloom-state.json"

    /// Readable after the first unlock, so the widget and Live Activity keep working on a locked phone.
    static let protection: Data.WritingOptions = .completeFileProtectionUntilFirstUserAuthentication

    static var url: URL {
        let dir = AppGroup.containerURL ?? legacyDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(filename)
    }

    /// Where stages 1–2 kept the file (app-private Application Support).
    static var legacyDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static var legacyURL: URL { legacyDirectory.appendingPathComponent(filename) }

    /// Moves the old app-private file into the App Group once.
    static func migrateLegacyFileIfNeeded() {
        let fm = FileManager.default
        let target = url
        guard target != legacyURL,
              fm.fileExists(atPath: legacyURL.path),
              !fm.fileExists(atPath: target.path),
              let data = try? Data(contentsOf: legacyURL) else { return }
        write(data)
        if fm.fileExists(atPath: target.path) {
            try? fm.removeItem(at: legacyURL)
        }
    }

    static func read() -> Data? {
        var result: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { readURL in
            result = try? Data(contentsOf: readURL)
        }
        return result
    }

    static func write(_ data: Data) {
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { writeURL in
            try? data.write(to: writeURL, options: [.atomic, protection])
        }
    }

    static func delete() {
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &error) { deleteURL in
            try? FileManager.default.removeItem(at: deleteURL)
        }
    }

    static func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    static func snapshot() -> SharedSnapshot {
        guard let data = read(), let snapshot = try? decoder.decode(SharedSnapshot.self, from: data) else { return .empty }
        return snapshot
    }

    /// Marks a dose taken by editing only `doseLogs`, keeping every other key untouched.
    /// Used when an intent runs outside the app process.
    @discardableResult
    static func markTaken(medicationID: UUID, scheduledAt: Date, takenAt: Date) -> Bool {
        var changed = false
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &error) { fileURL in
            guard let data = try? Data(contentsOf: fileURL),
                  var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            let snapshot = (try? decoder.decode(SharedSnapshot.self, from: data)) ?? .empty
            guard let instance = snapshot.instances(on: scheduledAt).first(where: {
                $0.medication.id == medicationID && abs($0.scheduledAt.timeIntervalSince(scheduledAt)) < 30
            }), instance.isPending else { return }

            // Keep the full log list (the snapshot may be filtered by meds, never by logs).
            var logs = snapshot.doseLogs
            let loggedBy = AppGroup.viewerID.flatMap(UUID.init(uuidString:))
            logs.append(DoseLog(medicationID: medicationID, scheduledAt: instance.scheduledAt, status: .taken,
                                takenAt: takenAt, loggedAt: .now, loggedBy: loggedBy))
            guard let logsData = try? encoder.encode(logs),
                  let logsObject = try? JSONSerialization.jsonObject(with: logsData) else { return }
            root["doseLogs"] = logsObject

            // When shared, queue the dose for upload; the app flushes it on next launch/wake.
            if let account = root["account"] as? [String: Any], account["pregnancyID"] != nil {
                let seq = ((root["opSeq"] as? Int) ?? 0) + 1
                var ops = (root["pendingOps"] as? [[String: Any]]) ?? []
                // Same format as SyncOp.doseKey: "medUUID|unixSeconds".
                let key = "\(medicationID.uuidString)|\(Int(instance.scheduledAt.timeIntervalSince1970.rounded()))"
                ops.removeAll { ($0["kind"] as? String) == "dose" && ($0["key"] as? String) == key }
                ops.append(["kind": "dose", "key": key, "seq": seq])
                root["pendingOps"] = ops
                root["opSeq"] = seq
            }
            guard let newData = try? JSONSerialization.data(withJSONObject: root) else { return }
            do {
                try newData.write(to: fileURL, options: [.atomic, protection])
                changed = true
            } catch {}
        }
        return changed
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
