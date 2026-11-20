//
//  PauseTrackingTests.swift
//  CarryTests
//

import Foundation
import Testing
@testable import Carry

/// Pausing pregnancy tracking: old saved files decode as not paused, the pause survives a
/// round trip, and it reaches the widgets through the shared snapshot.
struct PauseTrackingTests {

    /// A file saved before the pause existed (no tracking keys at all) decodes as tracking on.
    @Test func oldSavedFileDecodesAsNotPaused() throws {
        let json = """
        {"momName":"Maya","partnerName":"Leo","babyNickname":"Bean","datingMethod":"due_date",\
        "datingDate":"2026-11-01T00:00:00Z","embryoAgeDays":5,"dueDate":"2027-05-01T00:00:00Z"}
        """
        let profile = try SharedStateFile.decoder.decode(PregnancyProfile.self, from: Data(json.utf8))
        #expect(profile.trackingPaused == false)
        #expect(profile.trackingPausedAt == nil)
        #expect(profile.trackingPausedBy == nil)
    }

    /// Pausing keeps its fields through a save/load round trip; resuming clears them.
    @Test func pauseRoundTripAndResume() throws {
        var profile = PregnancyProfile(
            momName: "Maya", partnerName: "Leo", babyNickname: "Bean",
            datingMethod: .dueDate, datingDate: .now, embryoAgeDays: 5, dueDate: .now,
            trackingPaused: true, trackingPausedAt: .now, trackingPausedBy: "0A000000-0000-0000-0000-000000000001"
        )
        let data = try SharedStateFile.encoder.encode(profile)
        let loaded = try SharedStateFile.decoder.decode(PregnancyProfile.self, from: data)
        #expect(loaded.trackingPaused == true)
        #expect(loaded.trackingPausedAt != nil)
        #expect(loaded.trackingPausedBy == "0A000000-0000-0000-0000-000000000001")

        profile.trackingPaused = false
        profile.trackingPausedAt = nil
        profile.trackingPausedBy = nil
        let resumed = try SharedStateFile.decoder.decode(PregnancyProfile.self, from: SharedStateFile.encoder.encode(profile))
        #expect(resumed.trackingPaused == false)
        #expect(resumed.trackingPausedAt == nil)
        #expect(resumed.trackingPausedBy == nil)
    }

    /// The widget reads the shared file: a paused profile lands there with its flag intact.
    @Test func sharedSnapshotCarriesPauseToWidgets() throws {
        let json = """
        {"profile":{"momName":"Maya","partnerName":"","babyNickname":"","datingMethod":"due_date",\
        "datingDate":"2026-11-01T00:00:00Z","embryoAgeDays":5,"dueDate":"2027-05-01T00:00:00Z",\
        "trackingPaused":true},"onboardingComplete":true,"medications":[],"doseLogs":[]}
        """
        let snapshot = try SharedStateFile.decoder.decode(SharedSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.profile?.trackingPaused == true)
    }

    /// The server row decodes with and without the pause columns (older rows have none).
    @Test func remotePregnancyRowPauseFields() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let base = """
        {"id":"0A000000-0000-0000-0000-000000000010","created_by":"0A000000-0000-0000-0000-000000000011",\
        "creator_role":"mom","mom_name":"Maya","dating_method":"due_date",\
        "dating_date":"2026-11-01","due_date":"2027-05-01","invite_code":"AB12"}
        """
        let old = try decoder.decode(RemotePregnancyRow.self, from: Data(base.utf8))
        #expect(old.tracking_paused == nil)

        var pausedRow = base
        pausedRow.removeLast()
        pausedRow += """
        ,"tracking_paused":true,"tracking_paused_at":"2026-11-20T08:30:00Z",\
        "tracking_paused_by":"0A000000-0000-0000-0000-000000000011"}
        """
        let paused = try decoder.decode(RemotePregnancyRow.self, from: Data(pausedRow.utf8))
        #expect(paused.tracking_paused == true)
        #expect(paused.tracking_paused_at != nil)
        #expect(paused.tracking_paused_by?.uuidString == "0A000000-0000-0000-0000-000000000011")
    }
}
