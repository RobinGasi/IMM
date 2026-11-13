import Testing

@testable import IMMDesign

@Suite struct LayoutTests {
    @Test func clampValuesAtDesignWidths() {
        #expect(abs(IMMLayout.sidebarWidth(windowWidth: 1440) - 252) < 1e-9)
        #expect(abs(IMMLayout.sidebarWidth(windowWidth: 1024) - 212) < 1e-9)
        #expect(abs(IMMLayout.contentPadding(windowWidth: 1440) - 31.68) < 1e-9)
        #expect(abs(IMMLayout.contentPadding(windowWidth: 800) - 20) < 1e-9)
        #expect(abs(IMMLayout.heroFontSize(windowWidth: 1440) - 32) < 1e-9)
        #expect(abs(IMMLayout.heroFontSize(windowWidth: 1024) - 26) < 1e-9)
        #expect(abs(IMMLayout.inspectorWidth(windowWidth: 1440) - 360) < 1e-9)
        #expect(abs(IMMLayout.inspectorWidth(windowWidth: 1024) - 300) < 1e-9)
        #expect(abs(IMMLayout.inspectorWidth(windowWidth: 1200) - 300) < 1e-9)
        #expect(abs(IMMLayout.inspectorWidth(windowWidth: 1300) - 325) < 1e-9)
    }

    @Test func motionDefaultsMatchHandoff() {
        #expect(Motion.defaultDuration(.riseIn) == 0.24)
        #expect(Motion.defaultDuration(.popIn) == 0.16)
        #expect(Motion.defaultDuration(.sheetDown) == 0.26)
        #expect(Motion.defaultDuration(.slideInRight) == 0.24)
        #expect(Motion.Kind.allCases.count == 8)
    }
}
