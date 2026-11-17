// Throwaway: proves CI fails on a failing test (issue #9). Never merge.
import Testing

@Suite("CI red check")
struct CIRedCheckTests {
    @Test func failsOnPurpose() {
        #expect(1 == 2, "Deliberate failure to check CI turns red")
    }
}
