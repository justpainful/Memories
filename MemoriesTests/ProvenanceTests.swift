import Testing
@testable import Memories

/// Origin detection is pure string work, which is exactly the kind of thing that should be
/// proven in milliseconds rather than by launching a simulator and looking at it.
struct ProvenanceTests {

    @Test("WhatsApp names are recognised, in both directions")
    func whatsAppNames() {
        #expect(ProvenanceReader.platform(forFilename: "IMG-20230101-WA0001.jpg") == .whatsapp)
        #expect(ProvenanceReader.platform(forFilename: "VID-20240715-WA0042.mp4") == .whatsapp)
        // A camera file that merely contains "wa" must not be swept up.
        #expect(ProvenanceReader.platform(forFilename: "IMG_1234.HEIC") == .camera)
    }

    @Test("The camera's own naming is not mistaken for a download")
    func cameraNames() {
        #expect(ProvenanceReader.platform(forFilename: "IMG_0001.JPG") == .camera)
        #expect(ProvenanceReader.platform(forFilename: "IMG_E0001.JPG") == .camera)
        #expect(ProvenanceReader.platform(forFilename: "DSC_0042.JPG") == .camera)
    }

    @Test("Other platforms are told apart")
    func otherPlatforms() {
        #expect(ProvenanceReader.platform(forFilename: "Snapchat-1234567890.jpg") == .snapchat)
        #expect(ProvenanceReader.platform(forFilename: "FB_IMG_1620000000.jpg") == .facebook)
        #expect(ProvenanceReader.platform(forFilename: "received_101010.jpeg") == .messenger)
        #expect(ProvenanceReader.platform(forFilename: "photo_2023-05-01_18-00-00.jpg") == .telegram)
        #expect(ProvenanceReader.platform(forFilename: "RPReplay_Final1620.mp4") == .screenRecording)
        #expect(ProvenanceReader.platform(forFilename: "Screenshot 2024-01-01.png") == .screenshot)
    }

    @Test("An unknown name claims nothing")
    func unknownNames() {
        #expect(ProvenanceReader.platform(forFilename: "holiday.jpg") == nil)
        #expect(ProvenanceReader.platform(forFilename: "") == nil)
    }

    @Test("A date embedded in a filename is recovered, and nonsense is rejected")
    func filenameDates() throws {
        let date = try #require(ProvenanceReader.dateFromFilename("IMG-20230101-WA0001.jpg"))
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        #expect(parts.year == 2023)
        #expect(parts.month == 1)
        #expect(parts.day == 1)

        #expect(ProvenanceReader.dateFromFilename("IMG-20239999-WA0001.jpg") == nil)  // month 99
        #expect(ProvenanceReader.dateFromFilename("IMG_1234.HEIC") == nil)            // too few digits
        #expect(ProvenanceReader.dateFromFilename("holiday.jpg") == nil)
    }
}
