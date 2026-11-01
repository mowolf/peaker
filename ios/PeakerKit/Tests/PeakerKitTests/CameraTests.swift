import Foundation
import Testing
@testable import PeakerKit

func close(_ a: Double, _ b: Double, _ eps: Double = 1e-6) -> Bool { abs(a - b) < eps }

@Test func directions() {
    let east = Vec3.direction(azimuth: 90, altitude: 0)
    #expect(close(east.x, 0) && close(east.y, -1) && close(east.z, 0))
    let (az, alt) = Vec3.direction(azimuth: 237, altitude: 12).azimuthAltitude
    #expect(close(az, 237) && close(alt, 12))
}

@Test func virtualCameraProjection() {
    let pose = CameraPose(yaw: 120, pitch: 5, focalLength: 500, centerX: 200, centerY: 400)
    let c = pose.project(azimuth: 120, altitude: 5)!
    #expect(close(c.x, 200) && close(c.y, 400))
    // A point further clockwise (to the right) and higher appears right and above the centre.
    let p = pose.project(azimuth: 130, altitude: 8)!
    #expect(p.x > 200 && p.y < 400)
    // Behind the camera: not visible.
    #expect(pose.project(azimuth: 300, altitude: 0) == nil)
    // Round trip through the inverse.
    let back = pose.direction(x: p.x, y: p.y).azimuthAltitude
    #expect(close(back.azimuth, 130, 1e-6) && close(back.altitude, 8, 1e-6))
    #expect(close(pose.azimuth, 120) && close(pose.pitch, 5) && close(pose.roll, 0))
}

@Test func rollAndCalibration() {
    let rolled = CameraPose(yaw: 0, pitch: 0, roll: 10, focalLength: 500, centerX: 0, centerY: 0)
    #expect(close(rolled.roll, 10, 1e-6))
    // Rolling the phone clockwise turns the image counter-clockwise: the horizon on the right appears higher.
    #expect(rolled.project(azimuth: 10, altitude: 0)!.y < 0)
    let turned = CameraPose(yaw: 40, pitch: 0, focalLength: 500, centerX: 0, centerY: 0).rotatedYaw(by: 15)
    #expect(close(turned.azimuth, 55, 1e-6))
    #expect(close(turned.pitched(by: 7).pitch, 7, 1e-6))
}

/// The attitude quaternion maps device axes into the (north, west, up) frame. Device upright in portrait,
/// back camera facing north: -z_dev → north, +y_dev → up, +x_dev → east.
@Test func deviceAttitudeUprightFacingNorth() {
    let q = Quaternion(x: 0.5, y: -0.5, z: -0.5, w: 0.5)
    let pose = CameraPose(deviceAttitude: q, focalLength: 500, centerX: 0, centerY: 0)
    #expect(close(pose.azimuth, 0, 1e-9) || close(pose.azimuth, 360, 1e-9))
    #expect(close(pose.pitch, 0, 1e-9))
    #expect(close(pose.roll, 0, 1e-9))
    #expect(close(pose.right.y, -1, 1e-9))  // right = east
    // Lying flat, screen up (identity): the camera looks straight down.
    let flat = CameraPose(deviceAttitude: Quaternion(x: 0, y: 0, z: 0, w: 1), focalLength: 500, centerX: 0, centerY: 0)
    #expect(close(flat.pitch, -90, 1e-6))
}

@Test func focalLength() {
    #expect(close(CameraPose.focalLength(fieldOfView: 90, pixelsAcross: 400), 200))
}
