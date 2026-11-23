import Metal
import WeatherCore
import XCTest
@testable import WeatherWallpaper

final class CloudHistoryTests: XCTestCase {
    @MainActor
    func testRetiredHistoryReservationSurvivesUntilGPUCompletion() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        let budget = CloudHistoryBudget(limit: 2*1024*1024)
        let history = try XCTUnwrap(CloudFrameHistory(resources: resources,budget: budget))
        let u = ShaderUniforms(scene: .preview(kind: .cloudy,time: .day),size: .init(width: 512,height: 320),seconds: 19,wind: 0)
        XCTAssertTrue(history.prepare(u,width: 256,height: 160))
        let bytes = history.allocatedBytes
        let command = try XCTUnwrap(resources.queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = history.color
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
        encoder.endEncoding(); pass.colorAttachments[0].texture = nil
        history.trackCompletion(of: command)
        history.invalidate()
        XCTAssertEqual(history.allocatedBytes,0)
        XCTAssertEqual(budget.allocated,bytes,"In-flight textures must still occupy the shared budget")
        let done = expectation(description: "GPU finished retired history")
        command.addCompletedHandler { _ in done.fulfill() }
        command.commit()
        await fulfillment(of: [done],timeout: 10)
        XCTAssertEqual(command.status,.completed)
        XCTAssertLessThanOrEqual(budget.allocated,budget.limit)
    }

    func testBudgetEnforcesGlobalBoundAndLeaseLifetime() {
        let budget = CloudHistoryBudget(limit: 100)
        XCTAssertTrue(budget.reserve(80)); XCTAssertFalse(budget.reserve(21))
        var lease: CloudHistoryLease? = CloudHistoryLease(budget: budget,bytes: 80)
        do {
            let inFlight = lease
            lease = nil
            XCTAssertEqual(budget.allocated,80,"Retired/in-flight work must retain its reservation")
            withExtendedLifetime(inFlight) { XCTAssertFalse(budget.reserve(21)) }
        }
        XCTAssertEqual(budget.allocated,0)
        XCTAssertTrue(budget.reserve(100)); budget.release(100)
    }

    @MainActor
    func testHistoryRejectsChangesGapsClockReversalAndFeedback() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        let budget = CloudHistoryBudget(limit: 2*1024*1024)
        let history = try XCTUnwrap(CloudFrameHistory(resources: resources,budget: budget))
        let scene = SceneState.preview(kind: .cloudy,time: .day)
        let size = CGSize(width: 512,height: 320)
        let first = ShaderUniforms(scene: scene,size: size,seconds: 19,wind: 4)
        let next = ShaderUniforms(scene: scene,size: size,seconds: 19+1/30,wind: 4.01)
        XCTAssertTrue(history.prepare(first,width: 256,height: 160))
        XCTAssertFalse(history.canReuse(next))
        history.recordFresh(first)
        XCTAssertTrue(history.canReuse(next))
        history.recordReuse()
        XCTAssertFalse(history.canReuse(next),"A reconstructed image must never become its own history")
        history.recordFresh(first)
        var variants: [ShaderUniforms] = []
        var changed = next; changed.atmosphere.z += 0.01; variants.append(changed)
        changed = next; changed.morphology.x += 0.01; variants.append(changed)
        changed = next; changed.cloudStructure.z += 0.01; variants.append(changed)
        changed = next; changed.clouds.y += 0.01; variants.append(changed)
        changed = next; changed.celestial.x += 0.01; variants.append(changed)
        changed = next; changed.moon.x += 0.01; variants.append(changed)
        changed = next; changed.lightning.z = 0.5; variants.append(changed)
        changed = next; changed.weather.x = 0.1; variants.append(changed)
        changed = next; changed.clouds.w = 0.4; variants.append(changed)
        changed = next; changed.rendering.y = 4; variants.append(changed)
        changed = next; changed.rendering.z = 2; variants.append(changed)
        changed = next; changed.convection.x = 0.5; variants.append(changed)
        changed = next; changed.viewport.z += 1; variants.append(changed)
        changed = next; changed.viewport.z = 18; variants.append(changed)
        changed = next; changed.options.z += 100; variants.append(changed)
        for value in variants { XCTAssertFalse(history.canReuse(value)) }
        var sunset = first; sunset.atmosphere.x = 0.0201
        history.recordFresh(sunset)
        var moonlit = next; moonlit.atmosphere.x = 0.0199
        XCTAssertFalse(history.canReuse(moonlit),"Tiny daylight changes must not reuse the wrong sun/moon lighting source")
        history.invalidate()
        XCTAssertEqual(budget.allocated,0); XCTAssertEqual(history.allocatedBytes,0)
        XCTAssertFalse(history.canReuse(next))
    }

    @MainActor
    func testHistoryClockSplitAndAllocationFallback() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        let scene = SceneState.preview(kind: .cloudy,time: .day)
        let size = CGSize(width: 512,height: 320)
        let a = ShaderUniforms(scene: scene,size: size,seconds: 3599.99,wind: 5)
        let b = ShaderUniforms(scene: scene,size: size,seconds: 3600.02,wind: 5.01)
        let budget = CloudHistoryBudget(limit: 600_000)
        let first = try XCTUnwrap(CloudFrameHistory(resources: resources,budget: budget))
        let second = try XCTUnwrap(CloudFrameHistory(resources: resources,budget: budget))
        XCTAssertTrue(first.prepare(a,width: 256,height: 160))
        first.recordFresh(a)
        XCTAssertTrue(first.canReuse(b))
        XCTAssertFalse(second.prepare(a,width: 256,height: 160),"Additional displays must fall back instead of exceeding the cap")
        first.invalidate()
        XCTAssertTrue(second.prepare(a,width: 256,height: 160))
        XCTAssertLessThanOrEqual(budget.allocated,budget.limit)
        second.invalidate()
        XCTAssertFalse(first.prepare(a,width: 4096,height: 2160))
        XCTAssertEqual(budget.allocated,0)
        let tiny = try XCTUnwrap(CloudFrameHistory(resources: resources,budget: CloudHistoryBudget(limit: 1)))
        XCTAssertFalse(tiny.prepare(a,width: 256,height: 160)); XCTAssertEqual(tiny.allocatedBytes,0)
    }
}
