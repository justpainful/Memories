import Foundation
import Testing
@testable import Memories

struct PhotoLibraryPersistenceTests {
    @Test
    func profileAndThemeRepositoriesRoundTripMetadata() async throws {
        let container = try MemoryPersistenceStack.makeContainer(inMemory: true)
        let memoryRepository = MemoryRepository(container: container)
        let profileRepository = ProfileRepository(memoryRepository: memoryRepository)
        let themeRepository = ThemeRepository(memoryRepository: memoryRepository)

        var metadata = MemoryProfileMetadata.default
        metadata.displayName = "Alex"
        metadata.memoriesSeenCount = 7
        metadata.avatarLocalIdentifier = "avatar-1"
        metadata.fallbackInitials = "A"

        try await profileRepository.save(metadata)
        try await themeRepository.saveTheme(.reflectiveDark)

        let restoredProfile = try await profileRepository.load()
        let restoredTheme = try await themeRepository.loadTheme()

        #expect(restoredProfile.displayName == "Alex")
        #expect(restoredProfile.memoriesSeenCount == 7)
        #expect(restoredProfile.avatarLocalIdentifier == "avatar-1")
        #expect(restoredTheme == .reflectiveDark)
    }
}
