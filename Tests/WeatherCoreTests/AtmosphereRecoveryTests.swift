import XCTest
@testable import WeatherCore

final class AtmosphereRecoveryTests: XCTestCase {
    func testPanoramaDirectionsAgreeWithAltitudeAzimuthAndWrap() {
        for azimuth in stride(from: 0.0,to: 360.0,by: 30) {
            for altitude in [0.0,15,45,80] {
                let position = SkyProjection.position(azimuthDegrees: azimuth,altitudeDegrees: altitude)
                let ray = SkyProjection.direction(at: position)
                let angle = (altitude + SkyProjection.refraction(at: altitude)) * .pi / 180
                XCTAssertEqual(Double(ray.y),sin(angle),accuracy: 0.00001)
                XCTAssertEqual(Double(ray.x),sin(azimuth * .pi/180) * cos(angle),accuracy: 0.00001)
                XCTAssertEqual(ray.x * ray.x + ray.y * ray.y + ray.z * ray.z,1,accuracy: 0.00001)
            }
        }
        let north = SkyProjection.direction(at: SIMD2(0,0.97))
        let wrapped = SkyProjection.direction(at: SIMD2(1,0.97))
        XCTAssertEqual(north.z,wrapped.z,accuracy: 0.00001)
        XCTAssertEqual(north.x,wrapped.x,accuracy: 0.00001)
        XCTAssertEqual(north.y,0,accuracy: 0.00001)
    }

    func testMeteorHasEqualPixelVelocitiesAndGrowsFromNothing() throws {
        let cycle = try XCTUnwrap((0..<20).first { MeteorAppearance.sample(at: Double($0)*7+0.3,aspect: 1.6) != nil })
        let began = Double(cycle)*7+0.18
        XCTAssertNil(MeteorAppearance.sample(at: began,aspect: 1.6))
        let newborn = try XCTUnwrap(MeteorAppearance.sample(at: began+0.001,aspect: 1.6))
        let first = try XCTUnwrap(MeteorAppearance.sample(at: began+0.15,aspect: 1.6))
        let second = try XCTUnwrap(MeteorAppearance.sample(at: began+0.30,aspect: 1.6))
        XCTAssertLessThan(newborn.trainLength,0.001)
        XCTAssertLessThan(newborn.intensity,0.01)
        XCTAssertLessThan(second.head.x,first.head.x)
        XCTAssertGreaterThan(second.head.y,first.head.y)
        XCTAssertEqual(first.head.x-second.head.x,second.head.y-first.head.y,accuracy: 0.00001)
        XCTAssertLessThanOrEqual(second.trainLength,0.085)
        XCTAssertNil(MeteorAppearance.sample(at: began+0.66,aspect: 1.6))
    }

    func testMeteorSpeedChangesDurationNotPathOrAspectCorrectDirection() throws {
        let cycle = try XCTUnwrap((0..<20).first { MeteorAppearance.sample(at: Double($0)*7+0.3,aspect: 1.6) != nil })
        let began = Double(cycle)*7+0.18
        for speed: Float in [0.25,1,2.5] {
            let sample = try XCTUnwrap(MeteorAppearance.sample(at: began + Double(0.65/speed)*0.5,aspect: 1.6,speed: speed))
            let reference = try XCTUnwrap(MeteorAppearance.sample(at: began+0.325,aspect: 1.6))
            XCTAssertEqual(sample.head.x,reference.head.x,accuracy: 0.00001)
            XCTAssertEqual(sample.head.y,reference.head.y,accuracy: 0.00001)
        }
        XCTAssertNil(MeteorAppearance.sample(at: .infinity,aspect: 1.6))
        XCTAssertNil(MeteorAppearance.sample(at: 0.3,aspect: 0))
        XCTAssertNil(MeteorAppearance.sample(at: -1,aspect: 1.6))
    }
}
