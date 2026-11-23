import AppKit
import ImageIO
import Metal
import UniformTypeIdentifiers
import WeatherCore
import XCTest
@testable import WeatherWallpaper

final class RenderingTests: XCTestCase {
    @MainActor
    func testOptionalMoonlitHazeReview() async throws {
        guard let path = ProcessInfo.processInfo.environment["WEATHER_WALLPAPER_MOONLIT_HAZE_REVIEW"] else {
            throw XCTSkip("Set WEATHER_WALLPAPER_MOONLIT_HAZE_REVIEW for haze captures, motion and GPU diagnostics")
        }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        let current = SceneCompositor(resources: resources,useLightCache: false,useCloudHistory: false)
        var old: SceneCompositor?
        if let baseline = ProcessInfo.processInfo.environment["WEATHER_WALLPAPER_HAZE_BASELINE"] {
            let source = try String(contentsOf: URL(fileURLWithPath: baseline).appendingPathComponent("before-Atmosphere.metal"),encoding: .utf8)
            let library = try await resources.device.makeLibrary(source: source,options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "solarAtmosphereVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "atmosphereComposite")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
            old = SceneCompositor(resources: resources,atmospherePipeline: try await resources.device.makeRenderPipelineState(descriptor: descriptor),
                                  useLightCache: false,useCloudHistory: false)
        }
        var configurations: [(String,NotchHazeConfiguration)] = []
        var configuration = NotchHazeConfiguration(); configuration.enabled = false
        configurations.append(("off",configuration)); configuration.enabled = true
        configuration.layout = .compact; configurations.append(("compact",configuration))
        configuration.layout = .expanded; configurations.append(("expanded",configuration))
        var report: [[String: Any]] = []
        func stats(_ values: [Double]) -> [String: Double] {
            let sorted = values.sorted()
            return ["mean_ms":values.reduce(0,+)/Double(values.count),"median_ms":sorted[sorted.count/2],
                    "p95_ms":sorted[min(sorted.count-1,Int(Double(sorted.count)*0.95))]]
        }
        for efficient in [false,true] {
            var policy = RenderPolicy(); policy.permitsMeteors = false; policy.permitsLightning = false
            if efficient { policy.cloudSteps = 20; policy.cloudDownsample = 4; policy.bloomDownsample = 8; policy.particleScale = 0.5 }
            width = 2000; height = 1445
            for kind: WeatherKind in [.clear,.cloudy,.rain] {
                let scene = SceneState.preview(kind: kind,time: .night)
                for (name,configuration) in configurations {
                    try writePNG(try render(scene,seconds: 19,resources: resources,policy: policy,baseline: current,
                        historicalUniforms: false,hazeConfiguration: configuration),
                        to: directory.appendingPathComponent("\(kind.rawValue)-\(name)-\(efficient).png"))
                }
                if let old {
                    try writePNG(try render(scene,seconds: 19,resources: resources,policy: policy,baseline: old,
                        historicalUniforms: false,hazeConfiguration: NotchHazeConfiguration()),
                        to: directory.appendingPathComponent("\(kind.rawValue)-old-flat-\(efficient).png"))
                }
            }
            width = efficient ? 1600 : 2560; height = efficient ? 1000 : 1600
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,width: width,height: height,mipmapped: false)
            descriptor.storageMode = .private; descriptor.usage = .renderTarget
            let target = try XCTUnwrap(resources.device.makeTexture(descriptor: descriptor))
            for kind: WeatherKind in [.clear,.rain] {
                let scene = SceneState.preview(kind: kind,time: .night)
                var timings: [String: [Double]] = [:]
                let names = configurations.map(\.0)+(old == nil ? [] : ["old-flat"])
                for frame in 0..<72 {
                    let seconds = 19+Double(frame)/30
                    let uniforms = ShaderUniforms(scene: scene,size: CGSize(width: width,height: height),seconds: seconds,
                        wind: seconds*Double(scene.wind*scene.windDirection),policy: policy)
                    let ordered = (0..<names.count).map { names[($0+frame)%names.count] }
                    for name in frame%2 == 0 ? ordered : Array(ordered.reversed()) {
                        let configuration = configurations.first { $0.0 == name }?.1 ?? NotchHazeConfiguration()
                        let result = try benchmarkFrame(uniforms,widget: .disabled,resources: resources,
                            compositor: name == "old-flat" ? XCTUnwrap(old) : current,target: target,
                            haze: MoonlitHazeUniforms(configuration: configuration,seconds: seconds))
                        if frame >= 18 { timings[name,default: []].append(result.gpu*1000) }
                    }
                }
                report.append(["efficient":efficient,"scene":kind.rawValue,"width":width,"height":height,
                    "gpu":timings.mapValues(stats),"new_transient_bytes":current.allocatedTransientBytes,
                    "old_transient_bytes":old?.allocatedTransientBytes ?? current.allocatedTransientBytes])
                if let old { XCTAssertEqual(old.allocatedTransientBytes,current.allocatedTransientBytes) }
            }
            if ProcessInfo.processInfo.environment["WEATHER_WALLPAPER_REVIEW_STILLS_ONLY"] != "1" {
                width = 1280; height = 800
                let fps = efficient ? 15 : 30
                let movie = try ReviewVideoWriter(url: directory.appendingPathComponent("real-time-layout-transition-\(fps)fps-\(UUID().uuidString.prefix(8)).mp4"),
                    width: width,height: height,fps: fps)
                var transition = NotchHazeTransition()
                let scene = SceneState.preview(kind: .clear,time: .night)
                for frame in 0..<(fps*10) {
                    let seconds = 19+Double(frame)/Double(fps)
                    var configuration = NotchHazeConfiguration(); configuration.layout = frame < fps*3 || frame >= fps*7 ? .compact : .expanded
                    let state = transition.value(configuration: configuration,at: seconds,animated: true)
                    try await movie.append(render(scene,seconds: Float(seconds),resources: resources,policy: policy,
                        baseline: current,historicalUniforms: false,
                        hazeOverride: MoonlitHazeUniforms(strength: state.x,expansion: state.y,seconds: seconds)),frame: frame)
                }
                try await movie.finish()
            }
        }
        try JSONSerialization.data(withJSONObject: ["device":resources.device.name,"timings":report,
            "notes":"Same weather/quality and phase, rotated/reversed order, 18 warmups + 54 measured frames. Reused output, no screenshot readback in GPU timings; not a sustained-energy measurement. Compact/Expanded are manual states, with a real-time transition clip."],
            options: [.prettyPrinted,.sortedKeys]).write(to: directory.appendingPathComponent("review.json"))
    }

    @MainActor
    func testMoonlitHazeFieldsAreSlowSeamlessAndSharedByBothRenderers() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try ["Sky.metal","Atmosphere.metal"].map {
            try String(contentsOf: root.appendingPathComponent("Sources/WeatherWallpaper/Resources/"+$0),encoding: .utf8)
        }.joined(separator: "\n")
        let probe = """
        kernel void hazeProbe(device float4 *out [[buffer(0)]],constant AtmosphereUniforms &u [[buffer(1)]],
            constant MoonlitHazeUniformsV2 &haze [[buffer(2)]],constant Uniforms &legacy [[buffer(3)]],
            constant MoonlitHazeUniformsLegacy &legacyHaze [[buffer(4)]],texture3d<float> noise [[texture(0)]],
            uint id [[thread_position_in_grid]]) {
            float2 uv = float2((float(id%384)+0.5)/384,(float(id/384)+0.5)/128*0.27);
            out[id*2] = float4(moonlitNotchHazeV2(uv,u,haze,noise),1);
            out[id*2+1] = float4(moonlitNotchHazeLegacy(uv,legacy,legacyHaze,noise),1);
        }
        """
        let library = try await resources.device.makeLibrary(source: source+"\n"+probe,options: nil)
        let pipeline = try await resources.device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "hazeProbe")))
        let count = 384*128
        let output = try XCTUnwrap(resources.device.makeBuffer(length: count*2*MemoryLayout<SIMD4<Float>>.stride,options: .storageModeShared))
        var uniforms = ShaderUniforms(scene: .preview(kind: .clear,time: .night),size: CGSize(width: 1600,height: 1000),seconds: 0,wind: 0)
        func sample(_ seconds: Double) throws -> [SIMD4<Float>] {
            var haze = MoonlitHazeUniforms(configuration: NotchHazeConfiguration(),seconds: seconds)
            let command = try XCTUnwrap(resources.queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
            encoder.setComputePipelineState(pipeline); encoder.setBuffer(output,offset: 0,index: 0)
            for index in [1,3] { encoder.setBytes(&uniforms,length: MemoryLayout<ShaderUniforms>.stride,index: index) }
            for index in [2,4] { encoder.setBytes(&haze,length: MemoryLayout<MoonlitHazeUniforms>.stride,index: index) }
            encoder.setTexture(resources.noiseVolume,index: 0)
            encoder.dispatchThreads(MTLSize(width: count,height: 1,depth: 1),threadsPerThreadgroup: MTLSize(width: 64,height: 1,depth: 1))
            encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
            XCTAssertEqual(command.status,.completed)
            return Array(UnsafeBufferPointer(start: output.contents().assumingMemoryBound(to: SIMD4<Float>.self),count: count*2))
        }
        func maximumDifference(_ a: [SIMD4<Float>],_ b: [SIMD4<Float>]) -> Float {
            zip(a,b).reduce(Float(0)) { result,pair in
                let delta = pair.0-pair.1
                return max(result,max(abs(delta.x),max(abs(delta.y),abs(delta.z))))
            }
        }
        let initial = try sample(0), frame = try sample(1.0/30), minute = try sample(60)
        let frameDelta = maximumDifference(initial,frame), minuteDelta = maximumDifference(initial,minute)
        XCTAssertLessThan(frameDelta,0.00002,"No frame-to-frame shimmer")
        XCTAssertGreaterThan(minuteDelta,0.000001,"Mist should move slowly, not remain a static gradient")
        XCTAssertLessThan(minuteDelta,0.004,"One minute should not substantially reshape the lighting")
        for rate in [0.000080,0.000027,-0.000043,0.000061] {
            let boundary = 1/abs(rate)
            XCTAssertLessThan(maximumDifference(try sample(boundary-0.01),try sample(boundary+0.01)),0.00002,
                              "Periodic translations must not jump when their bounded clocks wrap")
        }
        var mismatch: Float = 0, maximumSlope: Float = 0, total = 0.0, asymmetry = 0.0
        for i in 0..<count {
            let value = initial[i*2], legacy = initial[i*2+1]
            for channel in 0..<3 {
                XCTAssertTrue(value[channel].isFinite); XCTAssertGreaterThanOrEqual(value[channel],0)
                mismatch = max(mismatch,abs(value[channel]-legacy[channel])); total += Double(value[channel])
                if i%384 > 0 { maximumSlope = max(maximumSlope,abs(value[channel]-initial[(i-1)*2][channel])) }
                if i >= 384 { maximumSlope = max(maximumSlope,abs(value[channel]-initial[(i-384)*2][channel])) }
                let mirror = (i/384)*384+(383-i%384)
                asymmetry += Double(abs(value[channel]-initial[mirror*2][channel]))
            }
        }
        XCTAssertLessThan(mismatch,0.000001)
        XCTAssertLessThan(maximumSlope,0.002,"No abrupt spatial edges")
        XCTAssertLessThan(total/Double(count*3)*0.27,0.001,"Do not noticeably brighten the whole screen")
        XCTAssertGreaterThan(asymmetry/Double(count*3),0.00001,"Overlapping warped fields should not be a symmetric flat halo")
    }

    @MainActor
    func testMoonlitNotchHazeIsBoundedAndLeavesDaytimeUnchanged() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        width = 1000; height = 700
        var policy = RenderPolicy(); policy.permitsMeteors = false; policy.permitsLightning = false; policy.bloom = false
        for legacy in [false,true] {
            policy.volumetricClouds = !legacy
            let night = SceneState.preview(kind: .clear,time: .night)
            let original = try render(night,resources: resources,policy: policy)
            let bytes = compositor?.allocatedTransientBytes
            let glowing = try render(night,resources: resources,policy: policy,nightNotchGlow: true)
            XCTAssertEqual(bytes,compositor?.allocatedTransientBytes,"The halo must not allocate any new render targets")
            func lift(_ x: Int,_ y: Int) -> Double {
                let index = (y*width+x)*4
                return (0..<3).map { Double(Int(glowing[index+$0])-Int(original[index+$0])) }.reduce(0,+)/3
            }
            XCTAssertGreaterThan(lift(width/2,8),15,"Lift the wallpaper immediately around the notch")
            XCTAssertGreaterThan(lift(Int(Double(width)*0.35),20),3,"The halo should extend beyond the notch app itself")
            var outsideDifference = 0
            for y in 0..<height {
                for x in 0..<width where Double(y)/Double(height) >= 0.25 || x < width/25 || x > width*24/25 {
                    let index = (y*width+x)*4
                    for channel in 0..<4 {
                        outsideDifference = max(outsideDifference,abs(Int(original[index+channel])-Int(glowing[index+channel])))
                    }
                }
            }
            XCTAssertEqual(outsideDifference,0,"Keep the rest of the night sky unchanged")
            for time: PreviewTime in [.day,.dawn,.dusk] {
                let scene = SceneState.preview(kind: .clear,time: time)
                XCTAssertEqual(try render(scene,resources: resources,policy: policy),
                    try render(scene,resources: resources,policy: policy,nightNotchGlow: true),"Do not tint daytime or twilight")
            }
        }
        policy.volumetricClouds = true; policy.animated = false
        for kind: WeatherKind in [.cloudy,.fog,.rain] {
            let scene = SceneState.preview(kind: kind,time: .night)
            XCTAssertNotEqual(try render(scene,resources: resources,policy: policy),
                try render(scene,resources: resources,policy: policy,nightNotchGlow: true),"Night readability survives weather and paused animation")
        }
        if let path = ProcessInfo.processInfo.environment["WEATHER_WALLPAPER_NOTCH_REVIEW"] {
            width = 2000; height = 1445
            policy.animated = true
            let scene = SceneState.preview(kind: .clear,time: .night)
            let directory = URL(fileURLWithPath: path)
            try writePNG(try render(scene,resources: resources,policy: policy),to: directory.appendingPathComponent("night-before.png"))
            try writePNG(try render(scene,resources: resources,policy: policy,nightNotchGlow: true),to: directory.appendingPathComponent("night-notch-glow.png"))
        }
    }

    @MainActor
    func testOptionalQualityPreservingOptimizationReview() async throws {
        guard let path = ProcessInfo.processInfo.environment["WEATHER_WALLPAPER_OPTIMIZATION_REVIEW"] else {
            throw XCTSkip("Set WEATHER_WALLPAPER_OPTIMIZATION_REVIEW for paired quality/performance diagnostics")
        }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        let variants = try await optimizationVariants(resources: resources,individual: true)
        var areas: [WidgetRainArea] = []
        for index in 0..<24 {
            var area = WidgetRainArea(); area.enabled = true
            area.x = 0.04+Float(index%6)*0.155; area.y = 0.08+Float(index/6)*0.22
            area.width = 0.14; area.height = 0.18; area.cornerRadius = 24
            areas.append(area)
        }
        let fixtures: [(String,SceneState,Int,[String])] = [
            ("clear",.preview(kind: .clear,time: .day),0,["before","solar","after"]),
            ("partly",.preview(kind: .partlyCloudy,time: .day),0,["before","solar","after"]),
            ("towers",.preview(kind: .partlyCloudy,time: .day,cloudDevelopment: .toweringCumulus),0,["before","solar","after"]),
            ("night",.preview(kind: .clear,time: .night),0,["before","after"]),
            ("rain-0",.preview(kind: .rain,time: .day),0,["before","quads","collisions","after"]),
            ("rain-5",.preview(kind: .rain,time: .day),5,["before","quads","collisions","after"]),
            ("rain-24",.preview(kind: .rain,time: .day),24,["before","quads","collisions","after"]),
            ("sleet",.preview(kind: .sleet,time: .day),24,["before","quads","collisions","after"]),
            ("snow",.preview(kind: .snow,time: .night),0,["before","quads","after"]),
            ("storm",.preview(kind: .thunderstorm,time: .day),24,["before","quads","collisions","after"])]
        func stats(_ values: [Double]) -> [String: Double] {
            let sorted = values.sorted()
            return ["mean_ms":values.reduce(0,+)/Double(values.count),"median_ms":sorted[sorted.count/2],
                    "p95_ms":sorted[min(sorted.count-1,Int(Double(sorted.count)*0.95))]]
        }
        var report: [[String: Any]] = [], cacheReport: [[String: Any]] = []
        for efficient in [false,true] {
            width = efficient ? 1600 : 2560; height = efficient ? 1000 : 1600
            var policy = RenderPolicy(); policy.permitsMeteors = false
            if efficient { policy.cloudSteps = 20; policy.cloudDownsample = 4; policy.bloomDownsample = 8; policy.particleScale = 0.5 }
            for (name,scene,count,names) in fixtures {
                policy.widgetRainAreas = Array(areas.prefix(count))
                let before = try render(scene,seconds: 17.2,resources: resources,policy: policy,baseline: variants["before"],historicalUniforms: false)
                try writePNG(before,to: directory.appendingPathComponent("before-\(name)-\(efficient).png"))
                var images: [[String: Any]] = []
                for variant in names where variant != "before" {
                    let image = try render(scene,seconds: 17.2,resources: resources,policy: policy,baseline: variants[variant],historicalUniforms: false)
                    let errors = imageCodeErrors(before,image)
                    XCTAssertLessThanOrEqual(errors.maximum,1); XCTAssertLessThan(errors.mean,0.002)
                    images.append(["variant":variant,"mean_abs_code":errors.mean,"maximum_abs_code":errors.maximum])
                    if variant == "after" { try writePNG(image,to: directory.appendingPathComponent("after-\(name)-\(efficient).png")) }
                }
                var timings: [String: [Double]] = [:], encodeTimes: [String: [Double]] = [:]
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,width: width,height: height,mipmapped: false)
                descriptor.storageMode = .private; descriptor.usage = .renderTarget
                let target = try XCTUnwrap(resources.device.makeTexture(descriptor: descriptor))
                let widget = WidgetRainLayoutUniforms(areas: policy.widgetRainAreas,screenHeight: Float(height),guide: false,animated: true)
                for frame in 0..<96 {
                    let seconds = 17+Float(frame)/30
                    let uniforms = ShaderUniforms(scene: scene,size: CGSize(width: width,height: height),seconds: Double(seconds),
                        wind: Double(seconds*scene.wind*scene.windDirection),policy: policy,
                        strike: LightningSample(origin: 0.58,seed: 41,intensity: scene.storm*0.6,reach: 0.90))
                    // Rotate and reverse draw order to reduce frequency/order bias.
                    let order = (0..<names.count).map { names[($0+frame)%names.count] }
                    for variant in frame%2 == 0 ? order : Array(order.reversed()) {
                        let times = try benchmarkFrame(uniforms,widget: widget,resources: resources,
                            compositor: XCTUnwrap(variants[variant]),target: target)
                        if frame >= 24 {
                            timings[variant,default: []].append(times.gpu*1000)
                            encodeTimes[variant,default: []].append(times.encode*1000)
                        }
                    }
                }
                let oldBytes = try XCTUnwrap(variants["before"]).allocatedTransientBytes
                let newBytes = try XCTUnwrap(variants["after"]).allocatedTransientBytes
                XCTAssertEqual(oldBytes,newBytes)
                report.append(["scene":name,"efficient":efficient,"width":width,"height":height,"areas":count,
                    "gpu":timings.mapValues(stats),"encode":encodeTimes.mapValues(stats),"image_errors":images,
                    "before_bytes":oldBytes,"after_bytes":newBytes])
            }
            if ProcessInfo.processInfo.environment["WEATHER_WALLPAPER_REVIEW_STILLS_ONLY"] != "1" {
                width = 1280; height = 800; policy.widgetRainAreas = Array(areas.prefix(5))
                let fps = efficient ? 15 : 30
                let movie = try ReviewVideoWriter(url: directory.appendingPathComponent("rain-before-after-\(efficient)-\(UUID().uuidString.prefix(8)).mp4"),
                    width: width*2,height: height,fps: fps)
                let scene = SceneState.preview(kind: .rain,time: .day)
                for frame in 0..<(fps*6) {
                    let seconds = 17+Float(frame)/Float(fps)
                    let old = try render(scene,seconds: seconds,resources: resources,policy: policy,baseline: variants["before"],historicalUniforms: false)
                    let new = try render(scene,seconds: seconds,resources: resources,policy: policy,baseline: variants["after"],historicalUniforms: false)
                    let errors = imageCodeErrors(old,new)
                    XCTAssertLessThanOrEqual(errors.maximum,1); XCTAssertLessThan(errors.mean,0.002)
                    var paired: [UInt8] = []; paired.reserveCapacity(old.count*2)
                    for row in 0..<height {
                        let range = (row*width*4)..<((row+1)*width*4)
                        paired.append(contentsOf: old[range]); paired.append(contentsOf: new[range])
                    }
                    try await movie.append(paired,frame: frame)
                }
                try await movie.finish()
            }
        }
        for count in [0,5,24] {
            let layout = Array(areas.prefix(count)), frames = 10000
            var cache = WidgetRainLayoutCache(), checksum: Float = 0
            var start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<frames {
                checksum += WidgetRainLayoutUniforms(areas: layout,screenHeight: 1000,guide: false,animated: true).vectors[0].x
            }
            let before = ProcessInfo.processInfo.systemUptime-start
            start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<frames { checksum += cache.uniforms(areas: layout,screenHeight: 1000,guide: false,animated: true).vectors[0].x }
            let after = ProcessInfo.processInfo.systemUptime-start
            XCTAssertEqual(cache.generation,1); XCTAssertEqual(checksum,Float(count*frames*2))
            cacheReport.append(["areas":count,"frames":frames,"before_ms":before*1000,"cached_ms":after*1000,"rebuilds":cache.generation])
        }
        try JSONSerialization.data(withJSONObject: ["device":resources.device.name,"timings":report,"layout_cache":cacheReport,
            "baseline":ProcessInfo.processInfo.environment["WEATHER_WALLPAPER_OPTIMIZATION_BASELINE"] ?? "Portable test-only reference",
            "notes":"Rotated/reversed variant order; 24 warmups + 72 measured frames. Same weather, quality, resolution and scene times. GPU timings reuse a target and exclude screenshot readback/allocation, but are not sustained energy results. Before/after images and clip frames are independently checked."],
            options: [.prettyPrinted,.sortedKeys]).write(to: directory.appendingPathComponent("review.json"))
    }

    @MainActor
    func testRendererOptimizationsPreserveThePreviousImages() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        let variants = try await optimizationVariants(resources: resources)
        let before = try XCTUnwrap(variants["before"]), after = try XCTUnwrap(variants["after"])
        var areas: [WidgetRainArea] = []
        for index in 0..<24 {
            var area = WidgetRainArea(); area.enabled = true
            area.x = 0.04+Float(index%6)*0.155; area.y = 0.08+Float(index/6)*0.22
            area.width = 0.14; area.height = 0.18; area.cornerRadius = index%2 == 0 ? 24 : 0
            areas.append(area)
        }
        var towered = SceneState.preview(kind: .partlyCloudy,time: .day,cloudDevelopment: .toweringCumulus)
        towered.solar.sunPosition = SIMD2(0.28,0.17)
        let scenes: [(String,SceneState)] = [
            ("clear",.preview(kind: .clear,time: .day)),("partly",.preview(kind: .partlyCloudy,time: .day)),
            ("rain",.preview(kind: .rain,time: .day)),("rain-night",.preview(kind: .rain,time: .night)),
            ("sleet",.preview(kind: .sleet,time: .day)),("snow",.preview(kind: .snow,time: .night)),
            ("storm",.preview(kind: .thunderstorm,time: .day)),("night",.preview(kind: .clear,time: .night)),
            ("fog",.preview(kind: .fog,time: .dusk)),("towers",towered)]
        for efficient in [false,true] {
            var policy = RenderPolicy(); policy.permitsMeteors = false
            if efficient { policy.cloudSteps = 20; policy.cloudDownsample = 4; policy.bloomDownsample = 8; policy.particleScale = 0.5 }
            for (index,fixture) in scenes.enumerated() {
                width = index%3 == 0 ? 600 : 960; height = index%3 == 0 ? 960 : 600
                policy.widgetRainAreas = Array(areas.prefix([0,5,24][index%3]))
                policy.showsWidgetGuide = index%3 == 2
                for seconds: Float in [7.2,3599.97,3600.03] {
                    let old = try render(fixture.1,seconds: seconds,resources: resources,policy: policy,baseline: before,historicalUniforms: false)
                    let new = try render(fixture.1,seconds: seconds,resources: resources,policy: policy,baseline: after,historicalUniforms: false)
                    let errors = imageCodeErrors(old,new)
                    XCTAssertLessThanOrEqual(errors.maximum,1,"\(fixture.0), efficient=\(efficient), t=\(seconds)")
                    XCTAssertLessThan(errors.mean,0.002,"No visible changes to particles, refraction, clouds or source occlusion")
                    XCTAssertEqual(before.allocatedTransientBytes,after.allocatedTransientBytes)
                }
            }
        }
    }

    @MainActor
    func testStarsAreLargerWithMostlyNeutralAndSubtleWarmCoolTints() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/WeatherWallpaper/Resources/Atmosphere.metal"),encoding: .utf8)
        let probe = """
        kernel void starProbe(device float4 *out [[buffer(0)]],constant AtmosphereUniforms &u [[buffer(1)]],uint id [[thread_position_in_grid]]) {
            float2 cell = float2(id%200,id/200);
            float3 h = noiseHash3(float3(cell,41));
            float2 uv = (cell+0.15+h.xy*0.7)/125/float2(u.viewport.w,1);
            float3 center = starFieldV2(uv,u);
            float3 shoulder = starFieldV2(uv+float2(0.035/125/u.viewport.w,0),u);
            out[id] = float4(center,shoulder.x/max(0.000001,center.x));
        }
        """
        let library = try await resources.device.makeLibrary(source: source+"\n"+probe,options: nil)
        let pipeline = try await resources.device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "starProbe")))
        let count = 200*125
        let output = try XCTUnwrap(resources.device.makeBuffer(length: count*MemoryLayout<SIMD4<Float>>.stride,options: .storageModeShared))
        var uniforms = ShaderUniforms(scene: .preview(kind: .clear,time: .night),size: CGSize(width: 1600,height: 1000),seconds: 7,wind: 0)
        let command = try XCTUnwrap(resources.queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline); encoder.setBuffer(output,offset: 0,index: 0)
        encoder.setBytes(&uniforms,length: MemoryLayout<ShaderUniforms>.stride,index: 1)
        encoder.dispatchThreads(MTLSize(width: count,height: 1,depth: 1),threadsPerThreadgroup: MTLSize(width: 64,height: 1,depth: 1))
        encoder.endEncoding()
        await withCheckedContinuation { continuation in command.addCompletedHandler { _ in continuation.resume() }; command.commit() }
        XCTAssertEqual(command.status,.completed)
        let values = output.contents().assumingMemoryBound(to: SIMD4<Float>.self)
        var neutral = 0, warm = 0, cool = 0, reddish = 0
        for i in 0..<count where values[i].x > 0.001 {
            let color = values[i]
            XCTAssertGreaterThan(color.w,0.26,"Larger Gaussian shoulders must not retain the old pinprick footprint")
            let ratio = color.x/color.z
            if ratio > 1.46 { reddish += 1 }
            else if ratio > 1.2 { warm += 1 }
            else if ratio < 0.85 { cool += 1 }
            else { neutral += 1 }
            XCTAssertLessThan(max(color.x,max(color.y,color.z))/min(color.x,min(color.y,color.z)),1.6)
        }
        XCTAssertGreaterThan(neutral,warm+cool+reddish)
        XCTAssertGreaterThan(warm,20); XCTAssertGreaterThan(cool,20); XCTAssertGreaterThan(reddish,10)
    }

    @MainActor
    func testRainLayersHaveVariedDepthAndRoundedTopImpacts() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/WeatherWallpaper/Resources/Sky.metal"),encoding: .utf8)
        let probe = """
        kernel void rainProbe(device float4 *out [[buffer(0)]],constant Uniforms &u [[buffer(1)]],
            constant WidgetRainLayout &layout [[buffer(2)]],uint id [[thread_position_in_grid]]) {
            RainDrop drop = rainDrop(id,u);
            out[id*2] = float4(drop.depth,drop.size.x*u.viewport.w,drop.size.y,drop.speed);
            float4 hit = rainWidgetImpact(drop,u,layout);
            out[id*2+1] = float4(hit.x,hit.y,drop.opacity,hit.w);
        }
        """
        let library = try await resources.device.makeLibrary(source: source+"\n"+probe,options: nil)
        let pipeline = try await resources.device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "rainProbe")))
        let count = 5200
        let output = try XCTUnwrap(resources.device.makeBuffer(length: count*2*MemoryLayout<SIMD4<Float>>.stride,options: .storageModeShared))
        var area = WidgetRainArea(); area.enabled = true; area.x = 0.1; area.width = 0.8; area.y = 0.4; area.cornerRadius = 100
        var lower = area; lower.y = 0.7; lower.x += 0.05; lower.width -= 0.1
        let layout = WidgetRainLayoutUniforms(areas: [lower,area],screenHeight: 1000,guide: false,animated: true)
        var uniforms = ShaderUniforms(scene: .preview(kind: .rain,time: .day),size: CGSize(width: 1600,height: 1000),seconds: 17,wind: 0)
        uniforms.weather.w = 0
        let command = try XCTUnwrap(resources.queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline); encoder.setBuffer(output,offset: 0,index: 0)
        encoder.setBytes(&uniforms,length: MemoryLayout<ShaderUniforms>.stride,index: 1)
        layout.vectors.withUnsafeBytes { encoder.setBytes($0.baseAddress!,length: $0.count,index: 2) }
        encoder.dispatchThreads(MTLSize(width: count,height: 1,depth: 1),threadsPerThreadgroup: MTLSize(width: 64,height: 1,depth: 1))
        encoder.endEncoding()
        await withCheckedContinuation { continuation in command.addCompletedHandler { _ in continuation.resume() }; command.commit() }
        XCTAssertEqual(command.status,.completed)
        let values = output.contents().assumingMemoryBound(to: SIMD4<Float>.self)
        var layerCounts = [0,0,0], speeds: [Float] = [0,0,0], widths: [Float] = [0,0,0], roundedHits = 0
        for i in 0..<count {
            let value = values[i*2], hit = values[i*2+1]
            XCTAssertTrue(value.x.isFinite && value.w.isFinite)
            let layer = i%10 < 6 ? 0 : (i%10 < 9 ? 1 : 2)
            layerCounts[layer] += 1; speeds[layer] += value.w; widths[layer] += value.y
            if hit.w > 0 {
                XCTAssertGreaterThanOrEqual(hit.x,0.1); XCTAssertLessThanOrEqual(hit.x,0.9)
                XCTAssertGreaterThanOrEqual(hit.y,0.4); XCTAssertLessThanOrEqual(hit.y,0.501)
                if hit.y > 0.401 { roundedHits += 1 }
            }
        }
        XCTAssertEqual(layerCounts,[3120,1560,520]); XCTAssertGreaterThan(roundedHits,50)
        for layer in 1...2 {
            XCTAssertGreaterThan(speeds[layer]/Float(layerCounts[layer]),speeds[layer-1]/Float(layerCounts[layer-1]))
            XCTAssertGreaterThan(widths[layer]/Float(layerCounts[layer]),widths[layer-1]/Float(layerCounts[layer-1]))
        }
    }

    @MainActor
    func testMultipleWidgetRainIsOrderIndependentAndReleasesWetResources() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        var first = WidgetRainArea(); first.enabled = true; first.x = 0.05; first.y = 0.3; first.width = 0.4
        var second = first; second.x = 0.55; second.y = 0.55
        var policy = RenderPolicy(); policy.permitsLightning = false; policy.permitsMeteors = false
        let scene = SceneState.preview(kind: .rain,time: .day)
        policy.widgetRainAreas = [first]
        let single = try render(scene,seconds: 3,resources: resources,policy: policy)
        XCTAssertGreaterThan(compositor?.rainSceneBytes ?? 0,0)
        policy.widgetRainAreas = [first,second]
        let multiple = try render(scene,seconds: 3,resources: resources,policy: policy)
        XCTAssertNotEqual(single,multiple)
        policy.widgetRainAreas.reverse()
        XCTAssertEqual(multiple,try render(scene,seconds: 3,resources: resources,policy: policy))
        // A lower area directly behind the first must not receive the same rain.
        second = first; second.y += 0.3; second.x += 0.05; second.width -= 0.1
        policy.widgetRainAreas = [second,first]
        XCTAssertEqual(single,try render(scene,seconds: 3,resources: resources,policy: policy))
        _ = try render(.preview(kind: .clear,time: .day),resources: resources,policy: policy)
        XCTAssertEqual(compositor?.rainSceneBytes,0)
        policy.widgetRainAreas = Array(repeating: first,count: 24)
        policy.showsWidgetGuide = true
        _ = try render(scene,seconds: 3,resources: resources,policy: policy)
        compositor?.releaseTransientResources()
        XCTAssertEqual(compositor?.allocatedTransientBytes,0)
    }

    @MainActor
    func testOptionalLayeredRainAndStarsReview() async throws {
        guard let path = ProcessInfo.processInfo.environment["WEATHER_WALLPAPER_RAIN_REVIEW"] else {
            throw XCTSkip("Set WEATHER_WALLPAPER_RAIN_REVIEW for rain/star captures and timings")
        }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        let root = URL(fileURLWithPath: path)
        var areas: [WidgetRainArea] = []
        for (x,y,w,h): (Float,Float,Float,Float) in [(0.08,0.30,0.23,0.2),(0.35,0.30,0.23,0.2),(0.62,0.30,0.23,0.45),(0.08,0.55,0.23,0.2),(0.35,0.55,0.23,0.2)] {
            var area = WidgetRainArea(); area.enabled = true; area.x = x; area.y = y
            area.width = w; area.height = h; area.cornerRadius = 24; areas.append(area)
        }
        var report: [[String: Any]] = []
        for efficient in [false,true] {
            width = 1600; height = 1000
            var policy = RenderPolicy(); policy.permitsLightning = false; policy.permitsMeteors = false
            if efficient { policy.cloudSteps = 20; policy.cloudDownsample = 4; policy.bloomDownsample = 8; policy.particleScale = 0.5 }
            for kind: WeatherKind in [.rain,.thunderstorm,.sleet] {
                for time: PreviewTime in [.day,.night] {
                    policy.widgetRainAreas = areas
                    let scene = SceneState.preview(kind: kind,time: time)
                    let name = "\(kind.rawValue)-\(time.rawValue)-\(efficient ? "efficient" : "normal")"
                    let pixels = try render(scene,seconds: 7.2,resources: resources,policy: policy)
                    try writePNG(pixels,to: root.appendingPathComponent(name+".png"))
                }
            }
            let scene = SceneState.preview(kind: .rain,time: .day)
            policy.showsWidgetGuide = true
            try writePNG(try render(scene,seconds: 7.2,resources: resources,policy: policy),
                         to: root.appendingPathComponent("placement-\(efficient).png"))
            policy.showsWidgetGuide = false
            width = efficient ? 1600 : 2560; height = efficient ? 1000 : 1600
            var maximumLayout: [WidgetRainArea] = []
            for i in 0..<24 {
                var area = WidgetRainArea(); area.enabled = true
                area.x = 0.04+Float(i%6)*0.155; area.y = 0.08+Float(i/6)*0.22
                area.width = 0.14; area.height = 0.18; maximumLayout.append(area)
            }
            for count in [0,5,24] {
                policy.widgetRainAreas = count == 24 ? maximumLayout : Array(areas.prefix(count))
                var times: [Double] = [], dry: [Double] = []
                for frame in 0..<36 {
                    // Same cloud uniforms; clear only the precipitation channel.
                    _ = try render(scene,seconds: 7+Float(frame)/30,resources: resources,policy: policy,rainOverride: 0)
                    if frame >= 6 { dry.append(lastGPUTime*1000) }
                    _ = try render(scene,seconds: 7+Float(frame)/30,resources: resources,policy: policy)
                    if frame >= 6 { times.append(lastGPUTime*1000) }
                }
                report.append(["efficient":efficient,"areas":count,"mean_gpu_ms":times.reduce(0,+)/Double(times.count),
                               "no_rain_mean_gpu_ms":dry.reduce(0,+)/Double(dry.count),"width":width,"height":height,
                               "transient_bytes":compositor?.allocatedTransientBytes ?? 0])
            }
            if ProcessInfo.processInfo.environment["WEATHER_WALLPAPER_REVIEW_STILLS_ONLY"] != "1" {
                width = 1440; height = 900; policy.widgetRainAreas = areas
                let fps = efficient ? 15 : 30
                let movie = try ReviewVideoWriter(url: root.appendingPathComponent("rain-\(efficient ? "efficient" : "normal")-\(UUID().uuidString.prefix(8)).mp4"),
                    width: width,height: height,fps: fps)
                for frame in 0..<(fps*6) {
                    try await movie.append(render(scene,seconds: 7+Float(frame)/Float(fps),resources: resources,policy: policy),frame: frame)
                }
                try await movie.finish()
            }
        }
        width = 1600; height = 1000
        for legacy in [false,true] {
            var policy = RenderPolicy(); policy.permitsMeteors = false; policy.volumetricClouds = !legacy
            let scene = SceneState.preview(kind: .clear,time: .night)
            try writePNG(try render(scene,seconds: 7,resources: resources,policy: policy),
                         to: root.appendingPathComponent("stars-\(legacy ? "legacy" : "hybrid").png"))
        }
        try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys])
            .write(to: root.appendingPathComponent("timings.json"))
    }

    @MainActor
    func testManualWidgetRainAndGuideRespectWeatherAndAnimation() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        var policy = RenderPolicy()
        policy.permitsLightning = false; policy.permitsMeteors = false
        var area = WidgetRainArea()
        area.enabled = true; area.x = 0.1; area.y = 0.4; area.width = 0.8; area.cornerRadius = 40
        let rain = SceneState.preview(kind: .rain,time: .day)
        let original = try render(rain,seconds: 5,resources: resources,policy: policy)
        policy.widgetRainAreas = [area]
        let bouncing = try render(rain,seconds: 5,resources: resources,policy: policy)
        XCTAssertNotEqual(original,bouncing,"Rain must collide with the manual area")
        policy.animated = false
        let paused = try render(rain,seconds: 5,resources: resources,policy: policy)
        var noAreas = policy; noAreas.widgetRainAreas = []
        XCTAssertEqual(try render(rain,seconds: 5,resources: resources,policy: noAreas),paused,"Paused animation disables the rebound")
        policy.animated = true
        for kind: WeatherKind in [.clear,.snow,.thunderstorm] {
            var scene = SceneState.preview(kind: kind,time: .day)
            if kind == .thunderstorm { scene.rain = 0 }
            let enabled = try render(scene,seconds: 5,resources: resources,policy: policy)
            var disabled = policy; disabled.widgetRainAreas = []
            XCTAssertEqual(enabled,try render(scene,seconds: 5,resources: resources,policy: disabled),
                           "Snow and dry weather must not splash")
        }
        let clear = SceneState.preview(kind: .clear,time: .day)
        let unmarked = try render(clear,resources: resources,policy: policy)
        policy.showsWidgetGuide = true
        XCTAssertNotEqual(unmarked,try render(clear,resources: resources,policy: policy),"Guide also draws in dry weather")
        policy.widgetRainAreas = []
        XCTAssertEqual(unmarked,try render(clear,resources: resources,policy: policy),"Disabled areas show no guide")
    }

    @MainActor
    func testEnlargedVariedTowersRemainInsideTheirTraversalBounds() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/WeatherWallpaper/Resources/Atmosphere.metal"),encoding: .utf8)
        let probe = """
        kernel void variedTowerProbe(device float4 *out [[buffer(0)]],device float4 *metadata [[buffer(1)]],
            constant AtmosphereUniforms &u [[buffer(2)]],texture3d<float> noise [[texture(0)]],uint id [[thread_position_in_grid]]) {
            VolumeShapeSettings s = volumeSettings(u);
            if (id < 2) metadata[id] = float4(s.towers[id].w,s.towers[id].z,s.towerStyle[id].xy);
            uint tower = id/(24*24*24), cell = id%(24*24*24);
            float3 local = (float3(cell%24,(cell/24)%24,cell/(24*24))+0.5)/24*2-1;
            float3 p = towerBoundCenterV2(s,tower)+local*towerBoundRadiusV2(s.towers[tower]);
            out[id] = float4(cloudDensityV2(p,s,noise,true),dot(local,local),(p.y-s.base)/s.towers[tower].z,0);
        }
        """
        let library = try await resources.device.makeLibrary(source: source+"\n"+probe,options: nil)
        let constants = MTLFunctionConstantValues(); var enabled = true
        constants.setConstantValue(&enabled,type: .bool,index: 0)
        let function = try await library.makeFunction(name: "variedTowerProbe",constantValues: constants)
        let pipeline = try await resources.device.makeComputePipelineState(function: function)
        let cells = 24*24*24, count = cells*2
        let output = try XCTUnwrap(resources.device.makeBuffer(length: count*MemoryLayout<SIMD4<Float>>.stride,options: .storageModeShared))
        let metadata = try XCTUnwrap(resources.device.makeBuffer(length: 2*MemoryLayout<SIMD4<Float>>.stride,options: .storageModeShared))
        var scene = SceneState.preview(kind: .partlyCloudy,time: .day,cloudDevelopment: .toweringCumulus)
        scene.cloudPresentation!.volumeFraction = 0
        var uniforms = ShaderUniforms(scene: scene,size: CGSize(width: 1600,height: 1000),seconds: 17,wind: 0)
        XCTAssertGreaterThan(uniforms.towerMetrics.x,5.45)
        XCTAssertGreaterThan(uniforms.towerMetrics.y,5.45)
        XCTAssertEqual(uniforms.towerMetrics.x*uniforms.towerMetrics.z,1,accuracy: 0.00001)
        XCTAssertEqual(uniforms.towerMetrics.y*uniforms.towerMetrics.w,1,accuracy: 0.00001)
        let command = try XCTUnwrap(resources.queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline); encoder.setBuffer(output,offset: 0,index: 0); encoder.setBuffer(metadata,offset: 0,index: 1)
        encoder.setBytes(&uniforms,length: MemoryLayout<ShaderUniforms>.stride,index: 2); encoder.setTexture(resources.noiseVolume,index: 0)
        encoder.dispatchThreads(MTLSize(width: count,height: 1,depth: 1),threadsPerThreadgroup: MTLSize(width: 64,height: 1,depth: 1))
        encoder.endEncoding()
        await withCheckedContinuation { continuation in command.addCompletedHandler { _ in continuation.resume() }; command.commit() }
        XCTAssertEqual(command.status,.completed)
        let geometry = metadata.contents().assumingMemoryBound(to: SIMD4<Float>.self)
        XCTAssertGreaterThan(geometry[0].x,1.65*1.2); XCTAssertGreaterThan(geometry[1].x,1.83*1.2)
        XCTAssertLessThan(geometry[0].z,0); XCTAssertGreaterThan(geometry[1].z,0,"Towers should not share the same lean")
        let data = output.contents().assumingMemoryBound(to: SIMD4<Float>.self)
        var occupied = [0,0], variation = 0.0
        for i in 0..<count {
            XCTAssertTrue(data[i].x.isFinite); XCTAssertGreaterThanOrEqual(data[i].x,0)
            if data[i].x > 0.001 {
                occupied[i/cells] += 1
                XCTAssertLessThanOrEqual(data[i].y,1.001,"Traversal ellipsoids must not clip the varied billows")
                XCTAssertGreaterThan(data[i].z,0); XCTAssertLessThan(data[i].z,1)
            }
            if i < cells { variation += Double(abs(data[i].x-data[i+cells].x)) }
        }
        XCTAssertTrue(occupied.allSatisfy { $0 > 100 })
        XCTAssertGreaterThan(variation/Double(cells),0.005,"Normalized towers should not be repeated copies")
    }

    @MainActor
    func testCloudDensityFootprintFilterHasCompactSupport() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/WeatherWallpaper/Resources/Atmosphere.metal"),encoding: .utf8)
        let probe = """
        kernel void densityFootprintProbe(device float2 *out [[buffer(0)]],uint id [[thread_position_in_grid]]) {
            const float values[7] = {-0.04,-0.02,-0.01,0,0.01,0.02,0.04};
            out[id] = float2(filteredCloudDensity(values[id],0.02),filteredCloudDensity(values[id],0));
        }
        """
        let library = try await resources.device.makeLibrary(source: source+"\n"+probe,options: nil)
        let pipeline = try await resources.device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "densityFootprintProbe")))
        let output = try XCTUnwrap(resources.device.makeBuffer(length: 7*MemoryLayout<SIMD2<Float>>.stride,options: .storageModeShared))
        let command = try XCTUnwrap(resources.queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline); encoder.setBuffer(output,offset: 0,index: 0)
        encoder.dispatchThreads(MTLSize(width: 7,height: 1,depth: 1),threadsPerThreadgroup: MTLSize(width: 7,height: 1,depth: 1))
        encoder.endEncoding()
        await withCheckedContinuation { continuation in
            command.addCompletedHandler { _ in continuation.resume() }; command.commit()
        }
        XCTAssertEqual(command.status,.completed)
        let actual = output.contents().assumingMemoryBound(to: SIMD2<Float>.self)
        let filtered: [Float] = [0,0,0.00125,0.005,0.01125,0.02,0.04]
        let unfiltered: [Float] = [0,0,0,0,0.01,0.02,0.04]
        for i in 0..<7 {
            XCTAssertEqual(actual[i].x,filtered[i],accuracy: 0.000001)
            XCTAssertEqual(actual[i].y,unfiltered[i],accuracy: 0.000001)
            if i > 0 { XCTAssertGreaterThanOrEqual(actual[i].x,actual[i-1].x) }
        }
    }

    @MainActor
    func testCumulusBillowLightingFollowsTheSourceWithoutChangingOpacity() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        width = 384; height = 240
        var scene = formerCumulusFixture()
        scene.solar.sunPosition = SIMD2(0.15,0.10)
        let left = try cloudField(scene,resources: resources)
        scene.solar.sunPosition = SIMD2(0.85,0.55)
        let right = try cloudField(scene,resources: resources)
        var shaded = 0, lit = 0, lightingChange = 0.0
        for i in 0..<left.count {
            XCTAssertEqual(left[i].w,right[i].w,accuracy: 0.002)
            XCTAssertTrue(left[i].x.isFinite && right[i].x.isFinite)
            if left[i].w > 0.5 {
                let a = (left[i].x+left[i].y+left[i].z)/(3*left[i].w)
                let b = (right[i].x+right[i].y+right[i].z)/(3*right[i].w)
                lightingChange += Double(abs(a-b))
                if a < 0.45 { shaded += 1 }; if a > 0.8 { lit += 1 }
            }
        }
        XCTAssertGreaterThan(shaded,100,"Retain shaded billows/undersides, not a flat white fill")
        XCTAssertGreaterThan(lit,100,"Retain illuminated billows, not a uniform dark ceiling")
        XCTAssertGreaterThan(lightingChange,100,"Cloud lighting must respond to the real source direction")
    }

    @MainActor
    func testBillowSpecializationPreservesContinuousMorphology() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        width = 384; height = 240
        let cumulus = formerCumulusFixture()
        let bank = SceneState.preview(kind: .windy,time: .day)
        for (scene,mode) in [(cumulus,UInt32(2)),(bank,0),(.preview(kind: .rain,time: .day),0),
                             (.interpolate(from: cumulus,to: bank,progress: 0.5),1)] {
            let uniforms = ShaderUniforms(scene: scene,size: CGSize(width: width,height: height),seconds: 0,wind: 0)
            XCTAssertEqual(uniforms.cloudBillowMode,mode)
            let specialized = try cloudField(scene,resources: resources)
            let mixed = try cloudField(scene,resources: resources,pipeline: resources.volumeCloudPipeline)
            let errors = zip(specialized,mixed).map { abs($0.w-$1.w) }
            XCTAssertLessThanOrEqual(errors.max() ?? 0,0.002)
            XCTAssertLessThan(errors.reduce(0,+)/Float(errors.count),0.00003,"Pipeline endpoints must not quantize a continuous scene")
        }
    }

    @MainActor
    func testOptionalCumulusQualityReview() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let output = env["WEATHER_WALLPAPER_CUMULUS_REVIEW"],let baselinePath = env["WEATHER_WALLPAPER_CUMULUS_BASELINE"] else {
            throw XCTSkip("Set WEATHER_WALLPAPER_CUMULUS_REVIEW and WEATHER_WALLPAPER_CUMULUS_BASELINE for cloud morphology/sampling A/B")
        }
        let resources = try MetalResources.shared.get()
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        let library = try await resources.device.makeLibrary(source: String(contentsOfFile: baselinePath,encoding: .utf8),options: nil)
        func pipeline(_ name: String,format: MTLPixelFormat,volume: Bool = true,towers: Bool = false) async throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: name == "atmosphereComposite" || name == "atmosphereEmission"
                ? "solarAtmosphereVertex" : "atmosphereVertex") ?? library.makeFunction(name: "atmosphereVertex")
            let constants = MTLFunctionConstantValues()
            if name == "volumeCloudFragment" {
                var v = volume, t = towers
                constants.setConstantValue(&v,type: .bool,index: 2); constants.setConstantValue(&t,type: .bool,index: 0)
            }
            descriptor.fragmentFunction = try await library.makeFunction(name: name,constantValues: constants)
            descriptor.colorAttachments[0].pixelFormat = format
            return try await resources.device.makeRenderPipelineState(descriptor: descriptor)
        }
        let oldVolume = try await pipeline("volumeCloudFragment",format: .rgba16Float)
        let oldTowers = try await pipeline("volumeCloudFragment",format: .rgba16Float,towers: true)
        let oldIce = try await pipeline("volumeCloudFragment",format: .rgba16Float,volume: false)
        let before = SceneCompositor(resources: resources,cloudPipeline: oldVolume,convectiveCloudPipeline: oldTowers,iceCloudPipeline: oldIce,
            atmospherePipeline: try await pipeline("atmosphereComposite",format: .bgra8Unorm_srgb),
            atmosphereEmissionPipeline: try await pipeline("atmosphereEmission",format: .rgba16Float),useLightCache: false,useCloudHistory: false)
        let after = SceneCompositor(resources: resources,useLightCache: false,useCloudHistory: false)
        compositor = after
        var broken = formerCumulusFixture()
        broken.solar.moon.visibility = 0
        var backlit = broken; backlit.solar.sunPosition = SIMD2(0.46,0.42)
        var sparse = broken; sparse.cloud = 0.18
        let towers = formerCumulusFixture(towers: true)
        let cases: [(String,SceneState)] = [("cumulus",broken),("backlit",backlit),("sparse",sparse),("towers",towers),
            ("sunset",formerCumulusFixture(time: .dusk)),
            ("night",formerCumulusFixture(time: .night)),("windy",.preview(kind: .windy,time: .day)),
            ("opaque",.preview(kind: .rain,time: .day)),("cirrus",.preview(kind: .clear,time: .day,cloudGenus: .cirrus))]
        var sampling: [[String: Any]] = []
        width = 384; height = 240
        for (name,scene) in cases {
            let oldPipeline = name == "cirrus" ? oldIce : (name == "towers" ? oldTowers : oldVolume)
            for efficient in [false,true] {
                var policy = RenderPolicy()
                if efficient { policy.cloudSteps = 20; policy.cloudDownsample = 4; policy.bloomDownsample = 8 }
                var referencePolicy = policy; referencePolicy.cloudSteps = 192
                let oldReference = try cloudField(scene,resources: resources,policy: referencePolicy,pipeline: oldPipeline)
                let newReference = try cloudField(scene,resources: resources,policy: referencePolicy)
                let old = try cloudField(scene,resources: resources,policy: policy,pipeline: oldPipeline)
                let new = try cloudField(scene,resources: resources,policy: policy)
                func metrics(_ image: [SIMD4<Float>],_ reference: [SIMD4<Float>]) -> [String: Double] {
                    var squared = 0.0, rows = 0.0, edges = 0.0, edgeCount = 0
                    let end = Int(Float(height)*0.60)
                    for y in 0..<end {
                        var row = 0.0
                        for x in 0..<width {
                            let i = y*width+x, e = Double(image[i].w-reference[i].w)
                            squared += e*e; row += e
                            if reference[i].w > 0.02 && reference[i].w < 0.95 { edges += e*e; edgeCount += 1 }
                        }
                        rows += pow(row/Double(width),2)
                    }
                    return ["mean_opacity": image.prefix(end*width).reduce(0.0) { $0+Double($1.w) }/Double(end*width),
                            "opacity_rmse": sqrt(squared/Double(end*width)),"row_rmse": sqrt(rows/Double(end)),
                            "edge_rmse": sqrt(edges/Double(max(1,edgeCount)))]
                }
                if name == "opaque" || name == "cirrus" {
                    XCTAssertLessThanOrEqual(zip(old,new).map { abs($0.w-$1.w) }.max() ?? 0,0.002,"Protect wet ceilings and high-only ice")
                }
                let oldMetrics = metrics(old,oldReference), newMetrics = metrics(new,newReference)
                if ["cumulus","backlit","sparse","towers"].contains(name) {
                    XCTAssertLessThan(newMetrics["edge_rmse"]!,oldMetrics["edge_rmse"]!*0.90,"Improve edge integration against each morphology's own converged field")
                    XCTAssertLessThan(newMetrics["opacity_rmse"]!,oldMetrics["opacity_rmse"]!*1.1)
                    XCTAssertLessThan(abs(newMetrics["mean_opacity"]!-oldMetrics["mean_opacity"]!),0.06,"Avoid the rejected overly filled cloud composition")
                }
                sampling.append(["scene": name,"efficient": efficient,"before": oldMetrics,"after": newMetrics])
            }
        }
        var timing: [[String: Any]] = []
        width = 2560; height = 1600
        for (name,scene) in cases {
            for efficient in [false,true] {
                var policy = RenderPolicy(); policy.permitsMeteors = false; policy.permitsLightning = false
                if efficient { policy.cloudSteps = 20; policy.cloudDownsample = 4; policy.bloomDownsample = 8 }
                var old: [Double] = [], new: [Double] = []
                for frame in 0..<40 {
                    for previous in (frame%2 == 0 ? [true,false] : [false,true]) {
                        _ = try render(scene,seconds: 19+Float(frame)/30,resources: resources,policy: policy,
                                       baseline: previous ? before : nil,historicalUniforms: false)
                        if frame >= 10 { if previous { old.append(lastGPUTime*1000) } else { new.append(lastGPUTime*1000) } }
                    }
                }
                func stats(_ values: [Double]) -> [String: Double] {
                    let sorted = values.sorted()
                    return ["mean_ms": values.reduce(0,+)/Double(values.count),"p95_ms": sorted[Int(Double(sorted.count-1)*0.95)]]
                }
                XCTAssertEqual(before.allocatedTransientBytes,after.allocatedTransientBytes)
                timing.append(["scene": name,"efficient": efficient,"before": stats(old),"after": stats(new),"transient_bytes": after.allocatedTransientBytes])
                try writePNG(render(scene,seconds: 19,resources: resources,policy: policy,baseline: before,historicalUniforms: false),
                             to: directory.appendingPathComponent("before-\(name)-\(efficient).png"))
                try writePNG(render(scene,seconds: 19,resources: resources,policy: policy),to: directory.appendingPathComponent("after-\(name)-\(efficient).png"))
            }
        }
        // Amplified isolated cloud passes avoid readback and most inter-frame CPU
        // gaps. These are still diagnostics, not sustained energy/thermal claims.
        var isolated: [[String: Any]] = []
        for (name,scene) in cases where ["cumulus","sparse","towers","windy","opaque"].contains(name) {
            for efficient in [false,true] {
                var policy = RenderPolicy()
                if efficient { policy.cloudSteps = 20; policy.cloudDownsample = 4 }
                let divisor = policy.cloudDownsample
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,width: 2560/divisor,height: 1600/divisor,mipmapped: false)
                descriptor.storageMode = .private; descriptor.usage = [.renderTarget]
                let target = try XCTUnwrap(resources.device.makeTexture(descriptor: descriptor))
                var uniforms = ShaderUniforms(scene: scene,size: CGSize(width: 2560,height: 1600),seconds: 19,wind: Double(19*scene.wind*scene.windDirection),policy: policy)
                let oldPipeline = name == "towers" ? oldTowers : oldVolume
                let newPipeline = resources.cloudVolumePipeline(for: uniforms)
                func batch(_ pipeline: MTLRenderPipelineState) throws -> Double {
                    let command = try XCTUnwrap(resources.queue.makeCommandBuffer())
                    let pass = MTLRenderPassDescriptor()
                    pass.colorAttachments[0].texture = target; pass.colorAttachments[0].loadAction = .dontCare; pass.colorAttachments[0].storeAction = .store
                    for _ in 0..<8 {
                        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
                        encoder.setRenderPipelineState(pipeline)
                        encoder.setFragmentBytes(&uniforms,length: MemoryLayout<ShaderUniforms>.stride,index: 0)
                        encoder.setFragmentTexture(resources.noiseVolume,index: 0); encoder.setFragmentTexture(resources.emptyLightDepth,index: 1)
                        encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 3); encoder.endEncoding()
                    }
                    command.commit(); command.waitUntilCompleted()
                    XCTAssertEqual(command.status,.completed)
                    return (command.gpuEndTime-command.gpuStartTime)*1000/8
                }
                var old: [Double] = [], new: [Double] = []
                for round in 0..<12 {
                    for previous in (round%2 == 0 ? [true,false] : [false,true]) {
                        let value = try batch(previous ? oldPipeline : newPipeline)
                        if round >= 3 { if previous { old.append(value) } else { new.append(value) } }
                    }
                }
                isolated.append(["scene": name,"efficient": efficient,"before_mean_ms": old.reduce(0,+)/Double(old.count),
                                 "after_mean_ms": new.reduce(0,+)/Double(new.count)])
            }
        }
        try JSONSerialization.data(withJSONObject: ["device": resources.device.name,"sampling": sampling,"timings": timing,"isolated_cloud": isolated,
            "notes": "Same profile/quality, changed morphology is not identical geometry. Each sampling diagnostic uses its OWN source at a 192-step reference ceiling. Full-pipeline timings include readback, not sustained energy."],
            options: [.prettyPrinted,.sortedKeys]).write(to: directory.appendingPathComponent("review.json"))
        if env["WEATHER_WALLPAPER_REVIEW_STILLS_ONLY"] == "1" { return }
        width = 1440; height = 900
        for (name,scene) in [("cumulus",broken),("towers",towers)] {
            let movie = try ReviewVideoWriter(url: directory.appendingPathComponent("\(name)-motion.mp4"),width: width,height: height,fps: 30)
            for frame in 0..<180 { try await movie.append(render(scene,seconds: 19+Float(frame)/30,resources: resources),frame: frame) }
            try await movie.finish()
        }
    }

    @MainActor
    func testInnerDiffractionShouldersBlendWithoutDimmingTheTips() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/WeatherWallpaper/Resources/Atmosphere.metal"),encoding: .utf8)
        // Evaluate the shipping diffraction function before bloom/tonemapping,
        // so a saturated white core cannot conceal excessively bright blade roots.
        let probe = """
        kernel void diffractionBlendProbe(device float *out [[buffer(0)]],
                                          constant AtmosphereUniforms &u [[buffer(1)]],uint id [[thread_position_in_grid]]) {
            const float radii[3] = {0.06,0.14,0.18};
            out[id] = solarDiffractionV2(float2(0.9659258,0.2588190)*radii[id],u);
        }
        """
        let library = try await resources.device.makeLibrary(source: source+"\n"+probe,options: nil)
        let pipeline = try await resources.device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "diffractionBlendProbe")))
        let output = try XCTUnwrap(resources.device.makeBuffer(length: 3*MemoryLayout<Float>.stride,options: .storageModeShared))
        var uniforms = ShaderUniforms(scene: .preview(kind: .clear,time: .day),size: CGSize(width: 1600,height: 1000),seconds: 0,wind: 0)
        let command = try XCTUnwrap(resources.queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(output,offset: 0,index: 0)
        encoder.setBytes(&uniforms,length: MemoryLayout<ShaderUniforms>.stride,index: 1)
        encoder.dispatchThreads(MTLSize(width: 3,height: 1,depth: 1),threadsPerThreadgroup: MTLSize(width: 3,height: 1,depth: 1))
        encoder.endEncoding()
        await withCheckedContinuation { continuation in
            command.addCompletedHandler { _ in continuation.resume() }
            command.commit()
        }
        XCTAssertEqual(command.status,.completed)
        let values = output.contents().assumingMemoryBound(to: Float.self)
        // The old inner shoulder was ~2.80. Its ~1.56 replacement lets the bloom
        // carry the middle while the already-shortened outer values stay intact.
        XCTAssertEqual(values[0],1.56,accuracy: 0.06)
        XCTAssertEqual(values[1],0.522,accuracy: 0.01)
        XCTAssertEqual(values[2],0.072,accuracy: 0.005)
    }

    @MainActor
    func testWarmSunRotatesCounterclockwiseWithoutMovingLensGhosts() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        width = 1600; height = 1000
        var scene = SceneState.preview(kind: .clear,time: .day)
        scene.cloud = 0; scene.solar.sunPosition = SIMD2(0.29,0.17); scene.solar.moon.visibility = 0
        let start = try render(scene,resources: resources)
        let turned = try render(scene,seconds: 5,resources: resources)
        var quiet = RenderPolicy(); quiet.bloom = false
        let noOptics = try render(scene,resources: resources,policy: quiet)
        func addedRGB(_ image: [UInt8],at uv: SIMD2<Float>) -> SIMD3<Double> {
            let x = Int(uv.x*Float(width)), y = Int(uv.y*Float(height))
            var value = SIMD3<Double>.zero
            for dy in -2...2 { for dx in -2...2 {
                let i = ((y+dy)*width+x+dx)*4
                value += SIMD3(Double(Int(image[i+2])-Int(noOptics[i+2])),
                               Double(Int(image[i+1])-Int(noOptics[i+1])),Double(Int(image[i])-Int(noOptics[i])))
            } }
            return value/25
        }
        func ray(_ angle: Float) -> SIMD2<Float> {
            // Sample inside the shortened blade, not at the old long-ray tip.
            scene.solar.sunPosition+SIMD2(cos(angle)*Float(height)/Float(width),sin(angle))*0.14
        }
        let ccw = addedRGB(turned,at: ray(0)), cw = addedRGB(turned,at: ray(.pi/6))
        XCTAssertGreaterThan(ccw.x+ccw.y+ccw.z,cw.x+cw.y+cw.z+15,"After 5s the initial 15° ray must turn UP to 0°, not down to 30°")
        XCTAssertGreaterThan(ccw.x,ccw.z+5,"Ray light should be warm yellow/amber, not neutral white")
        let initial = addedRGB(start,at: ray(.pi/12))
        XCTAssertGreaterThan(initial.x+initial.y+initial.z,30)
        let ghostUV = scene.solar.sunPosition+(SIMD2<Float>(repeating: 0.5)-scene.solar.sunPosition)
        XCTAssertEqual(addedRGB(start,at: ghostUV),addedRGB(turned,at: ghostUV),"Lens ghosts must not orbit with the blades")
        XCTAssertGreaterThan(addedRGB(start,at: ghostUV).z,8,"Blue ghost dots should be clearly visible")
        let cycle = try render(scene,seconds: 125,resources: resources)
        XCTAssertLessThanOrEqual(zip(turned,cycle).map { abs(Int($0)-Int($1)) }.max() ?? 0,1)
        let hour = try render(scene,seconds: 3605,resources: resources)
        XCTAssertEqual(turned,hour,"The split clock must not change the 120-second phase")
        XCTAssertEqual(try render(scene,seconds: 5,resources: resources),turned,"A frozen scene clock must produce the same optics")
        let edgeA = try render(scene,seconds: 3599.99,resources: resources)
        let edgeB = try render(scene,seconds: 3600.01,resources: resources)
        let errors = zip(edgeA,edgeB).map { abs(Int($0)-Int($1)) }
        XCTAssertLessThanOrEqual(errors.max() ?? 0,4,"No visible hour-boundary phase jump")
        XCTAssertLessThan(Double(errors.reduce(0,+))/Double(errors.count),0.1)
        let environment = SceneEnvironment(scene: scene)
        var paused = RenderPolicy(); paused.animated = false
        environment.setPolicy(paused)
        let now = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(environment.animationTime(at: now),environment.animationTime(at: now+30),"Pause / Reduce Motion must freeze the clock driving rotation")
        paused.animated = true; paused.suspended = true; environment.setPolicy(paused)
        XCTAssertEqual(environment.animationTime(at: now),environment.animationTime(at: now+30))
    }

    @MainActor
    func testPortraitSolarGlareDoesNotWrapToTheOppositeEdge() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        width = 900; height = 1932
        var scene = SceneState.preview(kind: .clear,time: .day)
        scene.cloud = 0; scene.solar.sunPosition = SIMD2(0.29,0.17); scene.solar.moon.visibility = 0
        let optics = try render(scene,resources: resources)
        var quiet = RenderPolicy(); quiet.bloom = false
        let noOptics = try render(scene,resources: resources,policy: quiet)
        // This used to show an unrelated second blade at the right edge because
        // the celestial seam delta wrapped a wide height-scaled glare footprint.
        let i = (Int(Float(height)*0.12)*width+Int(Float(width)*0.87))*4
        XCTAssertLessThanOrEqual((0..<3).map { abs(Int(optics[i+$0])-Int(noOptics[i+$0])) }.max() ?? 0,1)
        let scale = sqrt(Float(width)/Float(height))
        let ringX = 0.29+0.295*scale*Float(height)/Float(width)
        let ring = (Int(Float(height)*0.17)*width+Int(Float(width)*ringX))*4
        XCTAssertGreaterThan((0..<3).map { Int(optics[ring+$0])-Int(noOptics[ring+$0]) }.max() ?? 0,3,"Keep the rainbow arc visible on the inward/right side")
    }

    @MainActor
    func testOptionalWarmRotatingSunReview() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let output = env["WEATHER_WALLPAPER_WARM_SUN_REVIEW"],let baselinePath = env["WEATHER_WALLPAPER_WARM_SUN_BASELINE"] else {
            throw XCTSkip("Set WEATHER_WALLPAPER_WARM_SUN_REVIEW and WEATHER_WALLPAPER_WARM_SUN_BASELINE for rotating optics A/B")
        }
        let resources = try MetalResources.shared.get()
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        let library = try await resources.device.makeLibrary(source: String(contentsOfFile: baselinePath,encoding: .utf8),options: nil)
        func pipeline(_ name: String,format: MTLPixelFormat) async throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "solarAtmosphereVertex") ?? library.makeFunction(name: "atmosphereVertex")
            descriptor.fragmentFunction = try await library.makeFunction(name: name,constantValues: MTLFunctionConstantValues())
            descriptor.colorAttachments[0].pixelFormat = format
            return try await resources.device.makeRenderPipelineState(descriptor: descriptor)
        }
        let old = SceneCompositor(resources: resources,
            atmospherePipeline: try await pipeline("atmosphereComposite",format: .bgra8Unorm_srgb),
            atmosphereEmissionPipeline: try await pipeline("atmosphereEmission",format: .rgba16Float),useLightCache: false,useCloudHistory: false)
        let current = SceneCompositor(resources: resources,useLightCache: false,useCloudHistory: false)
        compositor = current
        var scene = SceneState.preview(kind: .clear,time: .day)
        scene.cloud = 0; scene.solar.sunPosition = SIMD2(0.29,0.17); scene.solar.moon.visibility = 0
        var appearance: [[String: Any]] = []
        for (w,h) in [(900,1932),(2560,1600)] {
            width = w; height = h
            for efficient in [false,true] {
                var policy = RenderPolicy(); policy.permitsMeteors = false; policy.permitsLightning = false
                if efficient { policy.cloudSteps = 20; policy.cloudDownsample = 4; policy.bloomDownsample = 8 }
                let before = try render(scene,resources: resources,policy: policy,baseline: old,historicalUniforms: false)
                try writePNG(before,to: directory.appendingPathComponent("before-\(w)x\(h)-\(efficient).png"))
                for seconds: Float in [0,5,15] {
                    let after = try render(scene,seconds: seconds,resources: resources,policy: policy)
                    try writePNG(after,to: directory.appendingPathComponent("after-\(w)x\(h)-\(efficient)-\(Int(seconds)).png"))
                    if seconds == 0 {
                        func hotPixels(_ image: [UInt8]) -> Int {
                            stride(from: 0,to: image.count,by: 4).filter { min(image[$0],min(image[$0+1],image[$0+2])) > 240 }.count
                        }
                        let oldArea = hotPixels(before), newArea = hotPixels(after)
                        XCTAssertLessThan(newArea,oldArea,"Concentrate exposure into a smaller white-hot center")
                        appearance.append(["width": w,"height": h,"efficient": efficient,"white_hot_pixels_before": oldArea,"white_hot_pixels_after": newArea])
                    }
                }
            }
        }
        width = 2560; height = 1600
        var report: [[String: Any]] = []
        for (name,sun) in [("clear",SIMD2<Float>(0.29,0.17)),("offscreen",SIMD2<Float>(0.29,1.2))] {
            scene.solar.sunPosition = sun
            for efficient in [false,true] {
                var policy = RenderPolicy(); policy.permitsMeteors = false; policy.permitsLightning = false
                if efficient { policy.cloudSteps = 20; policy.cloudDownsample = 4; policy.bloomDownsample = 8 }
                var before: [Double] = [], after: [Double] = []
                for frame in 0..<72 {
                    for previous in (frame%2 == 0 ? [true,false] : [false,true]) {
                        _ = try render(scene,seconds: Float(frame)/30,resources: resources,policy: policy,
                                       baseline: previous ? old : nil,historicalUniforms: false)
                        if frame >= 16 { if previous { before.append(lastGPUTime*1000) } else { after.append(lastGPUTime*1000) } }
                    }
                }
                func stats(_ values: [Double]) -> [String: Double] {
                    let sorted = values.sorted()
                    return ["mean_ms": values.reduce(0,+)/Double(values.count),"p95_ms": sorted[Int(Double(sorted.count-1)*0.95)]]
                }
                XCTAssertEqual(old.allocatedTransientBytes,current.allocatedTransientBytes)
                report.append(["scene": name,"efficient": efficient,"before": stats(before),"after": stats(after),
                               "transient_bytes": current.allocatedTransientBytes])
            }
        }
        try JSONSerialization.data(withJSONObject: ["device": resources.device.name,"timings": report,"appearance": appearance,
            "notes": "Only optics pipelines differ. Native clear-source fixtures with illustrative preview sun framing; no live ephemeris override. Readback-inclusive, not sustained energy."],
            options: [.prettyPrinted,.sortedKeys]).write(to: directory.appendingPathComponent("review.json"))
        if env["WEATHER_WALLPAPER_REVIEW_STILLS_ONLY"] == "1" { return }
        width = 1440; height = 900; scene.solar.sunPosition = SIMD2(0.29,0.30)
        let movie = try ReviewVideoWriter(url: directory.appendingPathComponent("counterclockwise-sun.mp4"),width: width,height: height,fps: 30)
        for frame in 0..<300 { try await movie.append(render(scene,seconds: Float(frame)/30,resources: resources),frame: frame) }
        try await movie.finish()
    }

    @MainActor
    func testClearSunHasSixFoldDiffractionOutsideThePhysicalDisk() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        width = 1600; height = 1000
        var scene = SceneState.preview(kind: .clear,time: .day)
        scene.cloud = 0; scene.solar.sunPosition = SIMD2(0.5,0.5); scene.solar.moon.visibility = 0
        var policy = RenderPolicy(); policy.permitsMeteors = false
        let glare = try render(scene,resources: resources,policy: policy)
        policy.bloom = false
        let disk = try render(scene,resources: resources,policy: policy)
        func addedLight(angle: Float, radius: Float = 0.14) -> Double {
            let uv = scene.solar.sunPosition+SIMD2(cos(angle)/Float(width)*Float(height),sin(angle))*radius
            let x = Int(uv.x*Float(width)), y = Int(uv.y*Float(height))
            var value = 0.0
            for dy in -2...2 { for dx in -2...2 {
                let i = ((y+dy)*width+x+dx)*4
                value += Double(Int(glare[i])-Int(disk[i]))*0.0722
                    + Double(Int(glare[i+1])-Int(disk[i+1]))*0.7152
                    + Double(Int(glare[i+2])-Int(disk[i+2]))*0.2126
            } }
            return value/25
        }
        var rays: [Double] = [], between: [Double] = []
        for point in 0..<6 {
            let angle = Float(point)*Float.pi/3+Float.pi/12
            rays.append(addedLight(angle: angle)); between.append(addedLight(angle: angle+Float.pi/6))
        }
        XCTAssertGreaterThan((rays.reduce(0,+)-between.reduce(0,+))/6,5,"Six blade-axis rays must extend beyond the circular bloom")
        XCTAssertTrue(rays.allSatisfy { $0 > 8 },"All six points must be visible, not one isolated flare ghost")
        let outerContrast = (0..<6).map { point -> Double in
            let angle = Float(point)*Float.pi/3+Float.pi/12
            return addedLight(angle: angle,radius: 0.24)-addedLight(angle: angle+Float.pi/6,radius: 0.24)
        }
        XCTAssertLessThan(outerContrast.reduce(0,+)/6,2,"The old long spike tips should no longer extend beyond the softened 0.21 footprint")
    }

    @MainActor
    func testBackgroundTowersPreserveNearCloudsAndAppearThroughDistantGaps() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        width = 384; height = 240
        let combined = SceneState.preview(kind: .partlyCloudy,time: .day,cloudDevelopment: .toweringCumulus)
        var foreground = combined; foreground.cloudPresentation!.convection = .zero
        var background = combined; background.cloudPresentation!.volumeFraction = 0
        let fore = try cloudField(foreground,resources: resources)
        let back = try cloudField(background,resources: resources)
        let composite = try cloudField(combined,resources: resources)
        var changedNear: Float = 0, nearError = 0.0, nearCount = 0, exposedTowers = 0
        for i in 0..<fore.count {
            let y = Float(i/width)/Float(height)
            // Enlarged background towers can now extend into the upper band.
            // Compare foreground-only rays, not pixels where new sky mass belongs.
            if y < 0.30 && back[i].w < 0.001 {
                let delta = abs(fore[i].w-composite[i].w)
                changedNear = max(changedNear,delta); nearError += Double(delta); nearCount += 1
            }
            if fore[i].w < 0.02 && back[i].w > 0.2 && composite[i].w > 0.05 { exposedTowers += 1 }
            XCTAssertTrue(composite[i].x.isFinite && composite[i].w.isFinite)
            XCTAssertGreaterThanOrEqual(composite[i].w,0); XCTAssertLessThanOrEqual(composite[i].w,1)
            if y >= 0.84 { XCTAssertEqual(composite[i],.zero) }
        }
        // The ordinary and convective pipeline specializations can round texture
        // coordinates differently. Bound both worst-case and average opacity error.
        XCTAssertLessThanOrEqual(changedNear,0.002,"Adding distant towers must not replace/re-shape near clouds")
        XCTAssertGreaterThan(nearCount,1000)
        XCTAssertLessThan(nearError/Double(max(1,nearCount)),0.00002)
        XCTAssertGreaterThan(exposedTowers,30,"The extra tower volume must be visible in genuinely clear foreground gaps")
    }

    @MainActor
    func testOptionalSixPointSunAndCompositeTowerReview() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let output = env["WEATHER_WALLPAPER_COMPOSITE_REVIEW"],let baselinePath = env["WEATHER_WALLPAPER_COMPOSITE_BASELINE"] else {
            throw XCTSkip("Set WEATHER_WALLPAPER_COMPOSITE_REVIEW and WEATHER_WALLPAPER_COMPOSITE_BASELINE for six-point sun/mixed tower review")
        }
        let resources = try MetalResources.shared.get()
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        let library = try await resources.device.makeLibrary(source: String(contentsOfFile: baselinePath,encoding: .utf8),options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "solarAtmosphereVertex") ?? library.makeFunction(name: "atmosphereVertex")
        descriptor.fragmentFunction = try await library.makeFunction(name: "atmosphereEmission",constantValues: MTLFunctionConstantValues())
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        let oldEmission = try await resources.device.makeRenderPipelineState(descriptor: descriptor)
        let oldSun = SceneCompositor(resources: resources,atmosphereEmissionPipeline: oldEmission,useLightCache: false,useCloudHistory: false)
        let current = SceneCompositor(resources: resources,useLightCache: false,useCloudHistory: false)
        compositor = current
        width = 2560; height = 1600
        var clear = SceneState.preview(kind: .clear,time: .day)
        clear.cloud = 0; clear.solar.sunPosition = SIMD2(0.49,0.28); clear.solar.moon.visibility = 0
        try writePNG(render(clear,seconds: 19,resources: resources,baseline: oldSun,historicalUniforms: false),to: directory.appendingPathComponent("before-sun.png"))
        try writePNG(render(clear,seconds: 19,resources: resources),to: directory.appendingPathComponent("six-point-sun.png"))
        var report: [[String: Any]] = []
        for (development,kind) in [(CloudDevelopment.toweringCumulus,WeatherKind.partlyCloudy),(.developingThunderstorm,.thunderstorm)] {
            let composite = SceneState.preview(kind: kind,time: .day,cloudDevelopment: development)
            var fore = composite; fore.cloudPresentation!.convection = .zero
            for efficient in [false,true] {
                var policy = RenderPolicy(); policy.permitsMeteors = false; policy.permitsLightning = false
                if efficient { policy.cloudDownsample = 4; policy.cloudSteps = 20; policy.bloomDownsample = 8; policy.framesPerSecond = 15 }
                var plain: [Double] = [], mixed: [Double] = []
                for frame in 0..<60 {
                    for towers in (frame%2 == 0 ? [true,false] : [false,true]) {
                        _ = try render(towers ? composite : fore,seconds: 19+Float(frame)/Float(policy.framesPerSecond),resources: resources,policy: policy)
                        if frame >= 12 { if towers { mixed.append(lastGPUTime*1000) } else { plain.append(lastGPUTime*1000) } }
                    }
                }
                func stats(_ values: [Double]) -> [String: Double] {
                    let sorted = values.sorted()
                    return ["mean_ms": values.reduce(0,+)/Double(values.count),"p95_ms": sorted[Int(Double(sorted.count-1)*0.95)]]
                }
                let bytes = current.allocatedTransientBytes
                try writePNG(render(composite,seconds: 19,resources: resources,policy: policy),to: directory.appendingPathComponent("composite-\(development.rawValue)-\(efficient).png"))
                try writePNG(render(fore,seconds: 19,resources: resources,policy: policy),to: directory.appendingPathComponent("foreground-\(development.rawValue)-\(efficient).png"))
                XCTAssertEqual(bytes,current.allocatedTransientBytes)
                report.append(["profile": development.rawValue,"efficient": efficient,"foreground": stats(plain),"composite": stats(mixed),"transient_bytes": bytes])
            }
        }
        try JSONSerialization.data(withJSONObject: ["device": resources.device.name,"timings": report,
            "notes": "Same foreground with towers off/on, capped 48/20 samples. Full pipeline incl readback, not sustained energy. Sun A/B changes only the emission shader."],
            options: [.prettyPrinted,.sortedKeys]).write(to: directory.appendingPathComponent("review.json"))
        if env["WEATHER_WALLPAPER_REVIEW_STILLS_ONLY"] == "1" { return }
        width = 1440; height = 900
        let scene = SceneState.preview(kind: .partlyCloudy,time: .day,cloudDevelopment: .toweringCumulus)
        let movie = try ReviewVideoWriter(url: directory.appendingPathComponent("mixed-towers.mp4"),width: width,height: height,fps: 30)
        for frame in 0..<180 { try await movie.append(render(scene,seconds: 19+Float(frame)/30,resources: resources),frame: frame) }
        try await movie.finish()
    }

    @MainActor
    func testSunOpticsFollowWeatherRatherThanPassingClouds() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        // Controlled transmission isolates the two optical regimes from random
        // cloud placement. Test-only constant cloud, never shipping artwork.
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 p [[position]]; float2 uv; };
        struct U { float4 viewport, atmosphere; };
        vertex V flatVertex(uint id [[vertex_id]]) {
            float2 p = float2(id == 1 ? 3.0 : -1.0,id == 2 ? 3.0 : -1.0);
            return {float4(p,0,1),float2((p.x+1)*0.5,(1-p.y)*0.5)};
        }
        fragment float4 flatCloud(V in [[stage_in]],constant U &u [[buffer(0)]]) {
            float a = u.atmosphere.z; return float4(float3(0.18,0.22,0.28)*a,a);
        }
        """
        let library = try await resources.device.makeLibrary(source: source,options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "flatVertex")
        desc.fragmentFunction = library.makeFunction(name: "flatCloud")
        desc.colorAttachments[0].pixelFormat = .rgba16Float
        let flat = try await resources.device.makeRenderPipelineState(descriptor: desc)
        compositor = SceneCompositor(resources: resources,cloudPipeline: flat,useLightCache: false,useCloudHistory: false)
        width = 800; height = 500
        var scene = SceneState.preview(kind: .partlyCloudy,time: .day)
        scene.solar.sunPosition = SIMD2(0.49,0.25); scene.solar.moon.visibility = 0; scene.cloud = 0
        var quiet = RenderPolicy(); quiet.bloom = false
        let clear = try render(scene,resources: resources)
        let clearQuiet = try render(scene,resources: resources,policy: quiet)
        func rgb(_ image: [UInt8], _ uv: SIMD2<Float>) -> [Int] {
            let index = (Int(uv.y*Float(height))*width+Int(uv.x*Float(width)))*4
            return (0..<3).map { Int(image[index+$0]) }
        }
        let halo = scene.solar.sunPosition+SIMD2(0.06,0)
        XCTAssertGreaterThan(zip(rgb(clear,halo),rgb(clearQuiet,halo)).reduce(0) { $0+$1.0-$1.1 },80)
        scene.cloud = 0.35
        let filtered = try render(scene,resources: resources)
        let filteredQuiet = try render(scene,resources: resources,policy: quiet)
        XCTAssertNotEqual(filtered,filteredQuiet,"A passing partly-cloudy layer must keep bloom/diffraction/flares")
        let filteredHalo = zip(rgb(filtered,halo),rgb(filteredQuiet,halo)).reduce(0) { $0+$1.0-$1.1 }
        let clearHalo = zip(rgb(clear,halo),rgb(clearQuiet,halo)).reduce(0) { $0+$1.0-$1.1 }
        XCTAssertGreaterThan(filteredHalo,20,"Retain noticeable glare through a light cloud")
        XCTAssertLessThan(filteredHalo,clearHalo,"The cloud should still attenuate glare")
        func added(_ uv: SIMD2<Float>) -> Int {
            zip(rgb(filtered,uv),rgb(filteredQuiet,uv)).reduce(0) { $0+$1.0-$1.1 }
        }
        func rayUV(_ angle: Float) -> SIMD2<Float> {
            scene.solar.sunPosition+SIMD2(cos(angle)*Float(height)/Float(width),sin(angle))*0.14
        }
        XCTAssertGreaterThan(added(rayUV(.pi/12)),added(rayUV(.pi/4))+4,"Diffraction must survive a passing light cloud, not just bloom")
        XCTAssertGreaterThan(added(SIMD2(0.5,0.5)),6,"Retain the lens-ghost trail through a passing light cloud")
        let capture = ProcessInfo.processInfo.environment["WEATHER_WALLPAPER_WEATHER_SUN_REVIEW"].map { URL(fileURLWithPath: $0) }
        if let capture {
            try writePNG(clear,to: capture.appendingPathComponent("fair-clear-source.png"))
            try writePNG(filtered,to: capture.appendingPathComponent("fair-passing-cloud.png"))
        }
        for kind in [WeatherKind.clear,.windy] {
            var fair = SceneState.preview(kind: kind,time: .day)
            fair.cloud = 0.35; fair.solar = scene.solar
            XCTAssertNotEqual(try render(fair,resources: resources),try render(fair,resources: resources,policy: quiet),"\(kind) must retain optics through a light cloud")
        }
        for kind in [WeatherKind.cloudy,.rain,.snow,.sleet,.thunderstorm,.fog] {
            var gloomy = SceneState.preview(kind: kind,time: .day)
            gloomy.solar = scene.solar; gloomy.cloud = 0.35
            // Isolate condition-level optics with the same transmission/background;
            // zero particle rates must not turn reported rainy weather into glare.
            gloomy.rain = 0; gloomy.snow = 0; gloomy.storm = 0; gloomy.fog = 0
            let disk = try render(gloomy,resources: resources)
            XCTAssertEqual(compositor?.bloomBytes,0,"\(kind) should skip unnecessary sun bloom passes")
            XCTAssertEqual(disk,try render(gloomy,resources: resources,policy: quiet),"\(kind) is disk-only even through the same light cloud")
            XCTAssertGreaterThan(rgb(disk,gloomy.solar.sunPosition).min() ?? 0,245,"Keep the compact transmitted disk white")
            XCTAssertLessThan(rgb(disk,halo).max() ?? 255,220,"No enlarged halo around the gloomy-weather disk")
            if let capture { try writePNG(disk,to: capture.appendingPathComponent("disk-only-\(kind.rawValue).png")) }
            gloomy.cloud = 0
            XCTAssertEqual(try render(gloomy,resources: resources),try render(gloomy,resources: resources,policy: quiet),"A gap in \(kind) must not restore glare")
        }
        scene.cloud = 1
        let opaque = try render(scene,resources: resources)
        scene.solar.sunPosition.y = 2
        XCTAssertEqual(opaque,try render(scene,resources: resources),"A fully opaque cloud still hides the disk")
    }

    @MainActor
    func testWeatherGlarePermissionKeepsUniformLayoutAndDenseFogCulling() {
        func uniform(_ scene: SceneState) -> ShaderUniforms {
            ShaderUniforms(scene: scene,size: CGSize(width: 800,height: 500),seconds: 0,wind: 0)
        }
        XCTAssertEqual(MemoryLayout<ShaderUniforms>.stride,256)
        var fair = SceneState.preview(kind: .partlyCloudy,time: .day)
        XCTAssertEqual(uniform(fair).moonLight.w,1)
        fair.fog = 0.12
        XCTAssertEqual(uniform(fair).moonLight.w,1,"Light haze must not force the plain disk")
        fair.fog = 0.40
        XCTAssertEqual(uniform(fair).moonLight.w,0.5,accuracy: 0.001)
        fair.fog = 0.60
        XCTAssertEqual(uniform(fair).moonLight.w,0)
        fair.fog = 0; fair.rain = 0.3
        XCTAssertEqual(uniform(fair).moonLight.w,0,"Manually tuned rain is also gloomy")
        fair.rain = 0; fair.snow = 0.3
        XCTAssertEqual(uniform(fair).moonLight.w,0)
        fair.snow = 0; fair.storm = 0.3
        XCTAssertEqual(uniform(fair).moonLight.w,0)
    }

    @MainActor
    func testOptionalSunReferenceAndDistantCloudReview() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let output = env["WEATHER_WALLPAPER_SUN_REVIEW"], let baselinePath = env["WEATHER_WALLPAPER_SUN_BASELINE"] else {
            throw XCTSkip("Set WEATHER_WALLPAPER_SUN_REVIEW and WEATHER_WALLPAPER_SUN_BASELINE for reference optics/distance captures")
        }
        let resources = try MetalResources.shared.get()
        let library = try await resources.device.makeLibrary(source: String(contentsOfFile: baselinePath,encoding: .utf8),options: nil)
        func pipeline(_ name: String, format: MTLPixelFormat, volume: Bool = true, towers: Bool = false) async throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: name == "atmosphereComposite" || name == "atmosphereEmission"
                ? "solarAtmosphereVertex" : "atmosphereVertex") ?? library.makeFunction(name: "atmosphereVertex")
            let constants = MTLFunctionConstantValues()
            if name == "volumeCloudFragment" {
                var v = volume, t = towers
                constants.setConstantValue(&v,type: .bool,index: 2); constants.setConstantValue(&t,type: .bool,index: 0)
            }
            descriptor.fragmentFunction = try await library.makeFunction(name: name,constantValues: constants)
            descriptor.colorAttachments[0].pixelFormat = format
            return try await resources.device.makeRenderPipelineState(descriptor: descriptor)
        }
        let oldVolume = try await pipeline("volumeCloudFragment",format: .rgba16Float)
        let oldIce = try await pipeline("volumeCloudFragment",format: .rgba16Float,volume: false)
        let old = SceneCompositor(resources: resources,cloudPipeline: oldVolume,
            convectiveCloudPipeline: try await pipeline("volumeCloudFragment",format: .rgba16Float,towers: true),iceCloudPipeline: oldIce,
            atmospherePipeline: try await pipeline("atmosphereComposite",format: .bgra8Unorm_srgb),
            atmosphereEmissionPipeline: try await pipeline("atmosphereEmission",format: .rgba16Float),useLightCache: false,useCloudHistory: false)
        let current = SceneCompositor(resources: resources,useLightCache: false,useCloudHistory: false)
        compositor = current
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        var reference = SceneState.preview(kind: .clear,time: .day,cloudGenus: .cirrus)
        reference.solar.sunPosition = SIMD2(0.49,0.235); reference.solar.moon.visibility = 0; reference.wind = 0
        var broken = SceneState.preview(kind: .partlyCloudy,time: .day,cloudGenus: .cumulus)
        broken.solar.moon.visibility = 0; broken.wind = 0
        width = 384; height = 240
        let field = try cloudField(broken,resources: resources)
        let candidate = (0..<field.count).filter {
            let uv = SIMD2(Float($0%width)/Float(width),Float($0/width)/Float(height))
            return field[$0].w > 0.3 && field[$0].w < 0.7 && uv.x > 0.25 && uv.x < 0.75 && uv.y > 0.18 && uv.y < 0.55
        }.min {
            func score(_ i: Int) -> Float { abs(Float(i%width)/Float(width)-0.49)+abs(Float(i/width)/Float(height)-0.30) }
            return score($0)<score($1)
        }
        var filtered = broken
        if let candidate { filtered.solar.sunPosition = SIMD2((Float(candidate%width)+0.5)/Float(width),(Float(candidate/width)+0.5)/Float(height)) }
        else { XCTFail("Need a natural cloud-filtered source fixture") }
        var overcast = SceneState.preview(kind: .rain,time: .day); overcast.cloud = 1
        var statistics: [[String: Any]] = []
        for (name,scene,oldPipeline) in [("broken",broken,oldVolume),("cirrus",reference,oldIce),("opaque",overcast,oldVolume)] {
            let before = try cloudField(scene,resources: resources,pipeline: oldPipeline)
            let after = try cloudField(scene,resources: resources)
            func band(_ image: [SIMD4<Float>], from: Float, to: Float) -> (Double,Int) {
                let pixels = image[(Int(Float(height)*from)*width)..<(Int(Float(height)*to)*width)]
                return (pixels.reduce(0) { $0+Double($1.w) }/Double(pixels.count),pixels.filter { $0.w > 0.01 }.count)
            }
            let nearBefore = band(before,from: 0,to: 0.30), nearAfter = band(after,from: 0,to: 0.30)
            let farBefore = band(before,from: 0.48,to: 0.80), farAfter = band(after,from: 0.48,to: 0.80)
            if name == "opaque" {
                XCTAssertTrue(zip(before,after).allSatisfy { $0.w == $1.w },"Do not punch holes into opaque ceilings")
                let error = zip(before,after).map { max(abs($0.x-$1.x),max(abs($0.y-$1.y),abs($0.z-$1.z))) }.max() ?? 0
                XCTAssertLessThanOrEqual(error,0.001,"Only float/half rounding, not a different ceiling light field")
            }
            else {
                XCTAssertLessThan(farAfter.0,farBefore.0)
                XCTAssertLessThan(farAfter.1,farBefore.1,"Remove remote fragments, not just their color")
                XCTAssertEqual(nearBefore.0,nearAfter.0,accuracy: 0.0005)
            }
            statistics.append(["scene": name,"near_alpha_before": nearBefore.0,"near_alpha_after": nearAfter.0,
                "far_alpha_before": farBefore.0,"far_alpha_after": farAfter.0,"far_pixels_before": farBefore.1,"far_pixels_after": farAfter.1])
        }
        width = 2560; height = 1600
        var timing: [[String: Any]] = []
        for (name,scene) in [("reference-cirrus",reference),("broken-clouds",broken),("cloud-filtered-sun",filtered),
                             ("opaque-ceiling",overcast),("sunset",SceneState.preview(kind: .partlyCloudy,time: .dusk)),
                             ("night",SceneState.preview(kind: .partlyCloudy,time: .night))] {
            for efficient in [false,true] {
                var policy = RenderPolicy(); policy.permitsMeteors = false; policy.permitsLightning = false
                if efficient { policy.cloudSteps = 20; policy.cloudDownsample = 4; policy.bloomDownsample = 8 }
                var before: [Double] = [], after: [Double] = []
                for frame in 0..<48 {
                    for previous in (frame%2 == 0 ? [true,false] : [false,true]) {
                        _ = try render(scene,seconds: 19+Float(frame)/30,resources: resources,policy: policy,
                                       baseline: previous ? old : nil,historicalUniforms: false)
                        if frame >= 12 { if previous { before.append(lastGPUTime*1000) } else { after.append(lastGPUTime*1000) } }
                    }
                }
                func stats(_ values: [Double]) -> [String: Double] {
                    let sorted = values.sorted()
                    return ["mean_ms": values.reduce(0,+)/Double(values.count),"p95_ms": sorted[Int(Double(sorted.count-1)*0.95)]]
                }
                timing.append(["scene": name,"efficient": efficient,"before": stats(before),"after": stats(after),
                               "before_bytes": old.allocatedTransientBytes,"after_bytes": current.allocatedTransientBytes])
                XCTAssertEqual(old.allocatedTransientBytes,current.allocatedTransientBytes)
                try writePNG(render(scene,seconds: 19,resources: resources,policy: policy,baseline: old,historicalUniforms: false),
                             to: directory.appendingPathComponent("before-\(name)-\(efficient).png"))
                try writePNG(render(scene,seconds: 19,resources: resources,policy: policy),to: directory.appendingPathComponent("after-\(name)-\(efficient).png"))
            }
        }
        try JSONSerialization.data(withJSONObject: ["device": resources.device.name,"distance": statistics,"timings": timing,
            "notes": "Native fixtures use illustrative source positions, not a city ephemeris override. Horizon bands are a cirrus proxy; deck thinning uses world-space distance. Paired full pipeline includes readback, not sustained energy."],
            options: [.prettyPrinted,.sortedKeys]).write(to: directory.appendingPathComponent("review.json"))
        if env["WEATHER_WALLPAPER_REVIEW_STILLS_ONLY"] == "1" { return }
        width = 1440; height = 900
        var moving = filtered; moving.wind = 0.45
        let movie = try ReviewVideoWriter(url: directory.appendingPathComponent("sun-cloud-edge.mp4"),width: width,height: height,fps: 30)
        for frame in 0..<180 { try await movie.append(render(moving,seconds: 19+Float(frame)/30,resources: resources),frame: frame) }
        try await movie.finish()
    }

    @MainActor
    func testInvisibleSunSkipsBloomButVisibleEdgeAndLightningKeepIt() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        var scene = SceneState.preview(kind: .clear,time: .day)
        scene.fog = 1
        _ = try render(scene,resources: resources)
        XCTAssertEqual(compositor?.bloomBytes,0)
        scene.fog = 0; scene.solar.sunPosition.y = -0.036
        _ = try render(scene,resources: resources)
        XCTAssertEqual(compositor?.bloomBytes,0)
        scene.solar.sunPosition.y = -0.02
        _ = try render(scene,resources: resources)
        XCTAssertGreaterThan(compositor?.bloomBytes ?? 0,0,"Preserve the visible edge aureole")
        scene.fog = 1
        _ = try render(scene,resources: resources,strike: LightningSample(origin: 0.58,seed: 41,intensity: 0.8,reach: 0.90))
        XCTAssertGreaterThan(compositor?.bloomBytes ?? 0,0,"Sun culling must not suppress a live lightning bloom")
    }

    @MainActor
    func testOptionalTraversalAndCloudHistoryOptimizationReview() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let output = env["WEATHER_WALLPAPER_OPTIMIZATION_REVIEW"],
              let baselinePath = env["WEATHER_WALLPAPER_OPTIMIZATION_BASELINE"] else {
            throw XCTSkip("Set WEATHER_WALLPAPER_OPTIMIZATION_REVIEW and WEATHER_WALLPAPER_OPTIMIZATION_BASELINE for paired shader/history review")
        }
        let resources = try MetalResources.shared.get()
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        let library = try await resources.device.makeLibrary(source: String(contentsOfFile: baselinePath,encoding: .utf8),options: nil)
        func oldPipeline(towers: Bool) async throws -> MTLRenderPipelineState {
            let constants = MTLFunctionConstantValues(); var value = towers
            constants.setConstantValue(&value,type: .bool,index: 0)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "atmosphereVertex")
            descriptor.fragmentFunction = try await library.makeFunction(name: "volumeCloudFragment",constantValues: constants)
            descriptor.colorAttachments[0].pixelFormat = .rgba16Float
            return try await resources.device.makeRenderPipelineState(descriptor: descriptor)
        }
        let oldVolume = try await oldPipeline(towers: false), oldConvection = try await oldPipeline(towers: true)
        let old = SceneCompositor(resources: resources,cloudPipeline: oldVolume,
                                  convectiveCloudPipeline: oldConvection,useLightCache: false,useCloudHistory: false)
        let full = SceneCompositor(resources: resources,useLightCache: false,useCloudHistory: false)
        let cached = SceneCompositor(resources: resources,useLightCache: false,useCloudHistory: true)
        let cloudOnly = env["WEATHER_WALLPAPER_REVIEW_CLOUD_ONLY"] == "1"
        width = 2560; height = 1600
        var thin = SceneState.preview(kind: .partlyCloudy,time: .night); thin.cloud = 0.18
        let cirrus = SceneState.preview(kind: .clear,time: .day,cloudGenus: .cirrus)
        let deck = SceneState.preview(kind: .cloudy,time: .day)
        let towers = SceneState.preview(kind: .partlyCloudy,time: .day,cloudDevelopment: .toweringCumulus)
        let storm = SceneState.preview(kind: .thunderstorm,time: .day,cloudDevelopment: .developingThunderstorm)
        func stats(_ values: [Double]) -> [String: Double] {
            guard !values.isEmpty else { return [:] }
            let sorted = values.sorted()
            return ["mean_ms": values.reduce(0,+)/Double(values.count),"median_ms": sorted[sorted.count/2],
                    "p95_ms": sorted[Int(Double(sorted.count-1)*0.95)]]
        }
        func errors(_ a: [UInt8], _ b: [UInt8]) -> [String: Double] {
            var values: [Double] = []
            for i in stride(from: 0,to: a.count,by: 4) {
                for c in 0..<3 { values.append(abs(Double(a[i+c])-Double(b[i+c]))) }
            }
            values.sort()
            return ["mean_display_code_error": values.reduce(0,+)/Double(values.count),
                    "p95_display_code_error": values[Int(Double(values.count-1)*0.95)],"max_display_code_error": values.last ?? 0]
        }
        var report: [[String: Any]] = []
        for (name,scene) in [("towering",towers),("developing",storm),("thin-night",thin),("cirrus",cirrus),("overcast",deck)] where !cloudOnly {
            for efficient in [false,true] {
                var policy = RenderPolicy(); policy.permitsMeteors = false; policy.permitsLightning = false
                if efficient { policy.cloudSteps = 20; policy.cloudDownsample = 4; policy.bloomDownsample = 8 }
                compositor = full
                var before: [Double] = [], after: [Double] = []
                var captureBefore: [UInt8] = [], captureAfter: [UInt8] = []
                for frame in 0..<60 {
                    for baseline in (frame%2 == 0 ? [true,false] : [false,true]) {
                        let image = try render(scene,seconds: 19+Float(frame)/30,resources: resources,policy: policy,
                                               baseline: baseline ? old : nil,historicalUniforms: false)
                        if frame >= 12 {
                            if baseline { before.append(lastGPUTime*1000) } else { after.append(lastGPUTime*1000) }
                        }
                        if frame == 31 { if baseline { captureBefore = image } else { captureAfter = image } }
                    }
                }
                report.append(["mode": "default-traversal","scene": name,"efficient": efficient,
                               "before": stats(before),"after": stats(after),"difference": errors(captureBefore,captureAfter),
                               "transient_bytes": full.allocatedTransientBytes])
                try writePNG(captureBefore,to: directory.appendingPathComponent("before-\(name)-\(efficient).png"))
                try writePNG(captureAfter,to: directory.appendingPathComponent("after-\(name)-\(efficient).png"))
            }
        }
        for (name,scene) in [("cirrus",cirrus),("overcast",deck),("windy",SceneState.preview(kind: .windy,time: .day))] where !cloudOnly {
            for efficient in [false,true] {
                var policy = RenderPolicy(); policy.permitsMeteors = false; policy.permitsLightning = false
                if efficient { policy.cloudSteps = 20; policy.cloudDownsample = 4; policy.bloomDownsample = 8; policy.framesPerSecond = 15 }
                cached.releaseTransientResources(); compositor = cached
                let initialReuses = cached.historyReprojectedFrames
                var before: [Double] = [], after: [Double] = [], freshTimes: [Double] = [], reuseTimes: [Double] = []
                var captureBefore: [UInt8] = [], captureAfter: [UInt8] = []
                for frame in 0..<60 {
                    for baseline in (frame%2 == 0 ? [true,false] : [false,true]) {
                        let reuses = cached.historyReprojectedFrames
                        let image = try render(scene,seconds: 19+Float(frame)/Float(policy.framesPerSecond),resources: resources,policy: policy,
                                               baseline: baseline ? full : nil,historicalUniforms: false)
                        if frame >= 12 {
                            if baseline { before.append(lastGPUTime*1000) }
                            else {
                                after.append(lastGPUTime*1000)
                                if cached.historyReprojectedFrames > reuses { reuseTimes.append(lastGPUTime*1000) }
                                else { freshTimes.append(lastGPUTime*1000) }
                            }
                        }
                        if frame == 31 { if baseline { captureBefore = image } else { captureAfter = image } }
                    }
                }
                report.append(["mode": "opt-in-history","scene": name,"efficient": efficient,
                               "before": stats(before),"after": stats(after),"fresh_frames": stats(freshTimes),"reprojected_frames": stats(reuseTimes),
                               "reuse_count": cached.historyReprojectedFrames-initialReuses,
                               "difference": errors(captureBefore,captureAfter),"history_bytes": cached.historyBytes,
                               "transient_bytes": cached.allocatedTransientBytes])
                try writePNG(captureAfter,to: directory.appendingPathComponent("history-\(name)-\(efficient).png"))
            }
        }
        // Isolate integration without final-sky/bloom/precipitation or a readback.
        // Still subject to other GPU contexts/frequency changes; record all quantiles.
        var cloudTimings: [[String: Any]] = []
        for (name,scene) in [("towering",towers),("developing",storm),("thin-night",thin),("cirrus",cirrus),("overcast",deck)] {
            for efficient in [false,true] {
                var policy = RenderPolicy()
                if efficient { policy.cloudSteps = 20; policy.cloudDownsample = 4 }
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                    width: 2560/policy.cloudDownsample,height: 1600/policy.cloudDownsample,mipmapped: false)
                descriptor.storageMode = .private; descriptor.usage = [.renderTarget]
                let target = try XCTUnwrap(resources.device.makeTexture(descriptor: descriptor))
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = target
                pass.colorAttachments[0].loadAction = .dontCare; pass.colorAttachments[0].storeAction = .store
                var before: [Double] = [], after: [Double] = []
                for frame in 0..<100 {
                    for old in (frame%2 == 0 ? [true,false] : [false,true]) {
                        var u = ShaderUniforms(scene: scene,size: .init(width: 2560,height: 1600),
                            seconds: 19+Double(frame)/30,wind: Double(scene.wind*scene.windDirection)*(19+Double(frame)/30),policy: policy)
                        let command = try XCTUnwrap(resources.queue.makeCommandBuffer())
                        command.label = old ? "Before: isolated cloud pass" : "After: isolated cloud pass"
                        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
                        let convective = u.convection.x > 0.001
                        let pipeline = old ? (convective ? oldConvection : oldVolume) :
                            (convective ? resources.convectiveCloudPipeline : (u.cloudStructure.z <= 0.075 ? resources.iceCloudPipeline : resources.volumeCloudPipeline))
                        encoder.setRenderPipelineState(pipeline)
                        encoder.setFragmentBytes(&u,length: MemoryLayout<ShaderUniforms>.stride,index: 0)
                        encoder.setFragmentTexture(resources.noiseVolume,index: 0)
                        encoder.setFragmentTexture(resources.emptyLightDepth,index: 1)
                        encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 3)
                        encoder.endEncoding()
                        await withCheckedContinuation { (continuation: CheckedContinuation<Void,Never>) in
                            command.addCompletedHandler { _ in continuation.resume() }
                            command.commit()
                        }
                        XCTAssertEqual(command.status,.completed)
                        if frame >= 20 {
                            let ms = (command.gpuEndTime-command.gpuStartTime)*1000
                            if old { before.append(ms) } else { after.append(ms) }
                        }
                    }
                }
                cloudTimings.append(["scene": name,"efficient": efficient,"before": stats(before),"after": stats(after)])
            }
        }
        width = 384; height = 240
        var sampling: [[String: Any]] = []
        for (name,scene) in [("towering",towers),("developing",storm)] {
            for steps in [20,48] {
                var policy = RenderPolicy(); policy.cloudSteps = steps; policy.cloudDownsample = steps == 20 ? 4 : 2
                var referencePolicy = policy; referencePolicy.cloudSteps = 192
                let reference = try cloudField(scene,resources: resources,policy: referencePolicy)
                let before = try cloudField(scene,resources: resources,policy: policy,pipeline: oldConvection)
                let after = try cloudField(scene,resources: resources,policy: policy)
                func rmse(_ image: [SIMD4<Float>]) -> Double {
                    let count = width*Int(Float(height)*0.62)
                    return sqrt((0..<count).reduce(0.0) { $0+pow(Double(image[$1].w-reference[$1].w),2) } / Double(count))
                }
                let b = rmse(before), a = rmse(after)
                XCTAssertLessThanOrEqual(a,b*1.1+0.001,"Faster traversal must retain integration quality against a 192-step reference")
                sampling.append(["scene": name,"steps": steps,"before_opacity_rmse": b,"after_opacity_rmse": a])
            }
        }
        try JSONSerialization.data(withJSONObject: ["device": resources.device.name,"results": report,"cloud_only": cloudTimings,"opacity_sampling": sampling,
            "notes": "Alternating order, same current compositor and full pipeline incl readback. Default comparison uses frozen pre-change cloud shader only. History comparison uses current shader in both paths; fresh and reuse costs separated. Not sustained app energy."],
            options: [.prettyPrinted,.sortedKeys]).write(to: directory.appendingPathComponent("measurements.json"))
        cached.releaseTransientResources()
        if cloudOnly || env["WEATHER_WALLPAPER_REVIEW_STILLS_ONLY"] == "1" { return }
        width = 1440; height = 900
        for (name,scene) in [("cirrus",cirrus),("overcast",deck)] {
            cached.releaseTransientResources(); compositor = cached
            let freshMovie = try ReviewVideoWriter(url: directory.appendingPathComponent("fresh-\(name).mp4"),width: width,height: height,fps: 30)
            let historyMovie = try ReviewVideoWriter(url: directory.appendingPathComponent("history-\(name).mp4"),width: width,height: height,fps: 30)
            for frame in 0..<180 {
                let seconds = Float(19)+Float(frame)/30
                try await freshMovie.append(render(scene,seconds: seconds,resources: resources,baseline: full,historicalUniforms: false),frame: frame)
                try await historyMovie.append(render(scene,seconds: seconds,resources: resources),frame: frame)
            }
            try await freshMovie.finish(); try await historyMovie.finish()
        }
        cached.releaseTransientResources()
    }

    @MainActor
    func testOptInCloudHistoryReconstructsWithoutChangingOutputCadenceOrResourcesUnboundedly() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        let current = SceneCompositor(resources: resources,useLightCache: false,useCloudHistory: true)
        let reference = SceneCompositor(resources: resources,useLightCache: false,useCloudHistory: false)
        compositor = current
        width = 480; height = 300
        var policy = RenderPolicy(); policy.permitsLightning = false; policy.permitsMeteors = false
        for scene in [SceneState.preview(kind: .cloudy,time: .day),.preview(kind: .clear,time: .dusk,cloudGenus: .cirrus)] {
            current.releaseTransientResources()
            let initialReused = current.historyReprojectedFrames
            for frame in 0..<12 {
                let seconds = Float(19)+Float(frame)/30
                let cached = try render(scene,seconds: seconds,resources: resources,policy: policy)
                let fresh = try render(scene,seconds: seconds,resources: resources,policy: policy,baseline: reference,historicalUniforms: false)
                var error: [Double] = []
                for i in stride(from: 0,to: cached.count,by: 4) {
                    for c in 0..<3 { error.append(abs(Double(cached[i+c])-Double(fresh[i+c]))) }
                }
                error.sort()
                XCTAssertLessThan(error.reduce(0,+)/Double(error.count),0.8)
                XCTAssertLessThan(error[Int(Double(error.count)*0.95)],4)
                XCTAssertGreaterThan(current.historyBytes,0)
                XCTAssertLessThanOrEqual(current.historyBytes,16*1024*1024)
                XCTAssertEqual(policy.framesPerSecond,30); XCTAssertEqual(policy.cloudSteps,48); XCTAssertEqual(policy.cloudDownsample,2)
            }
            XCTAssertEqual(current.historyReprojectedFrames-initialReused,6)
        }
        let reused = current.historyReprojectedFrames
        _ = try render(.preview(kind: .thunderstorm,time: .day),seconds: 20,resources: resources)
        XCTAssertEqual(current.historyBytes,0); XCTAssertEqual(current.historyReprojectedFrames,reused)
        width = 640; height = 400
        _ = try render(.preview(kind: .cloudy,time: .day),seconds: 21,resources: resources)
        XCTAssertGreaterThan(current.historyBytes,0)
        policy.animated = false
        _ = try render(.preview(kind: .cloudy,time: .day),seconds: 21,resources: resources,policy: policy)
        XCTAssertEqual(current.historyBytes,0,"Pause/Reduce Motion must release the extra history, not retain unused cache textures")
        current.releaseTransientResources()
        XCTAssertEqual(current.historyBytes,0); XCTAssertEqual(current.allocatedTransientBytes,0)
    }

    @MainActor
    func testConvectiveProfilesRenderWithBoundedResourcesAndContinuousMotion() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        width = 384; height = 240
        var policy = RenderPolicy(); policy.bloom = false; policy.permitsLightning = false; policy.particleScale = 0
        for (development,kind) in [(CloudDevelopment.toweringCumulus,WeatherKind.partlyCloudy),(.developingThunderstorm,.thunderstorm)] {
            for efficient in [false,true] {
                policy.cloudSteps = efficient ? 20 : 48; policy.cloudDownsample = efficient ? 4 : 2
                var scene = SceneState.preview(kind: kind,time: .day,cloudDevelopment: development)
                scene.cloudPresentation!.highFraction = 0.1
                var without = scene; without.cloudPresentation!.convection = .zero
                let base = try render(without,seconds: 19,resources: resources,policy: policy)
                let bytes = compositor!.allocatedTransientBytes
                let towers = try render(scene,seconds: 19,resources: resources,policy: policy)
                XCTAssertEqual(compositor!.allocatedTransientBytes,bytes,"No per-tower target, grid or history")
                XCTAssertEqual(compositor!.lightCacheBytes,0)
                XCTAssertNotEqual(towers,base)
                let next = try render(scene,seconds: 19+1/30,resources: resources,policy: policy)
                let meanChange = zip(towers,next).reduce(0.0) { $0+abs(Double($1.0)-Double($1.1)) } / Double(towers.count)
                XCTAssertLessThan(meanChange,0.8,"Slow evolution must not regenerate or flicker")
            }
            let a = ShaderUniforms(scene: .preview(kind: kind,time: .day,cloudDevelopment: development),
                                  size: CGSize(width: width,height: height),seconds: 3599.999,wind: 1023.999)
            let b = ShaderUniforms(scene: .preview(kind: kind,time: .day,cloudDevelopment: development),
                                  size: CGSize(width: width,height: height),seconds: 3600.001,wind: 1024.001)
            XCTAssertLessThan(abs(sin(a.convection.z)-sin(b.convection.z)),0.0001)
            XCTAssertLessThan(abs(a.convection.w-b.convection.w),0.0001)
            var fog = SceneState.preview(kind: kind,time: .day,cloudDevelopment: development); fog.fog = 1
            XCTAssertEqual(ShaderUniforms(scene: fog,size: .init(width: 384,height: 240),seconds: 0,wind: 0).convection.x,0)
        }
    }

    @MainActor
    func testCirrusIsTranslucentDistinctAndMovesCoherently() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        width = 256; height = 160
        let scene = SceneState.preview(kind: .clear,time: .day,cloudGenus: .cirrus)
        let field = try cloudField(scene,resources: resources)
        XCTAssertGreaterThan(field.map(\.w).max()!,0.001)
        XCTAssertLessThan(field.map(\.w).max()!,0.4)
        XCTAssertGreaterThan(field.filter { $0.w == 0 }.count,field.count/4)
        var outputs: [[UInt8]] = []
        for genus in [CloudGenus.cirrus,.cirrostratus,.cirrocumulus] {
            outputs.append(try render(.preview(kind: .clear,time: .dusk,cloudGenus: genus),seconds: 19,resources: resources))
        }
        XCTAssertNotEqual(outputs[0],outputs[1]); XCTAssertNotEqual(outputs[0],outputs[2])
        let first = try render(scene,seconds: 19,resources: resources)
        let next = try render(scene,seconds: 19+1/30,resources: resources)
        let later = try render(scene,seconds: 199,resources: resources)
        let change = zip(first,next).reduce(0.0) { $0+abs(Double($1.0)-Double($1.1)) } / Double(first.count)
        XCTAssertLessThan(change,0.2)
        XCTAssertNotEqual(first,later)
        var fog = scene; fog.fog = 1
        XCTAssertTrue(try cloudField(fog,resources: resources).allSatisfy { $0 == .zero })
    }

    @MainActor
    func testOpaqueForegroundConcealsDistantTowerAndHighIceOpacity() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        width = 192; height = 120
        var ceiling = SceneState.preview(kind: .rain,time: .day)
        ceiling.cloud = 1
        let foreground = try cloudField(ceiling,resources: resources)
        ceiling.cloudPresentation!.convection = SIMD2(1,0.95)
        ceiling.cloudPresentation!.highFraction = 1
        let combined = try cloudField(ceiling,resources: resources)
        var opaqueCount = 0, error: Float = 0
        for (a,b) in zip(foreground,combined) where a.w > 0.99 {
            opaqueCount += 1; error += abs(a.w-b.w)
        }
        XCTAssertGreaterThan(opaqueCount,width*height/5,"Exercise a real opaque ceiling")
        XCTAssertLessThan(error/Float(max(1,opaqueCount)),0.015,"Towers/ice must not punch holes through opaque foreground")
        for (i,value) in combined.enumerated() {
            XCTAssertTrue(value.x.isFinite && value.y.isFinite && value.z.isFinite && value.w.isFinite)
            XCTAssertGreaterThanOrEqual(value.w,0); XCTAssertLessThanOrEqual(value.w,1)
            if Float(i/width)/Float(height) >= 0.84 { XCTAssertEqual(value,.zero) }
        }
    }

    @MainActor
    func testOptionalConvectiveAndCirrusReview() async throws {
        guard let output = ProcessInfo.processInfo.environment["WEATHER_WALLPAPER_CONVECTION_REVIEW"] else {
            throw XCTSkip("Set WEATHER_WALLPAPER_CONVECTION_REVIEW for native-size captures, motion and paired on/off timings")
        }
        let resources = try MetalResources.shared.get()
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        width = 2560; height = 1600
        let stillsOnly = ProcessInfo.processInfo.environment["WEATHER_WALLPAPER_REVIEW_STILLS_ONLY"] == "1"
        var timing: [[String: Any]] = []
        for (development,kind) in [(CloudDevelopment.toweringCumulus,WeatherKind.partlyCloudy),(.developingThunderstorm,.thunderstorm)] {
            for time in [PreviewTime.day,.dusk,.night] {
                let scene = SceneState.preview(kind: kind,time: time,cloudDevelopment: development)
                try writePNG(render(scene,seconds: 19,resources: resources),to: directory.appendingPathComponent("\(development.rawValue)-\(time.rawValue).png"))
            }
            for efficient in (stillsOnly ? [] : [false,true]) {
                var scene = SceneState.preview(kind: kind,time: .day,cloudDevelopment: development)
                scene.cloudPresentation!.highFraction = 0.1
                var base = scene; base.cloudPresentation!.convection = .zero
                var policy = RenderPolicy()
                if efficient { policy.cloudSteps = 20; policy.cloudDownsample = 4; policy.bloomDownsample = 8 }
                var off: [Double] = [], on: [Double] = []
                for frame in 0..<48 {
                    for enabled in (frame%2 == 0 ? [true,false] : [false,true]) {
                        _ = try render(enabled ? scene : base,seconds: 19+Float(frame)/30,resources: resources,policy: policy)
                        if frame >= 12 {
                            if enabled { on.append(lastGPUTime*1000) } else { off.append(lastGPUTime*1000) }
                        }
                    }
                }
                func stats(_ values: [Double]) -> [String: Double] {
                    let sorted = values.sorted()
                    return ["mean_ms": values.reduce(0,+)/Double(values.count),"median_ms": sorted[sorted.count/2],
                            "p95_ms": sorted[Int(Double(sorted.count-1)*0.95)]]
                }
                timing.append(["profile": development.rawValue,"efficient": efficient,"off": stats(off),"on": stats(on),
                               "transient_bytes": compositor!.allocatedTransientBytes])
            }
        }
        for genus in [CloudGenus.cirrus,.cirrostratus,.cirrocumulus] {
            for time in [PreviewTime.day,.dusk,.night] {
                try writePNG(render(.preview(kind: .clear,time: time,cloudGenus: genus),seconds: 19,resources: resources),
                             to: directory.appendingPathComponent("\(genus.rawValue)-\(time.rawValue).png"))
            }
        }
        if !stillsOnly {
            // Isolate the old/new cirrus field inside otherwise identical CURRENT
            // shaders; do not compare unrelated historical lighting or target sizes.
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            var source = try String(contentsOf: root.appendingPathComponent("Sources/WeatherWallpaper/Resources/Atmosphere.metal"),encoding: .utf8)
            let start = try XCTUnwrap(source.range(of: "float cirrusDensityV2("))
            let end = try XCTUnwrap(source.range(of: "inline __attribute__((always_inline)) float4 integrateCloudsV2",range: start.upperBound..<source.endIndex))
            let fixture = try XCTUnwrap(Bundle.module.url(forResource: "CirrusBefore",withExtension: "metal",subdirectory: "Fixtures"))
            source.replaceSubrange(start.lowerBound..<end.lowerBound,with: try String(contentsOf: fixture,encoding: .utf8))
            let library = try await resources.device.makeLibrary(source: source,options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "atmosphereVertex")
            descriptor.fragmentFunction = try await library.makeFunction(name: "volumeCloudFragment",constantValues: MTLFunctionConstantValues())
            descriptor.colorAttachments[0].pixelFormat = .rgba16Float
            let pipeline = try await resources.device.makeRenderPipelineState(descriptor: descriptor)
            let previous = SceneCompositor(resources: resources,cloudPipeline: pipeline,useLightCache: false)
            let fieldOnly = SceneCompositor(resources: resources,cloudPipeline: resources.volumeCloudPipeline,useLightCache: false,useCloudHistory: false)
            let scene = SceneState.preview(kind: .clear,time: .day,cloudGenus: .cirrus)
            var before: [Double] = [], after: [Double] = []
            for frame in 0..<60 {
                for old in (frame%2 == 0 ? [true,false] : [false,true]) {
                    _ = try render(scene,seconds: 19+Float(frame)/30,resources: resources,
                                   baseline: old ? previous : fieldOnly,historicalUniforms: false)
                    if frame >= 12 {
                        if old { before.append(lastGPUTime*1000) } else { after.append(lastGPUTime*1000) }
                    }
                }
            }
            func stats(_ values: [Double]) -> [String: Double] {
                let sorted = values.sorted()
                return ["mean_ms": values.reduce(0,+)/Double(values.count),"median_ms": sorted[sorted.count/2],
                        "p95_ms": sorted[Int(Double(sorted.count-1)*0.95)]]
            }
            timing.append(["profile": "cirrus-field","before": stats(before),"after": stats(after),
                           "transient_bytes": fieldOnly.allocatedTransientBytes])
            try writePNG(render(scene,seconds: 19,resources: resources,baseline: previous,historicalUniforms: false),
                         to: directory.appendingPathComponent("cirrus-before-day.png"))
        }
        // Both layers in one pass; opacity, not screen ordering, hides the high ice.
        var combined = SceneState.preview(kind: .partlyCloudy,time: .day,cloudDevelopment: .toweringCumulus)
        combined.cloudPresentation!.highFraction = 0.8
        try writePNG(render(combined,seconds: 19,resources: resources),to: directory.appendingPathComponent("combined.png"))
        try JSONSerialization.data(withJSONObject: ["device": resources.device.name,"timings": timing,
            "notes": "Alternating feature-on/off full pipeline, same foreground and resource policy; includes readback, not sustained app energy."],
            options: [.prettyPrinted,.sortedKeys]).write(to: directory.appendingPathComponent("timings.json"))
        if stillsOnly { return }
        width = 1440; height = 900
        for (name,scene) in [("towers",combined),("cirrus",SceneState.preview(kind: .clear,time: .day,cloudGenus: .cirrus))] {
            let movie = try ReviewVideoWriter(url: directory.appendingPathComponent("\(name).mp4"),width: width,height: height,fps: 30)
            for frame in 0..<180 {
                try await movie.append(render(scene,seconds: 19+Float(frame)/30,resources: resources),frame: frame)
            }
            try await movie.finish()
        }
    }

    @MainActor
    func testLightCacheStaysBoundedAndDoesNotChangeCloudSilhouettes() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        let uncached = SceneCompositor(resources: resources,useLightCache: false)
        compositor = SceneCompositor(resources: resources,useLightCache: true)
        width = 960; height = 600
        var policy = RenderPolicy(); policy.bloom = false; policy.particleScale = 0; policy.permitsLightning = false
        for kind in [WeatherKind.cloudy,.rain] {
            for seconds: Float in [11,19] {
                let scene = SceneState.preview(kind: kind,time: .day)
                let cached = try render(scene,seconds: seconds,resources: resources,policy: policy)
                let reference = try render(scene,seconds: seconds,resources: resources,policy: policy,
                                           baseline: uncached,historicalUniforms: false)
                var error: [Double] = []
                for p in stride(from: 0,to: cached.count,by: 4) {
                    for c in 0..<3 { error.append(abs(Double(cached[p+c])-Double(reference[p+c]))) }
                }
                error.sort()
                XCTAssertLessThan(error.reduce(0,+)/Double(error.count),1.5,"Cache must retain the uncached lighting at display precision")
                XCTAssertLessThan(error[Int(Double(error.count)*0.95)],5)
                XCTAssertGreaterThan(compositor?.lightCacheBytes ?? 0,0)
                XCTAssertLessThanOrEqual(compositor?.lightCacheBytes ?? .max,1024*1024)
            }
        }
        _ = try render(.preview(kind: .partlyCloudy,time: .day),resources: resources)
        XCTAssertEqual(compositor?.lightCacheBytes,0,"Sparse skies must not pay for an unhelpful light grid")
        compositor?.releaseTransientResources()
        XCTAssertEqual(compositor?.allocatedTransientBytes,0)
    }

    @MainActor
    func testCloudBottomFadeClearsBothColorAndOpacitySmoothly() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        width = 256; height = 256
        var scene = SceneState.preview(kind: .rain,time: .night)
        scene.cloud = 1
        let pixels = try cloudField(scene,resources: resources)
        var rowMeans: [Float] = []
        for y in 0..<height {
            let uv = (Float(y)+0.5)/Float(height)
            let t = max(0,min(1,(uv-0.62)/0.22))
            let fade = 1-t*t*t*(t*(t*6-15)+10)
            var opacity: Float = 0
            for x in 0..<width {
                let value = pixels[y*width+x]
                XCTAssertLessThanOrEqual(value.w,fade+0.0005)
                if uv >= 0.84 { XCTAssertEqual(value,.zero,"No colored/opaque strip below the fade") }
                opacity += value.w
            }
            rowMeans.append(opacity/Float(width))
        }
        let start = Int(Float(height)*0.66), end = Int(Float(height)*0.84)
        XCTAssertGreaterThan(rowMeans[start],0.20,"Exercise real cloud opacity before the fade, not an empty sky")
        for y in start..<end {
            XCTAssertLessThan(abs(rowMeans[y+1]-rowMeans[y]),0.07,"Fade must not hide a hard lower cutoff")
        }
    }

    @MainActor
    func testUnchangedSceneDoesNotWakeRenderersAgain() {
        let scene = SceneState.preview(kind: .partlyCloudy,time: .day)
        let environment = SceneEnvironment(scene: scene)
        var notifications = 0
        let token = environment.observe { notifications += 1 }
        defer { environment.removeObserver(token) }
        environment.setScene(scene)
        XCTAssertEqual(notifications,0)
        var changed = scene; changed.cloud += 0.1
        environment.setScene(changed)
        XCTAssertEqual(notifications,1)
        environment.setScene(changed)
        XCTAssertEqual(notifications,1)
        environment.setScene(changed,immediate: true)
        XCTAssertEqual(notifications,2,"An explicit still-frame/transition snap must remain possible")
    }

    @MainActor
    func testHiddenPreviewPausesAndResumesWithoutChangingFrameRate() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let scene = SceneEnvironment(scene: .preview(kind: .partlyCloudy,time: .day))
        let view = SkyMetalView(frame: CGRect(x: 0,y: 0,width: 400,height: 260))
        let window = NSWindow(contentRect: view.frame,styleMask: [.borderless],backing: .buffered,defer: false)
        window.contentView = view
        window.orderFront(nil)
        defer { view.stop(); window.orderOut(nil) }
        view.renderer = try WeatherRenderer(view: view,environment: scene)
        view.isHidden = true
        view.renderer?.refreshPolicy()
        XCTAssertTrue(view.isPaused)
        XCTAssertEqual(view.preferredFramesPerSecond,30)
        view.isHidden = false
        view.renderer?.refreshPolicy()
        XCTAssertEqual(view.preferredFramesPerSecond,30)
        if window.occlusionState.contains(.visible) { XCTAssertFalse(view.isPaused) }
    }

    @MainActor
    func testOptionalBandingOptimizationComparison() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let output = env["WEATHER_WALLPAPER_BANDING_REVIEW"],
              let baselinePath = env["WEATHER_WALLPAPER_BANDING_BASELINE"] else {
            throw XCTSkip("Set BANDING_REVIEW and BANDING_BASELINE with WEATHER_WALLPAPER_ prefix for paired current-source comparison")
        }
        let resources = try MetalResources.shared.get()
        let library = try await resources.device.makeLibrary(source: String(contentsOfFile: baselinePath,encoding: .utf8),options: nil)
        func pipeline(_ name: String, format: MTLPixelFormat) async throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: name == "atmosphereComposite" || name == "atmosphereEmission"
                ? "solarAtmosphereVertex" : "atmosphereVertex") ?? library.makeFunction(name: "atmosphereVertex")
            descriptor.fragmentFunction = try await library.makeFunction(name: name,constantValues: MTLFunctionConstantValues())
            descriptor.colorAttachments[0].pixelFormat = format
            return try await resources.device.makeRenderPipelineState(descriptor: descriptor)
        }
        let oldCloud = try await pipeline("volumeCloudFragment",format: .rgba16Float)
        let oldSky = try await pipeline("atmosphereComposite",format: .bgra8Unorm_srgb)
        let oldEmission = try await pipeline("atmosphereEmission",format: .rgba16Float)
        let previous = SceneCompositor(resources: resources,cloudPipeline: oldCloud,
                                       atmospherePipeline: oldSky,atmosphereEmissionPipeline: oldEmission)
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        var metrics: [[String: Any]] = []
        width = 384; height = 240
        for cover: Float in [0.10,0.18,0.28,0.44] {
            var scene = SceneState.preview(kind: .partlyCloudy,time: .night); scene.cloud = cover
            var referencePolicy = RenderPolicy(); referencePolicy.cloudSteps = 192
            let reference = try cloudField(scene,resources: resources,policy: referencePolicy)
            let before = try cloudField(scene,resources: resources,pipeline: oldCloud)
            let after = try cloudField(scene,resources: resources)
            func error(_ image: [SIMD4<Float>]) -> (Double,Double) {
                var square = 0.0, rowSquare = 0.0, count = 0
                // Exclude the independently requested bottom fade from sampling-quality scoring.
                for y in 0..<Int(Float(height)*0.60) {
                    var row = 0.0
                    for x in 0..<width {
                        let delta = Double(image[y*width+x].w-reference[y*width+x].w)
                        square += delta*delta; row += delta; count += 1
                    }
                    rowSquare += pow(row/Double(width),2)
                }
                return (sqrt(square/Double(count)),sqrt(rowSquare/Double(Int(Float(height)*0.60))))
            }
            let b = error(before), a = error(after)
            metrics.append(["coverage": cover,"before_opacity_rmse": b.0,"after_opacity_rmse": a.0,
                            "before_row_error": b.1,"after_row_error": a.1])
            func alphaImage(_ values: [SIMD4<Float>]) -> [UInt8] {
                values.flatMap { pixel -> [UInt8] in
                    let v = UInt8(max(0,min(255,(pixel.w*255).rounded())))
                    return [v,v,v,255]
                }
            }
            try writePNG(alphaImage(before),to: directory.appendingPathComponent("opacity-before-\(cover).png"))
            try writePNG(alphaImage(after),to: directory.appendingPathComponent("opacity-after-\(cover).png"))
            try writePNG(alphaImage(reference),to: directory.appendingPathComponent("opacity-reference-\(cover).png"))
        }
        var timing: [[String: Any]] = []
        width = 2560; height = 1600
        for (name,kind,time,cover) in [("thin-night",WeatherKind.partlyCloudy,PreviewTime.night,Float(0.18)),
                                     ("partly-day",.partlyCloudy,.day,0.44),
                                     ("overcast",.cloudy,.day,0.94),("rain",.rain,.day,0.92),
                                     ("clear-night",.clear,.night,0.06),("battery-thin",.partlyCloudy,.night,0.18)] {
            var scene = SceneState.preview(kind: kind,time: time); scene.cloud = cover
            var policy = RenderPolicy()
            if name == "battery-thin" {
                policy.cloudSteps = 20; policy.cloudDownsample = 4; policy.bloomDownsample = 8
                policy.particleScale = 0.5; policy.permitsLightning = false
            }
            var oldGPU: [Double] = [], newGPU: [Double] = [], oldCPU: [Double] = [], newCPU: [Double] = []
            for frame in 0..<72 {
                for old in (frame % 2 == 0 ? [true,false] : [false,true]) {
                    _ = try render(scene,seconds: 19+Float(frame)/30,resources: resources,policy: policy,
                                   baseline: old ? previous : nil,historicalUniforms: false)
                    if frame >= 16 {
                        if old { oldGPU.append(lastGPUTime*1000); oldCPU.append(lastEncodeTime*1000) }
                        else { newGPU.append(lastGPUTime*1000); newCPU.append(lastEncodeTime*1000) }
                    }
                }
            }
            func stats(_ values: [Double]) -> [String: Double] {
                let sorted = values.sorted()
                return ["mean": values.reduce(0,+)/Double(values.count),"median": sorted[sorted.count/2],
                        "p95": sorted[Int(Double(sorted.count-1)*0.95)]]
            }
            timing.append(["scene": name,"before_gpu_ms": stats(oldGPU),"after_gpu_ms": stats(newGPU),
                           "before_encode_ms": stats(oldCPU),"after_encode_ms": stats(newCPU),
                           "transient_bytes": compositor?.allocatedTransientBytes ?? 0])
            let oldBytes = try render(scene,seconds: 19,resources: resources,policy: policy,baseline: previous,historicalUniforms: false)
            let newBytes = try render(scene,seconds: 19,resources: resources,policy: policy)
            try writePNG(oldBytes,to: directory.appendingPathComponent("before-\(name).png"))
            try writePNG(newBytes,to: directory.appendingPathComponent("after-\(name).png"))
        }
        let report: [String: Any] = ["device": resources.device.name,"sampling": metrics,"timings": timing,
            "notes": "Alternating-order same-source full-pipeline comparison; includes readback, not sustained app energy. Encode timings use the same descriptor-reuse code in both paths."]
        try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys]).write(to: directory.appendingPathComponent("comparison.json"))
    }

    @MainActor
    func testCloudFloatTargetHasExactEmptyOutputAndBoundedOpacity() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        let size = 64, rowBytes = 64 * 8
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,width: size,height: size,mipmapped: false)
        desc.storageMode = .private; desc.usage = [.shaderRead,.renderTarget]
        let target = try XCTUnwrap(resources.device.makeTexture(descriptor: desc))
        let readback = try XCTUnwrap(resources.device.makeBuffer(length: rowBytes * size,options: .storageModeShared))
        for kind in [WeatherKind.clear,.partlyCloudy,.rain,.fog] {
            let scene = SceneState.preview(kind: kind,time: .night)
            var uniforms = ShaderUniforms(scene: scene,size: CGSize(width: size,height: size),seconds: 19,wind: 0)
            let command = try XCTUnwrap(resources.queue.makeCommandBuffer())
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
            encoder.setRenderPipelineState(resources.volumeCloudPipeline)
            encoder.setFragmentBytes(&uniforms,length: MemoryLayout<ShaderUniforms>.stride,index: 0)
            encoder.setFragmentTexture(resources.noiseVolume,index: 0)
            encoder.setFragmentTexture(resources.emptyLightDepth,index: 1)
            encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 3)
            encoder.endEncoding()
            let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
            blit.copy(from: target,sourceSlice: 0,sourceLevel: 0,sourceOrigin: MTLOrigin(),
                      sourceSize: MTLSize(width: size,height: size,depth: 1),to: readback,destinationOffset: 0,
                      destinationBytesPerRow: rowBytes,destinationBytesPerImage: rowBytes * size)
            blit.endEncoding()
            await withCheckedContinuation { continuation in
                command.addCompletedHandler { _ in continuation.resume() }
                command.commit()
            }
            XCTAssertEqual(command.status,.completed)
            let values = readback.contents().assumingMemoryBound(to: UInt16.self)
            for pixel in 0..<(size*size) {
                for channel in 0..<4 {
                    let value = Float(Float16(bitPattern: values[pixel*4+channel]))
                    XCTAssertTrue(value.isFinite); XCTAssertGreaterThanOrEqual(value,0)
                    if channel == 3 { XCTAssertLessThanOrEqual(value,1) }
                    if kind == .clear { XCTAssertEqual(value,0,"Empty volume must not contain color or opacity dither") }
                }
            }
        }
    }

    @MainActor
    func testRecoveryDesktopCapturesAndMeteorMotionWhenRequested() async throws {
        guard let output = ProcessInfo.processInfo.environment["WEATHER_WALLPAPER_RECOVERY_OUTPUT"] else {
            throw XCTSkip("Set WEATHER_WALLPAPER_RECOVERY_OUTPUT for native-size recovery captures and meteor movie")
        }
        let resources = try MetalResources.shared.get()
        width = 2560; height = 1600
        for kind in [WeatherKind.partlyCloudy,.cloudy,.rain] {
            for time in [PreviewTime.day,.night] {
                let scene = SceneState.preview(kind: kind,time: time)
                try writePNG(render(scene,seconds: 19,resources: resources),
                    to: URL(fileURLWithPath: output).appendingPathComponent("desktop-\(kind.rawValue)-\(time.rawValue).png"))
            }
        }
        width = 1440; height = 900
        let night = SceneState.preview(kind: .clear,time: .night)
        for fps in [15,30,60] {
            let url = URL(fileURLWithPath: output).appendingPathComponent("meteor-\(fps)fps.mp4")
            let video = try ReviewVideoWriter(url: url,width: width,height: height,fps: fps)
            var policy = RenderPolicy(); policy.framesPerSecond = fps
            for frame in 0..<(fps*8) {
                let bytes = try render(night,seconds: Float(frame)/Float(fps),resources: resources,policy: policy)
                try await video.append(bytes,frame: frame)
            }
            try await video.finish()
        }
    }

    @MainActor
    func testAllWeatherAndTimeCombinationsRenderOnGPU() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is unavailable on this host") }
        let resources = try MetalResources.shared.get()
        XCTAssertEqual(MemoryLayout<ShaderUniforms>.stride, 256)
        for kind in WeatherKind.allCases {
            for time in PreviewTime.allCases {
                let bytes = try render(.preview(kind: kind, time: time), seconds: 19, resources: resources)
                let luminance = meanLuminance(bytes)
                XCTAssertGreaterThan(luminance, 2, "\(kind) \(time) is black")
                XCTAssertLessThan(luminance, 253, "\(kind) \(time) is blown out")
                if let path = ProcessInfo.processInfo.environment["WEATHER_WALLPAPER_RENDER_OUTPUT"] {
                    try writePNG(bytes, to: URL(fileURLWithPath: path)
                        .appendingPathComponent("\(kind.rawValue)-\(time.rawValue).png"))
                }
            }
        }
    }

    @MainActor
    func testDayNightAndAnimatedPrecipitationDiffer() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is unavailable on this host") }
        let resources = try MetalResources.shared.get()
        let day = try render(.preview(kind: .clear, time: .day), resources: resources)
        let night = try render(.preview(kind: .clear, time: .night), resources: resources)
        XCTAssertGreaterThan(meanLuminance(day), meanLuminance(night) * 2)
        for kind in [WeatherKind.rain, .snow, .thunderstorm, .partlyCloudy] {
            let scene = SceneState.preview(kind: kind, time: .day)
            let first = try render(scene, seconds: 1, resources: resources)
            let second = try render(scene, seconds: 3, resources: resources)
            XCTAssertNotEqual(first, second, "\(kind) does not animate")
        }
    }

    @MainActor
    func testPolicyFreezesAndResumesAnimationClock() async {
        let environment = SceneEnvironment(scene: .preview(kind: .rain, time: .day))
        var policy = RenderPolicy()
        policy.animated = false
        environment.setPolicy(policy)
        let frozen = environment.animationTime(at: ProcessInfo.processInfo.systemUptime)
        XCTAssertEqual(frozen, environment.animationTime(at: ProcessInfo.processInfo.systemUptime + 100))
        policy.animated = true
        environment.setPolicy(policy)
        let now = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(environment.animationTime(at: now + 2) - environment.animationTime(at: now), 2, accuracy: 0.001)
        policy.suspended = true
        environment.setPolicy(policy)
        XCTAssertEqual(environment.animationTime(at: now), environment.animationTime(at: now + 100))
    }

    @MainActor
    func testWindChangeDoesNotMultiplyByPlaybackUptime() async {
        let scene = SceneState.preview(kind: .windy, time: .day)
        let environment = SceneEnvironment(scene: scene)
        let now = ProcessInfo.processInfo.systemUptime
        _ = environment.windOffset(at: now + 7200, scene: scene)
        var changed = scene
        changed.windDirection = -1
        let before = environment.windOffset(at: now + 7200.01, scene: scene)
        let after = environment.windOffset(at: now + 7200.02, scene: changed)
        XCTAssertLessThan(abs(after - before), 0.02)
    }

    @MainActor
    func testDetachedRendererIsPausedBoundedAndReleased() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is unavailable on this host") }
        let environment = SceneEnvironment(scene: .preview(kind: .snow, time: .day))
        var policy = RenderPolicy()
        policy.maximumDimension = 800
        environment.setPolicy(policy)
        let view = SkyMetalView(frame: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        view.renderer = try WeatherRenderer(view: view, environment: environment)
        let releasedRenderer = { [weak renderer = view.renderer] in renderer }
        XCTAssertTrue(view.isPaused, "A detached / invisible view must not run a render loop")
        XCTAssertEqual(view.drawableSize, CGSize(width: 800, height: 500))
        view.stop()
        XCTAssertNil(view.delegate)
        XCTAssertNil(releasedRenderer(), "The shared environment must not retain a dismantled renderer")
        environment.setScene(.preview(kind: .rain, time: .night))
    }

    @MainActor
    func testFullResolutionStormRenderCompletes() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is unavailable on this host") }
        let resources = try MetalResources.shared.get()
        width = 2560
        height = 1600
        var timings: [Double] = []
        for frame in 0..<15 {
            let seconds = Float(18) + Float(frame) / 30
            _ = try render(.preview(kind: .thunderstorm, time: .dusk), seconds: seconds, resources: resources)
            if frame >= 3 { timings.append(lastGPUTime) }
        }
        if ProcessInfo.processInfo.environment["WEATHER_WALLPAPER_GPU_TIMING"] == "1" {
            let milliseconds = timings.reduce(0, +) / Double(timings.count) * 1000
            let p95 = timings.sorted()[Int(Double(timings.count - 1) * 0.95)] * 1000
            print("\(resources.device.name): 2560×1600 storm + readback, mean \(String(format: "%.2f", milliseconds)) ms, p95 \(String(format: "%.2f", p95)) ms; transient \(compositor?.allocatedTransientBytes ?? 0) bytes")
        }
    }

    @MainActor
    func testOptionalCloudProfileBenchmark() async throws {
        guard let path = ProcessInfo.processInfo.environment["WEATHER_WALLPAPER_BENCHMARK_OUTPUT"] else {
            throw XCTSkip("Set WEATHER_WALLPAPER_BENCHMARK_OUTPUT to record controlled cloud timings")
        }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        let baselineURL = try XCTUnwrap(Bundle.module.url(forResource: "CloudBaseline",withExtension: "metal",subdirectory: "Fixtures"))
        let library = try await resources.device.makeLibrary(source: String(contentsOf: baselineURL,encoding: .utf8),options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "baselineVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "baselineClouds")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        let pipeline = try await resources.device.makeRenderPipelineState(descriptor: descriptor)
        let baseline = SceneCompositor(resources: resources,cloudPipeline: pipeline)
        var rows: [[String: Any]] = []
        for mode in ["normal", "battery", "ultrawide"] {
            width = mode == "battery" ? 1920 : 2560
            height = mode == "battery" ? 1200 : (mode == "ultrawide" ? 1072 : 1600)
            var policy = RenderPolicy()
            if mode == "battery" {
                policy.cloudSteps = 20; policy.cloudDownsample = 4
                policy.bloomDownsample = 8; policy.particleScale = 0.5; policy.permitsLightning = false
            }
            for kind in [WeatherKind.clear, .partlyCloudy, .cloudy, .rain, .thunderstorm] {
                var timings: [Double] = []
                var reference: [Double] = []
                let scene = SceneState.preview(kind: kind, time: .day)
                for frame in 0..<64 {
                    // Alternate order to reduce thermal/frequency/other-app bias between paths.
                    for previous in (frame % 2 == 0 ? [true,false] : [false,true]) {
                        _ = try render(scene,seconds: 18 + Float(frame) / 30,resources: resources,policy: policy,
                                       baseline: previous ? baseline : nil)
                        if frame >= 16 {
                            if previous { reference.append(lastGPUTime * 1000) }
                            else { timings.append(lastGPUTime * 1000) }
                        }
                    }
                }
                let sorted = timings.sorted()
                let referenceSorted = reference.sorted()
                let average = timings.reduce(0,+) / Double(timings.count)
                let previousAverage = reference.reduce(0,+) / Double(reference.count)
                rows.append(["mode": mode, "scene": kind.rawValue,
                    "mean_ms": average, "baseline_mean_ms": previousAverage,
                    "change_percent": (average / previousAverage - 1) * 100,
                    "baseline_median_ms": referenceSorted[referenceSorted.count / 2],
                    "baseline_p95_ms": referenceSorted[Int(Double(referenceSorted.count - 1) * 0.95)],
                    "median_ms": sorted[sorted.count / 2], "p95_ms": sorted[Int(Double(sorted.count - 1) * 0.95)],
                    "transient_bytes": compositor?.allocatedTransientBytes ?? 0])
            }
        }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["device": resources.device.name, "cases": rows], options: [.prettyPrinted, .sortedKeys]).write(to: url)
        print("Cloud benchmark: \(url.path)")
    }

    @MainActor
    func testPhotographicMoonRendersAllPhasesByDayAndNight() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is unavailable on this host") }
        let resources = try MetalResources.shared.get()
        for time in [PreviewTime.day, .night] {
            var images: [[UInt8]] = []
            for phase in PreviewMoonPhase.allCases {
                let scene = SceneState.preview(kind: .clear, time: time, moonPhase: phase)
                let bytes = try render(scene, resources: resources)
                images.append(bytes)
                if let path = ProcessInfo.processInfo.environment["WEATHER_WALLPAPER_RENDER_OUTPUT"] {
                    try writePNG(bytes, to: URL(fileURLWithPath: path).appendingPathComponent("moon-\(phase.rawValue)-\(time.rawValue).png"))
                }
            }
            XCTAssertNotEqual(images[0], images[4], "New and full moons must not look the same")
            XCTAssertNotEqual(images[2], images[6], "Waxing and waning quarters must illuminate opposite limbs")
            XCTAssertNotEqual(images[1], images[3], "Crescent and gibbous phases must differ")
        }
    }

    @MainActor
    func testLightSuppressionIsAppliedToEveryRenderPass() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is unavailable on this host") }
        let resources = try MetalResources.shared.get()
        let storm = SceneState.preview(kind: .thunderstorm, time: .night)
        let lit = try render(storm, resources: resources)
        var policy = RenderPolicy()
        policy.permitsLightning = false
        policy.bloom = false
        let quiet = try render(storm, resources: resources, policy: policy)
        XCTAssertGreaterThan(meanLuminance(lit), meanLuminance(quiet))
        let uniforms = ShaderUniforms(scene: storm, size: CGSize(width: 800, height: 500), seconds: 0, wind: 0,
                                     policy: policy, strike: LightningSample(intensity: 1))
        XCTAssertEqual(uniforms.lightning.z, 0)
        XCTAssertEqual(uniforms.options.y, 0)
        XCTAssertEqual(uniforms.options.w, 0)
    }

    @MainActor
    func testLongRunningClocksKeepFramePrecisionAndDoNotResetAtMidnight() async {
        let scene = SceneState.preview(kind: .snow, time: .night)
        let environment = SceneEnvironment(scene: scene)
        let now = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(environment.animationTime(at: now + 86401) - environment.animationTime(at: now + 86399), 2, accuracy: 0.001)
        let month = 31.0 * 86400 + 0.125
        let first = ShaderUniforms(scene: scene, size: CGSize(width: 800, height: 500), seconds: month, wind: 1_000_000.125)
        let next = ShaderUniforms(scene: scene, size: CGSize(width: 800, height: 500), seconds: month + 1 / 30.0, wind: 1_000_000.13)
        XCTAssertLessThan(first.viewport.z, 3600)
        XCTAssertLessThan(abs(first.options.z), 1024)
        XCTAssertEqual(next.viewport.z - first.viewport.z, 1 / 30.0, accuracy: 0.0001)
        XCTAssertGreaterThan(first.clock.x, 86400)
    }

    @MainActor
    func testBatteryBloomStillExistsWithoutFullSizeBuffers() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is unavailable on this host") }
        let resources = try MetalResources.shared.get()
        let scene = SceneState.preview(kind: .clear, time: .day)
        var economical = RenderPolicy()
        economical.bloomDownsample = 8
        economical.framesPerSecond = 15
        let lit = try render(scene, resources: resources, policy: economical)
        economical.bloom = false
        let unlit = try render(scene, resources: resources, policy: economical)
        XCTAssertGreaterThan(meanLuminance(lit), meanLuminance(unlit))
        let uniforms = ShaderUniforms(scene: scene, size: CGSize(width: width, height: height),
                                     seconds: 0, wind: 0, policy: economical)
        XCTAssertEqual(uniforms.clock.w, 8)
        XCTAssertEqual(uniforms.options.w, 0)
        XCTAssertEqual(resources.cloudAtlas.width, 1536, "More cloud variations must not enlarge the atlas")
        XCTAssertEqual(resources.moonAlbedo.width, 2048, "Moon sharpness is a rendering fix, not a texture-size increase")
    }

    @MainActor
    func testPreviewMeteorDemoRendersAndSpeedReachesTheShader() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        width = 960; height = 600
        var night = SceneState.preview(kind: .clear, time: .night)
        night.cloud = 0; night.wind = 0
        let cycle = try XCTUnwrap((0..<20).first { MeteorAppearance.sample(at: Double($0)*7+0.3,aspect: 1.6) != nil })
        for speed: Float in [0.25,1,2.5] {
            var policy = RenderPolicy(); policy.meteorSpeed = speed
            var centroids: [SIMD2<Double>] = []
            for (index,progress) in [0.25,0.55].enumerated() {
                let seconds = Float(cycle)*7 + 0.18 + 0.65/speed * Float(progress)
                let bytes = try render(night,seconds: seconds,resources: resources,policy: policy)
                policy.permitsMeteors = false
                let control = try render(night,seconds: seconds,resources: resources,policy: policy)
                policy.permitsMeteors = true
                var mass = 0.0, x = 0.0, y = 0.0, red = 0.0, blue = 0.0
                for p in stride(from: 0,to: bytes.count,by: 4) {
                    let r = max(0,Double(bytes[p+2])-Double(control[p+2]))
                    let b = max(0,Double(bytes[p])-Double(control[p]))
                    if r > 3 {
                        mass += r; x += Double(p/4 % width)*r; y += Double(p/4 / width)*r
                        red += r; blue += b
                    }
                }
                XCTAssertGreaterThan(mass,20,"Meteor-only pixels must render, not merely a twinkling star field")
                XCTAssertGreaterThan(red,blue,"Train must remain warm rather than blue")
                centroids.append(SIMD2(x/max(1,mass),y/max(1,mass)))
                if let path = ProcessInfo.processInfo.environment["WEATHER_WALLPAPER_RENDER_OUTPUT"] {
                    try writePNG(bytes,to: URL(fileURLWithPath: path).appendingPathComponent("meteor-\(speed)-\(index).png"))
                }
            }
            let delta = centroids[1]-centroids[0]
            XCTAssertLessThan(delta.x,-10); XCTAssertGreaterThan(delta.y,10)
            XCTAssertEqual(-delta.x,delta.y,accuracy: 5,"Movement and train use identical pixel coordinates")
        }
        var stopped = RenderPolicy(); stopped.animated = false
        let still = try render(night,seconds: Float(cycle)*7+0.4,resources: resources,policy: stopped)
        stopped.permitsMeteors = false
        XCTAssertEqual(still,try render(night,seconds: Float(cycle)*7+0.4,resources: resources,policy: stopped))
    }

    @MainActor
    func testFullMoonRetainsPhotographicContrastInsteadOfClippingWhite() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is unavailable on this host") }
        let resources = try MetalResources.shared.get()
        // Check photographic contrast across the enlarged lunar disk.
        width = 1600; height = 1000
        let scene = SceneState.preview(kind: .clear, time: .night, moonPhase: .fullMoon)
        let bytes = try render(scene, resources: resources)
        let centerX = Double(scene.solar.moon.position.x) * Double(width)
        let centerY = Double(scene.solar.moon.position.y) * Double(height)
        let radius = Double(height) * Double(SkyOptics.moonRadius) * 0.72
        var values: [Double] = []
        for y in max(0, Int(centerY - radius))...min(height - 1, Int(centerY + radius)) {
            for x in max(0, Int(centerX - radius))...min(width - 1, Int(centerX + radius)) {
                guard hypot(Double(x) - centerX, Double(y) - centerY) < radius else { continue }
                let index = (y * width + x) * 4
                values.append(Double(bytes[index]) * 0.0722 + Double(bytes[index + 1]) * 0.7152 + Double(bytes[index + 2]) * 0.2126)
            }
        }
        XCTAssertGreaterThan(values.count, 100)
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        XCTAssertGreaterThan(sqrt(variance), 8, "Lunar maria and highlands should remain distinguishable")
        XCTAssertLessThan(mean, 240, "Exposure must not turn the full moon into a flat white disk")
    }

    @MainActor
    func testMoonIsFiftyPercentLargerWithoutChangingTheSun() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        width = 1600; height = 1000
        func diameter(_ bytes: [UInt8], at center: SIMD2<Float>) -> Int {
            let x = Int(center.x * Float(width)), y = Int(center.y * Float(height))
            let range = Int(Float(height) * SkyOptics.moonRadius * 2)
            func luminance(_ dx: Int) -> Double {
                let index = (y * width + x + dx) * 4
                return Double(bytes[index]) * 0.0722 + Double(bytes[index + 1]) * 0.7152 + Double(bytes[index + 2]) * 0.2126
            }
            let background = (luminance(-range) + luminance(range)) / 2
            let peak = (-2...2).map(luminance).max() ?? background
            let threshold = background + (peak - background) * 0.45
            let disk = (-range...range).filter { luminance($0) > threshold }
            return (disk.last ?? 0) - (disk.first ?? 0) + 1
        }
        for hybrid in [true, false] {
            var policy = RenderPolicy()
            policy.bloom = false; policy.volumetricClouds = hybrid
            var day = SceneState.preview(kind: .clear, time: .day)
            day.cloud = 0; day.solar.moon.visibility = 0
            var night = SceneState.preview(kind: .clear, time: .night, moonPhase: .fullMoon)
            night.cloud = 0
            let sun = try render(day, resources: resources, policy: policy)
            let moon = try render(night, resources: resources, policy: policy)
            let sunDiameter = diameter(sun, at: day.solar.sunPosition)
            let moonDiameter = diameter(moon, at: night.solar.moon.position)
            XCTAssertEqual(Double(sunDiameter),Double(height)*Double(SkyOptics.bodyRadius)*2,accuracy: 3,"Leave the sun unchanged")
            XCTAssertEqual(Double(moonDiameter),Double(sunDiameter)*1.5,accuracy: 3,"Enlarge lunar diameter, not brightness")
            XCTAssertEqual(Double(moonDiameter),Double(height)*Double(SkyOptics.moonRadius)*2,accuracy: 3)
        }
    }

    @MainActor
    func testSunHasVisibleBloomAndSourceOccludedLensFlares() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        var scene = SceneState.preview(kind: .clear, time: .day)
        scene.cloud = 0
        var policy = RenderPolicy()
        let lit = try render(scene, resources: resources, policy: policy)
        policy.bloom = false
        let quiet = try render(scene, resources: resources, policy: policy)
        func delta(at uv: SIMD2<Float>) -> Int {
            let x = Int(uv.x * Float(width)), y = Int(uv.y * Float(height))
            let index = (y * width + x) * 4
            return (0..<3).reduce(0) { $0 + Int(lit[index + $1]) - Int(quiet[index + $1]) }
        }
        XCTAssertGreaterThan(delta(at: scene.solar.sunPosition + SIMD2(0,0.045)), 8, "Bloom must extend visibly beyond the disk")
        let ghost = scene.solar.sunPosition + (SIMD2<Float>(repeating: 0.5) - scene.solar.sunPosition) * 1.35
        XCTAssertGreaterThan(delta(at: ghost), 3, "Lens ghosts must remain visible away from the sun's glow")

        scene.solar.sunPosition.y = 2
        policy.bloom = true
        let hidden = try render(scene, resources: resources, policy: policy)
        policy.bloom = false
        XCTAssertEqual(hidden, try render(scene, resources: resources, policy: policy), "An off-screen sun must not leave flares behind")
    }

    func testVisualWindSpeedIncreasesWithoutChangingWeatherMeasurements() {
        let scene = SceneState.preview(kind: .windy, time: .day)
        let uniforms = ShaderUniforms(scene: scene, size: CGSize(width: 960, height: 600), seconds: 0, wind: 100)
        XCTAssertEqual(Double(uniforms.clock.y + uniforms.options.z), 135, accuracy: 0.001)
        XCTAssertEqual(uniforms.weather.w, scene.wind)
        XCTAssertEqual(uniforms.rendering.w, SkyOptics.bodyRadius)
    }

    @MainActor
    func testCelestialMotionInterpolatesThroughoutRefreshWindow() async {
        let start = SolarState.preview(.night)
        var end = start
        end.moon.position.x += 0.02
        let environment = SceneEnvironment(scene: .preview(kind: .clear, time: .night))
        let now = ProcessInfo.processInfo.systemUptime
        environment.setSolarMotion(from: start, to: end, at: now)
        let a = environment.scene(at: now + 30).solar.moon.position.x
        let b = environment.scene(at: now + 31).solar.moon.position.x
        XCTAssertGreaterThan(b, a)
        XCTAssertEqual(a, start.moon.position.x + 0.005, accuracy: 0.0001)
        var policy = RenderPolicy()
        policy.animated = false
        environment.setPolicy(policy)
        XCTAssertEqual(environment.scene(at: now + 31).solar, start)
    }

    @MainActor
    func testCloudDensityChangesWithoutPrecipitationParticlesOrLightning() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is unavailable on this host") }
        let resources = try MetalResources.shared.get()
        var policy = RenderPolicy()
        policy.particleScale = 0
        policy.permitsLightning = false
        policy.bloom = false
        var scene = SceneState.preview(kind: .partlyCloudy, time: .day)
        let dry = try render(scene, resources: resources, policy: policy)
        scene.rain = 0.6
        let rain = try render(scene, resources: resources, policy: policy)
        scene.storm = 1
        let thunder = try render(scene, resources: resources, policy: policy)
        XCTAssertNotEqual(dry, rain)
        XCTAssertNotEqual(rain, thunder)
        XCTAssertLessThan(meanLuminance(thunder), meanLuminance(rain))
    }

    @MainActor
    func testOpaqueWeatherKeepsSubtleCloudCeilingDetail() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        var policy = RenderPolicy()
        policy.particleScale = 0; policy.permitsLightning = false; policy.bloom = false
        for kind in [WeatherKind.cloudy, .rain, .thunderstorm] {
            var scene = SceneState.preview(kind: kind, time: .day)
            scene.solar.moon.visibility = 0
            let bytes = try render(scene, resources: resources, policy: policy)
            let row = height / 4
            let values = (width / 10..<width * 9 / 10).map { x -> Double in
                let index = (row * width + x) * 4
                return Double(bytes[index]) * 0.0722 + Double(bytes[index + 1]) * 0.7152 + Double(bytes[index + 2]) * 0.2126
            }
            let mean = values.reduce(0,+) / Double(values.count)
            let spread = sqrt(values.reduce(0) { $0 + pow($1 - mean,2) } / Double(values.count))
            XCTAssertGreaterThan(spread, 1, "\(kind) should retain visible shading, not a flat fill")
            XCTAssertLessThan(spread, 24, "\(kind) ceiling detail should remain subdued")
        }
    }

    @MainActor
    func testCirrusIsAnIndependentDistantLayer() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is unavailable on this host") }
        let resources = try MetalResources.shared.get()
        var scene = SceneState.preview(kind: .clear, time: .day)
        scene.cloud = 0
        // Isolate cloud scattering: filtering the sun now intentionally reduces
        // the clear-sky glare, so total bloom-on image brightness is not this test.
        var policy = RenderPolicy(); policy.bloom = false
        let empty = try render(scene, resources: resources,policy: policy)
        let cirrus = try render(scene, resources: resources,policy: policy,cloudLayers: SIMD4(0, 1, 0, 1))
        XCTAssertNotEqual(empty, cirrus)
        XCTAssertGreaterThan(meanLuminance(cirrus), meanLuminance(empty))
        if let path = ProcessInfo.processInfo.environment["WEATHER_WALLPAPER_RENDER_OUTPUT"] {
            try writePNG(cirrus, to: URL(fileURLWithPath: path).appendingPathComponent("cirrus-only-day.png"))
        }
    }

    @MainActor
    func testAllResearchedCloudFamiliesRenderDistinctCompatiblePreviews() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        var highClouds: [[UInt8]] = []
        for genus in CloudGenus.allCases {
            let kind = try XCTUnwrap(WeatherKind.allCases.first { CloudGenus.eligiblePreviews(for: $0).contains(genus) })
            let scene = SceneState.preview(kind: kind,time: .day,cloudGenus: genus)
            let bytes = try render(scene, seconds: 19, resources: resources)
            XCTAssertGreaterThan(meanLuminance(bytes),20)
            XCTAssertLessThan(meanLuminance(bytes),250)
            if [.cirrus,.cirrocumulus,.cirrostratus].contains(genus) { highClouds.append(bytes) }
            if let path = ProcessInfo.processInfo.environment["WEATHER_WALLPAPER_RENDER_OUTPUT"] {
                try writePNG(bytes,to: URL(fileURLWithPath: path).appendingPathComponent("family-\(genus.rawValue).png"))
            }
        }
        XCTAssertEqual(highClouds.count,3)
        XCTAssertNotEqual(highClouds[0],highClouds[1])
        XCTAssertNotEqual(highClouds[1],highClouds[2])
    }

    @MainActor
    func testHighCloudsDisappearBehindOpaqueRainAndDenseFog() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        var scene = SceneState.preview(kind: .rain,time: .day)
        scene.cloud = 1
        var policy = RenderPolicy()
        policy.particleScale = 0; policy.permitsLightning = false; policy.bloom = false
        let withoutUpper = try render(scene,resources: resources,policy: policy)
        var profile = try XCTUnwrap(scene.cloudPresentation)
        profile.highFraction = 1; profile.upperStyle = SIMD3(0,1,0)
        scene.cloudPresentation = profile
        let withUpper = try render(scene,resources: resources,policy: policy)
        let roofBytes = width * (height / 2) * 4
        var difference = 0.0
        for index in stride(from: 0,to: roofBytes,by: 4) {
            for channel in 0..<3 { difference += abs(Double(withUpper[index + channel]) - Double(withoutUpper[index + channel])) }
        }
        XCTAssertLessThan(difference / Double(roofBytes / 4 * 3),0.1, "Opaque low clouds must conceal high ripples")

        scene.fog = 1
        let fogWithUpper = try render(scene,resources: resources,policy: policy)
        profile.highFraction = 0; scene.cloudPresentation = profile
        XCTAssertEqual(fogWithUpper,try render(scene,resources: resources,policy: policy))
    }

    @MainActor
    func testLightningRemainsVisibleNearTheBottomOfTheWallpaper() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is unavailable on this host") }
        let resources = try MetalResources.shared.get()
        let scene = SceneState.preview(kind: .thunderstorm, time: .night)
        let lit = try render(scene, resources: resources)
        var policy = RenderPolicy()
        policy.permitsLightning = false
        let quiet = try render(scene, resources: resources, policy: policy)
        let bottom = Int(Double(height) * 0.84) * width * 4
        let brighterPixels = stride(from: bottom, to: lit.count, by: 4).filter {
            Int(lit[$0]) + Int(lit[$0 + 1]) + Int(lit[$0 + 2]) > Int(quiet[$0]) + Int(quiet[$0 + 1]) + Int(quiet[$0 + 2]) + 90
        }.count
        XCTAssertGreaterThan(brighterPixels, 20, "Long bolts should emerge in clear spaces near the Dock")
    }

    @MainActor
    func testHybridUsesSmallSharedVolumeAndReleasesBoundedTargets() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        XCTAssertEqual(resources.noiseVolume.textureType, .type3D)
        XCTAssertEqual(resources.noiseVolume.width, 128)
        XCTAssertLessThanOrEqual(resources.noiseVolume.allocatedSize, 8 * 1024 * 1024)
        if ProcessInfo.processInfo.environment["WEATHER_WALLPAPER_GPU_TIMING"] == "1" {
            let shared = resources.cloudAtlas.allocatedSize + resources.moonAlbedo.allocatedSize + resources.noiseVolume.allocatedSize
            print("Shared artwork + volume allocation: \(shared) bytes")
        }
        width = 2560; height = 1600
        let scene = SceneState.preview(kind: .partlyCloudy, time: .day)
        _ = try render(scene, resources: resources)
        XCTAssertEqual(compositor?.cloudRenderSize?.width, 1280)
        XCTAssertLessThan(compositor?.allocatedTransientBytes ?? .max, 16 * 1024 * 1024)
        var battery = RenderPolicy()
        battery.cloudDownsample = 4; battery.cloudSteps = 20; battery.bloomDownsample = 8
        _ = try render(scene, resources: resources, policy: battery)
        XCTAssertEqual(compositor?.cloudRenderSize?.width, 640)
        compositor?.releaseTransientResources()
        XCTAssertEqual(compositor?.allocatedTransientBytes, 0)
        XCTAssertNil(compositor?.cloudRenderSize)
    }

    @MainActor
    func testPreviousRendererRemainsAvailableForVisualComparison() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        let scene = SceneState.preview(kind: .partlyCloudy, time: .day)
        let hybrid = try render(scene, resources: resources)
        var previous = RenderPolicy()
        previous.volumetricClouds = false
        let legacy = try render(scene, resources: resources, policy: previous)
        XCTAssertNotEqual(hybrid, legacy)
        XCTAssertNil(compositor?.cloudRenderSize)
        if let path = ProcessInfo.processInfo.environment["WEATHER_WALLPAPER_RENDER_OUTPUT"] {
            try writePNG(legacy, to: URL(fileURLWithPath: path).appendingPathComponent("comparison-previous-partlyCloudy.png"))
        }
    }

    @MainActor
    func testVolumeIsDeterministicAndClockWrapDoesNotMoveTheSky() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        var policy = RenderPolicy()
        policy.bloom = false
        let scene = SceneState.preview(kind: .partlyCloudy, time: .day)
        let first = try render(scene, seconds: 3600, resources: resources, policy: policy)
        let repeatFrame = try render(scene, seconds: 3600, resources: resources, policy: policy)
        XCTAssertEqual(first, repeatFrame)
        let previous = try render(scene, seconds: 3599.99, resources: resources, policy: policy)
        var difference = 0.0
        for index in stride(from: 0, to: first.count, by: 4) {
            difference += abs(Double(first[index]) - Double(previous[index]))
                + abs(Double(first[index + 1]) - Double(previous[index + 1]))
                + abs(Double(first[index + 2]) - Double(previous[index + 2]))
        }
        XCTAssertLessThan(difference / Double(width * height * 3), 0.75, "Hour-boundary clock splitting must not reset cloud shapes")
    }

    @MainActor
    func testPortraitAndUltrawideCompositionsRender() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        for (name, w, h) in [("portrait",540,960), ("ultrawide",1600,670)] {
            width = w; height = h
            let bytes = try render(.preview(kind: .partlyCloudy, time: .day), resources: resources)
            XCTAssertGreaterThan(meanLuminance(bytes), 20)
            if let path = ProcessInfo.processInfo.environment["WEATHER_WALLPAPER_RENDER_OUTPUT"] {
                try writePNG(bytes, to: URL(fileURLWithPath: path).appendingPathComponent("composition-\(name).png"))
            }
        }
    }

    @MainActor
    func testOptionalFifteenSecondMotionReviews() async throws {
        guard ProcessInfo.processInfo.environment["WEATHER_WALLPAPER_RENDER_MOTION"] == "1",
              let path = ProcessInfo.processInfo.environment["WEATHER_WALLPAPER_RENDER_OUTPUT"] else {
            throw XCTSkip("Opt-in motion capture requires WEATHER_WALLPAPER_RENDER_MOTION=1 and an output folder")
        }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let resources = try MetalResources.shared.get()
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        for kind in [WeatherKind.partlyCloudy, .thunderstorm] {
            let url = URL(fileURLWithPath: path).appendingPathComponent("review-\(kind.rawValue)-\(UUID().uuidString.prefix(8)).mp4")
            let video = try ReviewVideoWriter(url: url, width: width, height: height)
            let scene = SceneState.preview(kind: kind, time: kind == .thunderstorm ? .night : .day)
            var timeline = LightningTimeline()
            for frame in 0..<450 {
                let seconds = Float(frame) / 30
                let strike = timeline.sample(at: Double(seconds), storm: scene.storm, enabled: true)
                let bytes = try render(scene, seconds: seconds, resources: resources, strike: strike)
                try await video.append(bytes, frame: frame)
            }
            try await video.finish()
            print("Visual motion review: \(url.path)")
        }
    }

    private var width = 960
    private var height = 600
    private var lastGPUTime: Double = 0
    private var lastEncodeTime: Double = 0
    private var compositor: SceneCompositor?

    @MainActor
    private func cloudField(_ scene: SceneState, resources: MetalResources, policy: RenderPolicy = RenderPolicy(),
                            pipeline: MTLRenderPipelineState? = nil) throws -> [SIMD4<Float>] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,width: width,height: height,mipmapped: false)
        descriptor.storageMode = .private; descriptor.usage = [.renderTarget,.shaderRead]
        let texture = try XCTUnwrap(resources.device.makeTexture(descriptor: descriptor))
        let rowBytes = ((width*8+255)/256)*256
        let readback = try XCTUnwrap(resources.device.makeBuffer(length: rowBytes*height,options: .storageModeShared))
        let command = try XCTUnwrap(resources.queue.makeCommandBuffer())
        var uniforms = ShaderUniforms(scene: scene,size: CGSize(width: width,height: height),seconds: 19,wind: 0,policy: policy)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare; pass.colorAttachments[0].storeAction = .store
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline ?? resources.cloudVolumePipeline(for: uniforms))
        encoder.setFragmentBytes(&uniforms,length: MemoryLayout<ShaderUniforms>.stride,index: 0)
        encoder.setFragmentTexture(resources.noiseVolume,index: 0)
        encoder.setFragmentTexture(resources.emptyLightDepth,index: 1)
        encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 3)
        encoder.endEncoding()
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from: texture,sourceSlice: 0,sourceLevel: 0,sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: width,height: height,depth: 1),to: readback,destinationOffset: 0,
                  destinationBytesPerRow: rowBytes,destinationBytesPerImage: rowBytes*height)
        blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status,.completed)
        let bits = readback.contents().assumingMemoryBound(to: UInt16.self)
        return (0..<(width*height)).map { pixel in
            let i = (pixel/width)*(rowBytes/2)+(pixel%width)*4
            return SIMD4(Float(Float16(bitPattern: bits[i])),Float(Float16(bitPattern: bits[i+1])),
                         Float(Float16(bitPattern: bits[i+2])),Float(Float16(bitPattern: bits[i+3])))
        }
    }

    @MainActor
    private func benchmarkFrame(_ uniforms: ShaderUniforms,widget: WidgetRainLayoutUniforms,resources: MetalResources,
                                compositor: SceneCompositor,target: MTLTexture,haze: MoonlitHazeUniforms = .disabled) throws -> (gpu: Double,encode: Double) {
        let command = try XCTUnwrap(resources.queue.makeCommandBuffer())
        let start = ProcessInfo.processInfo.systemUptime
        compositor.encode(into: target,buffer: command,uniforms: uniforms,widget: widget,haze: haze)
        let encode = ProcessInfo.processInfo.systemUptime-start
        command.commit(); command.waitUntilCompleted() // Test-only timing, never in the app.
        XCTAssertEqual(command.status,.completed)
        return (command.gpuEndTime-command.gpuStartTime,encode)
    }

    private func imageCodeErrors(_ before: [UInt8],_ after: [UInt8]) -> (mean: Double,maximum: Int) {
        var total = 0, maximum = 0
        for (a,b) in zip(before,after) {
            let error = abs(Int(a)-Int(b)); total += error; maximum = max(maximum,error)
        }
        return (Double(total)/Double(max(1,before.count)),maximum)
    }

    @MainActor
    private func optimizationVariants(resources: MetalResources,individual: Bool = false) async throws -> [String: SceneCompositor] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sky = try String(contentsOf: root.appendingPathComponent("Sources/WeatherWallpaper/Resources/Sky.metal"),encoding: .utf8)
        let atmosphere = try String(contentsOf: root.appendingPathComponent("Sources/WeatherWallpaper/Resources/Atmosphere.metal"),encoding: .utf8)
        let impact = try String(contentsOf: root.appendingPathComponent("Tests/WeatherWallpaperTests/Fixtures/WidgetImpactBeforeOptimization.metal"),encoding: .utf8)
        func sixCorners(_ source: String) -> String {
            source.replacingOccurrences(of: "{ float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) }",
                with: "{ float2(-1,-1), float2(1,-1), float2(-1,1), float2(-1,1), float2(1,-1), float2(1,1) }")
                .replacingOccurrences(of: "{float2(-1,-1),float2(1,-1),float2(-1,1),float2(1,1)}",
                with: "{float2(-1,-1),float2(1,-1),float2(-1,1),float2(-1,1),float2(1,-1),float2(1,1)}")
        }
        func oldCollisions(_ source: String) -> String {
            source.replacingOccurrences(of: "vertex ParticleVertex particleVertex",with: impact+"\nvertex ParticleVertex particleVertex")
                .replacingOccurrences(of: "float4 hit = rainWidgetImpact(drop,u,layout);",with: "float4 hit = referenceRainWidgetImpact(drop,u,layout);")
                .replacingOccurrences(of: "\n            && drop.center.y+drop.size.y*0.7 >= layout.settings.w",with: "")
        }
        let oldAtmosphere = atmosphere.replacingOccurrences(of: "SolarAtmosphereVertex in [[stage_in]]",with: "AtmosphereVertex in [[stage_in]]")
            .replacingOccurrences(of: "float visibility = in.sunVisibility;",with: "float visibility = visibleSunV2(u,clouds);")
        let reference: String
        if let path = ProcessInfo.processInfo.environment["WEATHER_WALLPAPER_OPTIMIZATION_BASELINE"] {
            let directory = URL(fileURLWithPath: path)
            reference = try String(contentsOf: directory.appendingPathComponent("before-Sky.metal"),encoding: .utf8)+"\n"
                + String(contentsOf: directory.appendingPathComponent("before-Atmosphere.metal"),encoding: .utf8)
        } else {
            // Guard the source substitutions so future shader changes cannot
            // silently turn the portable reference into the optimized path.
            XCTAssertTrue(sky.contains("\n            && drop.center.y+drop.size.y*0.7 >= layout.settings.w"))
            XCTAssertTrue(sky.contains("{ float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) }"))
            XCTAssertTrue(atmosphere.contains("float visibility = in.sunVisibility;"))
            reference = oldCollisions(sixCorners(sky))+"\n"+oldAtmosphere
        }
        let previous = try await resources.device.makeLibrary(source: reference,options: nil)
        func pipeline(_ library: MTLLibrary,_ vertex: String,_ fragment: String,_ format: MTLPixelFormat,
                      blending: Int = 0) async throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = format; color.isBlendingEnabled = blending > 0
            if blending > 0 {
                color.sourceRGBBlendFactor = .sourceAlpha; color.destinationRGBBlendFactor = .oneMinusSourceAlpha
                color.sourceAlphaBlendFactor = blending == 1 ? .one : .zero
                color.destinationAlphaBlendFactor = blending == 1 ? .oneMinusSourceAlpha : .one
            }
            return try await resources.device.makeRenderPipelineState(descriptor: descriptor)
        }
        let oldSky = try await pipeline(previous,"atmosphereVertex","atmosphereComposite",.bgra8Unorm_srgb)
        let oldEmission = try await pipeline(previous,"atmosphereVertex","atmosphereEmission",.rgba16Float)
        let oldParticles = try await pipeline(previous,"particleVertex","particleFragment",.bgra8Unorm_srgb,blending: 1)
        let oldLens = try await pipeline(previous,"lensVertex","lensFragment",.bgra8Unorm_srgb,blending: 2)
        var variants = ["before": SceneCompositor(resources: resources,atmospherePipeline: oldSky,atmosphereEmissionPipeline: oldEmission,
            particlePipeline: oldParticles,lensPipeline: oldLens,usesQuadStrips: false,useLightCache: false,useCloudHistory: false),
            "after": SceneCompositor(resources: resources,useLightCache: false,useCloudHistory: false)]
        if individual {
            let quads = try await resources.device.makeLibrary(source: oldCollisions(sky),options: nil)
            let collisions = try await resources.device.makeLibrary(source: sixCorners(sky),options: nil)
            variants["quads"] = SceneCompositor(resources: resources,atmospherePipeline: oldSky,atmosphereEmissionPipeline: oldEmission,
                particlePipeline: try await pipeline(quads,"particleVertex","particleFragment",.bgra8Unorm_srgb,blending: 1),
                useLightCache: false,useCloudHistory: false)
            variants["collisions"] = SceneCompositor(resources: resources,atmospherePipeline: oldSky,atmosphereEmissionPipeline: oldEmission,
                particlePipeline: try await pipeline(collisions,"particleVertex","particleFragment",.bgra8Unorm_srgb,blending: 1),
                lensPipeline: oldLens,usesQuadStrips: false,useLightCache: false,useCloudHistory: false)
            variants["solar"] = SceneCompositor(resources: resources,particlePipeline: oldParticles,lensPipeline: oldLens,
                usesQuadStrips: false,useLightCache: false,useCloudHistory: false)
        }
        return variants
    }

    @MainActor
    private func render(_ scene: SceneState, seconds: Float = 0, resources: MetalResources,
                        policy: RenderPolicy = RenderPolicy(), cloudLayers: SIMD4<Float>? = nil,
                        strike: LightningSample? = nil, baseline: SceneCompositor? = nil,
                        historicalUniforms: Bool = true, rainOverride: Float? = nil, nightNotchGlow: Bool = false,
                        hazeConfiguration: NotchHazeConfiguration? = nil,hazeOverride: MoonlitHazeUniforms? = nil) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
                                                                 width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        let texture = try XCTUnwrap(resources.device.makeTexture(descriptor: descriptor))
        let bytesPerRow = ((width * 4 + 255) / 256) * 256
        let readback = try XCTUnwrap(resources.device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared))
        let buffer = try XCTUnwrap(resources.queue.makeCommandBuffer())
        var uniforms = ShaderUniforms(scene: scene, size: CGSize(width: width, height: height),
                                     seconds: Double(seconds), wind: Double(seconds * scene.wind * scene.windDirection),
                                     policy: policy,
                                      strike: strike ?? LightningSample(origin: 0.58, seed: 41, intensity: scene.storm * 0.6, reach: 0.90))
        if let cloudLayers { uniforms.clouds = cloudLayers; uniforms.cloudStructure.z = cloudLayers.x }
        if let rainOverride { uniforms.weather.x = rainOverride }
        if baseline != nil && historicalUniforms {
            uniforms.clouds.w = min(1,scene.cloud * 4) * (1 - uniforms.clouds.z * 0.6)
            uniforms.cloudStructure.z = uniforms.clouds.x
        }
        if compositor == nil { compositor = SceneCompositor(resources: resources) }
        let meteor = policy.animated && !policy.suspended && policy.permitsMeteors && scene.solar.daylight < 0.1
            ? MeteorAppearance.sample(at: Double(seconds),aspect: Float(width)/Float(height),speed: policy.meteorSpeed) : nil
        let encodeStart = ProcessInfo.processInfo.systemUptime
        (baseline ?? compositor)?.encode(into: texture, buffer: buffer, uniforms: uniforms,meteor: meteor,
                                         framesPerSecond: policy.framesPerSecond,animated: policy.animated && !policy.suspended,
                                         widget: WidgetRainLayoutUniforms(areas: policy.widgetRainAreas,screenHeight: Float(height),
                                              guide: policy.showsWidgetGuide,animated: policy.animated && !policy.suspended),
                                         haze: hazeOverride ?? hazeConfiguration.map { MoonlitHazeUniforms(configuration: $0,seconds: Double(seconds)) }
                                            ?? (nightNotchGlow ? MoonlitHazeUniforms(configuration: NotchHazeConfiguration(),seconds: Double(seconds)) : .disabled))
        lastEncodeTime = ProcessInfo.processInfo.systemUptime-encodeStart
        let blit = try XCTUnwrap(buffer.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: readback,
                  destinationOffset: 0, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted() // Readback is test-only; the app never blocks on the GPU.
        XCTAssertEqual(buffer.status, .completed, buffer.error?.localizedDescription ?? "GPU command failed")
        lastGPUTime = buffer.gpuEndTime - buffer.gpuStartTime
        let pointer = readback.contents().assumingMemoryBound(to: UInt8.self)
        var pixels = [UInt8]()
        pixels.reserveCapacity(width * height * 4)
        for row in 0..<height {
            pixels.append(contentsOf: UnsafeBufferPointer(start: pointer + row * bytesPerRow, count: width * 4))
        }
        return pixels
    }

    // Test-only preserved billowing endpoint for shader specialization/history
    // diagnostics. Shipping ordinary clouds now use the raised bank profile.
    private func formerCumulusFixture(time: PreviewTime = .day,towers: Bool = false) -> SceneState {
        var scene = SceneState.preview(kind: .partlyCloudy,time: time,cloudDevelopment: towers ? .toweringCumulus : nil)
        let convection = scene.cloudPresentation!.convection
        var profile = CloudPresentation.generic
        profile.shape = SIMD4(1.15,1.1,1,0); profile.erosion = 0.075
        profile.convection = convection
        scene.cloudPresentation = profile
        return scene
    }

    private func meanLuminance(_ bytes: [UInt8]) -> Double {
        var sum = 0.0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            sum += Double(bytes[index]) * 0.0722 + Double(bytes[index + 1]) * 0.7152 + Double(bytes[index + 2]) * 0.2126
        }
        return sum / Double(bytes.count / 4)
    }

    private func writePNG(_ bytes: [UInt8], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(bytes) as CFData
        let provider = try XCTUnwrap(CGDataProvider(data: data))
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
                                         decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
