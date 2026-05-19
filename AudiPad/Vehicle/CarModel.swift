import SceneKit
import UIKit

/// Procedural low-poly Audi Q5/SQ5 model built from SceneKit primitives.
/// Tuned to read as a black SUV at the small annotation size the map uses,
/// with proportions that match the real car at ~real-world scale:
///
///   length  4.66 m, width 1.89 m, height 1.66 m
///   wheelbase 2.82 m, ground clearance 0.18 m
///
/// SCNBox primitives can't capture the kinked DLO or the rear roof
/// slope, so the silhouette is approximated. Body shape readability
/// comes from the chassis-taller-than-cabin proportion (chassis 0.75 m
/// vs cabin 0.45 m), tucked-in wheels, and roof rails — all distinctive
/// Q5 elements.
enum CarModel {
    static func makeNode() -> SCNNode {
        let root = SCNNode()

        // ── Palette ─────────────────────────────────────────────────────
        // Mythos-black-ish — not pure 0,0,0 so the body still picks up
        // specular highlights rather than collapsing to a silhouette.
        let bodyColor   = UIColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1.0)
        let glassColor  = UIColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1.0)
        let darkColor   = UIColor(white: 0.04, alpha: 1.0)
        let tireColor   = UIColor(white: 0.07, alpha: 1.0)
        let rimColor    = UIColor(white: 0.62, alpha: 1.0)
        let chromeColor = UIColor(white: 0.72, alpha: 1.0)
        let lightWhite  = UIColor(white: 0.96, alpha: 1.0)
        let taillightR  = UIColor(red: 0.80, green: 0.06, blue: 0.06, alpha: 1.0)

        // ── Dimensions (from SQ5 side-view reference photos) ────────────
        let L: Float = 4.66
        let W: Float = 1.89
        let wheelR: Float = 0.38                            // 21" S-line wheels
        let chassisH: Float = 0.93                          // belt-line raised
        let cabinH:   Float = 0.55
        let baseY:    Float = 0.18                          // ground clearance

        // From the side-view reference, the cabin (windshield base to
        // rear hatch top) spans roughly 30%→90% of the length. We model
        // it as a single box at that span, leaving:
        //   • ~10% length hood forward of cabin (~0.47 m? no — 30%)
        //   • ~10% length rear-bumper stub behind cabin
        //
        // Actually: hood = 30% of length (~1.40 m), cabin = 60% (~2.80 m),
        // rear stub = 10% (~0.47 m).
        let cabinLen: Float = L * 0.55                      // ~2.56 m
        let hoodLen:  Float = L * 0.35                      // ~1.63 m — long hood, Q5 profile
        let rearStub: Float = L - cabinLen - hoodLen        // ~0.47 m
        let cabinCenterZ: Float = -L/2 + rearStub + cabinLen/2  // ~ -0.58
        _ = hoodLen                                          // documented above

        // ── Body materials helpers ──────────────────────────────────────
        func paint(_ box: SCNGeometry) {
            box.firstMaterial?.diffuse.contents  = bodyColor
            box.firstMaterial?.specular.contents = UIColor.white
            box.firstMaterial?.shininess         = 1.0       // glossy paint
            box.firstMaterial?.metalness.contents = 0.4
        }

        // ── Chassis (everything below the window line) ──────────────────
        // Heavy chamferRadius rounds the nose corners so the front of
        // the hood reads as curved rather than boxy.
        let chassis = SCNBox(width: CGFloat(W), height: CGFloat(chassisH),
                             length: CGFloat(L), chamferRadius: 0.42)
        paint(chassis)
        let chassisN = SCNNode(geometry: chassis)
        chassisN.position = SCNVector3(0, baseY + chassisH/2, 0)
        root.addChildNode(chassisN)

        // ── Cabin (greenhouse — extends to the rear, no trunk) ─────────
        let cabin = SCNBox(width: CGFloat(W * 0.88), height: CGFloat(cabinH),
                           length: CGFloat(cabinLen), chamferRadius: 0.20)
        paint(cabin)
        let cabinN = SCNNode(geometry: cabin)
        cabinN.position = SCNVector3(0,
                                     baseY + chassisH + cabinH/2,
                                     cabinCenterZ)
        root.addChildNode(cabinN)

        // ── Glass band — slightly inset, follows cabin length ──────────
        let glass = SCNBox(width: CGFloat(W * 0.91), height: CGFloat(cabinH * 0.70),
                           length: CGFloat(cabinLen * 0.95), chamferRadius: 0.06)
        glass.firstMaterial?.diffuse.contents  = glassColor
        glass.firstMaterial?.specular.contents = UIColor.white
        glass.firstMaterial?.shininess         = 1.0
        let glassN = SCNNode(geometry: glass)
        glassN.position = SCNVector3(0,
                                     baseY + chassisH + cabinH/2 + 0.04,
                                     cabinCenterZ)
        root.addChildNode(glassN)

        // ── Windshield — tilted thin panel in front of the cabin's
        //    front face. Without this the cabin's vertical front wall
        //    reads as forward-leaning under the SceneKit camera's slight
        //    perspective. 30° from vertical = top recedes back, like a
        //    real Q5 raked windshield.
        let wsAngle: Float = 30 * .pi / 180
        let wsSlopeLen: Float = cabinH / cos(wsAngle)
        let wsCenterY: Float = baseY + chassisH + cabinH/2
        let wsCenterZ: Float = cabinCenterZ + cabinLen/2 + (cabinH * tan(wsAngle))/2
        let windshield = SCNBox(width: CGFloat(W * 0.85),
                                height: CGFloat(wsSlopeLen),
                                length: 0.04,
                                chamferRadius: 0.02)
        windshield.firstMaterial?.diffuse.contents  = glassColor
        windshield.firstMaterial?.specular.contents = UIColor.white
        windshield.firstMaterial?.shininess         = 1.0
        let windshieldN = SCNNode(geometry: windshield)
        windshieldN.position    = SCNVector3(0, wsCenterY, wsCenterZ)
        windshieldN.eulerAngles = SCNVector3(-wsAngle, 0, 0)
        root.addChildNode(windshieldN)

        // ── Rear hatch glass — symmetric, tilted forward at top
        //    (~25° from vertical, slightly less raked than the
        //    windshield, which is typical for hatchback profiles).
        let rwAngle: Float = 25 * .pi / 180
        let rwSlopeLen: Float = cabinH / cos(rwAngle)
        let rwCenterZ: Float = cabinCenterZ - cabinLen/2 - (cabinH * tan(rwAngle))/2
        let rearWindow = SCNBox(width: CGFloat(W * 0.85),
                                height: CGFloat(rwSlopeLen),
                                length: 0.04,
                                chamferRadius: 0.02)
        rearWindow.firstMaterial?.diffuse.contents  = glassColor
        rearWindow.firstMaterial?.specular.contents = UIColor.white
        rearWindow.firstMaterial?.shininess         = 1.0
        let rearWindowN = SCNNode(geometry: rearWindow)
        rearWindowN.position    = SCNVector3(0, wsCenterY, rwCenterZ)
        rearWindowN.eulerAngles = SCNVector3(rwAngle, 0, 0)
        root.addChildNode(rearWindowN)

        // ── Roof rails — span the cabin length minus a small inset ─────
        let rail = SCNBox(width: 0.07, height: 0.05,
                          length: CGFloat(cabinLen * 0.85), chamferRadius: 0.02)
        rail.firstMaterial?.diffuse.contents  = chromeColor
        rail.firstMaterial?.specular.contents = UIColor.white
        rail.firstMaterial?.shininess         = 0.9
        for sx: Float in [-1, 1] {
            let n = SCNNode(geometry: rail)
            n.position = SCNVector3(sx * (W * 0.41),
                                    baseY + chassisH + cabinH + 0.025,
                                    cabinCenterZ)
            root.addChildNode(n)
        }

        // ── Wheels — tucked in (smaller R, larger inset) so they read
        //    as inset under fenders rather than off-road tires ───────────
        let tire = SCNCylinder(radius: CGFloat(wheelR), height: 0.26)
        tire.firstMaterial?.diffuse.contents = tireColor
        let rim = SCNCylinder(radius: CGFloat(wheelR * 0.70), height: 0.28)
        rim.firstMaterial?.diffuse.contents  = rimColor
        rim.firstMaterial?.specular.contents = UIColor.white
        rim.firstMaterial?.shininess         = 0.6

        let wheelInset: Float = 0.12
        let wheelPositions: [(Float, Float)] = [
            ( W/2 - wheelInset,  L/2 - 0.95),
            (-W/2 + wheelInset,  L/2 - 0.95),
            ( W/2 - wheelInset, -L/2 + 0.95),
            (-W/2 + wheelInset, -L/2 + 0.95),
        ]
        for (x, z) in wheelPositions {
            let tireN = SCNNode(geometry: tire)
            tireN.position = SCNVector3(x, wheelR, z)
            tireN.eulerAngles = SCNVector3(0, 0, Float.pi/2)
            root.addChildNode(tireN)
            let rimN = SCNNode(geometry: rim)
            rimN.position = tireN.position
            rimN.eulerAngles = tireN.eulerAngles
            root.addChildNode(rimN)
        }

        // ── Single-frame grille — wider and more imposing than v1 ───────
        let grille = SCNBox(width: CGFloat(W * 0.65), height: 0.35,
                            length: 0.05, chamferRadius: 0.05)
        grille.firstMaterial?.diffuse.contents = darkColor
        let grilleN = SCNNode(geometry: grille)
        grilleN.position = SCNVector3(0, baseY + 0.30, L/2 - 0.025)
        root.addChildNode(grilleN)

        // ── LED DRL headlights — slim horizontal slits ──────────────────
        let hl = SCNBox(width: 0.40, height: 0.06, length: 0.05, chamferRadius: 0.02)
        hl.firstMaterial?.diffuse.contents  = lightWhite
        hl.firstMaterial?.emission.contents = UIColor(white: 0.85, alpha: 1.0)
        for sx: Float in [-1, 1] {
            let n = SCNNode(geometry: hl)
            n.position = SCNVector3(sx * (W * 0.34),
                                    baseY + 0.50,
                                    L/2 - 0.025)
            root.addChildNode(n)
        }

        // ── Continuous LED taillight bar ────────────────────────────────
        let tl = SCNBox(width: CGFloat(W * 0.82), height: 0.07,
                        length: 0.05, chamferRadius: 0.02)
        tl.firstMaterial?.diffuse.contents  = taillightR
        tl.firstMaterial?.emission.contents = UIColor(red: 0.45, green: 0, blue: 0, alpha: 1.0)
        let tlN = SCNNode(geometry: tl)
        tlN.position = SCNVector3(0, baseY + 0.50, -L/2 + 0.025)
        root.addChildNode(tlN)

        // ── Lower body trim — dark plastic skirt for the SUV stance ─────
        let skirt = SCNBox(width: CGFloat(W * 1.005), height: 0.12,
                           length: CGFloat(L * 0.94), chamferRadius: 0.04)
        skirt.firstMaterial?.diffuse.contents = darkColor
        let skirtN = SCNNode(geometry: skirt)
        skirtN.position = SCNVector3(0, baseY + 0.06, 0)
        root.addChildNode(skirtN)

        // Pivot at the car's geometric center so eulerAngles.y spins it
        // around its own vertical axis instead of orbiting a corner.
        root.pivot = SCNMatrix4MakeTranslation(0, baseY + (chassisH + cabinH)/2, 0)
        return root
    }

    /// Try to load the bundled `SQ5.usdz` model and return a node ready
    /// to drop into the annotation scene. Returns nil if the file is
    /// missing, fails to parse, or has degenerate geometry — caller
    /// should fall back to the procedural `makeNode()` in that case.
    ///
    /// Structure: an outer wrapper whose `eulerAngles.y` is owned by
    /// `CarAnnotationView.applyTransform` (overwritten every frame),
    /// wrapping an inner `model` node that holds the bake-in
    /// transforms: uniform scale to ~4.66 m on the longest extent
    /// (the car's length), pivot at the model's geometric centre so
    /// yaw spins around the vertical axis, and an optional Y-axis
    /// orientation correction to align the hood with +Z (which the
    /// rest of the camera-orbit code assumes).
    static func loadSQ5USDZ() -> SCNNode? {
        guard let url = Bundle.main.url(forResource: "SQ5", withExtension: "usdz"),
              let scene = try? SCNScene(url: url, options: nil)
        else { return nil }

        let wrapper = SCNNode()
        let model = SCNNode()
        for child in scene.rootNode.childNodes {
            model.addChildNode(child)
        }
        wrapper.addChildNode(model)

        let (boxMin, boxMax) = model.boundingBox
        let extX = Float(boxMax.x - boxMin.x)
        let extY = Float(boxMax.y - boxMin.y)
        let extZ = Float(boxMax.z - boxMin.z)
        let longest = max(extX, extY, extZ)
        guard longest > 0 else { return nil }

        // Bump 1.2× over real-world length — the orthographic camera
        // makes 4.66 m read a little small at the annotation footprint,
        // and a slightly oversized marker is easier to track at a glance
        // while driving.
        let targetLength: Float = 4.66 * 1.2
        let s = targetLength / longest
        model.scale = SCNVector3(s, s, s)

        let cx = Float(boxMin.x + boxMax.x) / 2
        let cy = Float(boxMin.y + boxMax.y) / 2
        let cz = Float(boxMin.z + boxMax.z) / 2
        model.pivot = SCNMatrix4MakeTranslation(cx, cy, cz)

        // Tint the windows toward a privacy-glass dark gray. The
        // stock USDZ ships them as light gray, which reads as plastic
        // on a black body and breaks the SQ5 silhouette.
        tintWindows(in: model)

        // Pick the longest extent as the "length" axis and rotate so
        // that axis maps to +Z (matches the procedural model's
        // convention, which the annotation camera + yaw transform are
        // built around). Most USDZ car exports come out +X-forward,
        // so the X case is the common one; the others are safety
        // nets if a future swap-in uses a different export.
        if extX >= extY && extX >= extZ {
            // Length along X → rotate -90° about Y so +X aligns with +Z.
            model.eulerAngles = SCNVector3(0, -Float.pi / 2, 0)
        } else if extZ >= extX && extZ >= extY {
            // Already +Z-aligned, no rotation needed.
        } else {
            // Length along Y is unusual (model on its side?). Leave
            // it alone — first render will surface the issue.
        }

        return wrapper
    }

    /// Walk every material in the hierarchy and swap window-like
    /// materials' diffuse to a dark tint. Detection is by material
    /// name first (most USDZ exports name them `glass`/`window`/etc.)
    /// with a transparency-hint fallback so opaque-but-named windows
    /// still get caught and translucent unnamed glass doesn't get
    /// missed.
    private static func tintWindows(in root: SCNNode) {
        // Privacy-glass tone — very dark gray with a slight cool tint
        // so the windows still read as separate from the body paint
        // rather than collapsing into it.
        let tint = UIColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1.0)

        root.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            for material in geometry.materials where isWindowMaterial(material) {
                material.diffuse.contents = tint
                // Force opacity — we want a solid tinted look, not
                // see-through (which would expose any missing
                // interior geometry).
                material.transparency = 1.0
                if material.lightingModel == .physicallyBased {
                    material.metalness.contents = 0.4
                    material.roughness.contents = 0.15
                } else {
                    material.specular.contents = UIColor.white
                    material.shininess = 0.9
                }
            }
        }
    }

    private static func isWindowMaterial(_ m: SCNMaterial) -> Bool {
        let name = (m.name ?? "").lowercased()
        if name.contains("glass")
            || name.contains("window")
            || name.contains("windshield")
            || name.contains("windscreen") {
            return true
        }
        // Fallback: materials with non-trivial transparency are almost
        // always glass. Threshold below 0.95 so fully-opaque body
        // paint (transparency = 1.0) isn't caught.
        return m.transparency < 0.95
    }
}
