import SwiftUI

/// A hairline rule flanked by the flourish ornament on both sides, with
/// arbitrary center content — a section-list title, or just a diamond for a
/// modal's chapter rule. Shared so both read as the same decorative family.
struct FlankedOrnamentRule<Center: View>: View {
    @ViewBuilder var center: () -> Center

    var body: some View {
        HStack(spacing: 8) {
            // Negative spacing overlaps the hairline into the ornament's own
            // frame — the flourish tapers to a thin, gappy tail right at its
            // bounding-box edge, so a flush (zero-spacing) hairline still
            // reads as disconnected; the overlap guarantees contact.
            HStack(spacing: -3) {
                line
                ornament(flippedHorizontally: true)
            }

            center()

            HStack(spacing: -3) {
                ornament()
                line
            }
        }
    }

    private var line: some View {
        Rectangle()
            .fill(AppPalette.line.swiftUI)
            .frame(height: 1)
    }

    /// Flourish flanking the center content: its dense end sits against the
    /// content, its thin trailing end feeds into the line running out to the
    /// edge. Unflipped (right side) matches the source art's native
    /// left-to-right orientation; the left side mirrors it so the line still
    /// runs outward, away from center, on that side too.
    private func ornament(flippedHorizontally: Bool = false) -> some View {
        SectionTitleOrnament()
            .fill(AppPalette.line.swiftUI)
            .frame(width: 17, height: 11)
            .scaleEffect(x: flippedHorizontally ? -1 : 1, y: 1)
    }
}

/// Small flourish-into-hairline motif used by `FlankedOrnamentRule`,
/// normalized from a corner/divider ornament sheet (3387180_58104.svg).
struct SectionTitleOrnament: Shape {
    func path(in rect: CGRect) -> Path {
        Self.unitPath.applying(CGAffineTransform(
            a: rect.width, b: 0, c: 0, d: rect.height, tx: rect.minX, ty: rect.minY
        ))
    }

    private static let unitPath: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 0.2352, y: 0.9493))
        path.addCurve(to: CGPoint(x: 0.2519, y: 0.8722), control1: CGPoint(x: 0.2429, y: 0.9255), control2: CGPoint(x: 0.2502, y: 0.8988))
        path.addCurve(to: CGPoint(x: 0.2413, y: 0.8158), control1: CGPoint(x: 0.2532, y: 0.8524), control2: CGPoint(x: 0.2513, y: 0.83))
        path.addCurve(to: CGPoint(x: 0.1966, y: 0.7746), control1: CGPoint(x: 0.2309, y: 0.8009), control2: CGPoint(x: 0.2016, y: 0.7991))
        path.addCurve(to: CGPoint(x: 0.2119, y: 0.7878), control1: CGPoint(x: 0.2016, y: 0.779), control2: CGPoint(x: 0.206, y: 0.785))
        path.addCurve(to: CGPoint(x: 0.2335, y: 0.7904), control1: CGPoint(x: 0.2193, y: 0.7913), control2: CGPoint(x: 0.2259, y: 0.7931))
        path.addCurve(to: CGPoint(x: 0.2692, y: 0.7471), control1: CGPoint(x: 0.247, y: 0.7855), control2: CGPoint(x: 0.2649, y: 0.7679))
        path.addCurve(to: CGPoint(x: 0.2664, y: 0.7411), control1: CGPoint(x: 0.2699, y: 0.7439), control2: CGPoint(x: 0.2687, y: 0.741))
        path.addCurve(to: CGPoint(x: 0.235, y: 0.7216), control1: CGPoint(x: 0.2528, y: 0.7413), control2: CGPoint(x: 0.2443, y: 0.7374))
        path.addCurve(to: CGPoint(x: 0.2213, y: 0.6698), control1: CGPoint(x: 0.2262, y: 0.7067), control2: CGPoint(x: 0.2229, y: 0.6893))
        path.addCurve(to: CGPoint(x: 0.2294, y: 0.5673), control1: CGPoint(x: 0.2188, y: 0.6378), control2: CGPoint(x: 0.2213, y: 0.5973))
        path.addCurve(to: CGPoint(x: 0.2627, y: 0.4836), control1: CGPoint(x: 0.2375, y: 0.5374), control2: CGPoint(x: 0.248, y: 0.5068))
        path.addCurve(to: CGPoint(x: 0.2802, y: 0.4602), control1: CGPoint(x: 0.2681, y: 0.475), control2: CGPoint(x: 0.2744, y: 0.4679))
        path.addCurve(to: CGPoint(x: 0.2544, y: 0.5905), control1: CGPoint(x: 0.2657, y: 0.5), control2: CGPoint(x: 0.2572, y: 0.5449))
        path.addCurve(to: CGPoint(x: 0.2567, y: 0.6953), control1: CGPoint(x: 0.2523, y: 0.6254), control2: CGPoint(x: 0.2523, y: 0.6608))
        path.addCurve(to: CGPoint(x: 0.2666, y: 0.7292), control1: CGPoint(x: 0.2581, y: 0.7065), control2: CGPoint(x: 0.2592, y: 0.7238))
        path.addCurve(to: CGPoint(x: 0.2751, y: 0.7601), control1: CGPoint(x: 0.2687, y: 0.7401), control2: CGPoint(x: 0.2714, y: 0.7506))
        path.addCurve(to: CGPoint(x: 0.3293, y: 0.8278), control1: CGPoint(x: 0.2877, y: 0.792), control2: CGPoint(x: 0.3072, y: 0.8145))
        path.addCurve(to: CGPoint(x: 0.3533, y: 0.8395), control1: CGPoint(x: 0.3365, y: 0.8336), control2: CGPoint(x: 0.3445, y: 0.8377))
        path.addCurve(to: CGPoint(x: 0.3652, y: 0.8411), control1: CGPoint(x: 0.3573, y: 0.8404), control2: CGPoint(x: 0.3613, y: 0.8408))
        path.addCurve(to: CGPoint(x: 0.3754, y: 0.8422), control1: CGPoint(x: 0.3686, y: 0.8416), control2: CGPoint(x: 0.372, y: 0.8421))
        path.addCurve(to: CGPoint(x: 0.3772, y: 0.8412), control1: CGPoint(x: 0.3762, y: 0.8423), control2: CGPoint(x: 0.3768, y: 0.8418))
        path.addCurve(to: CGPoint(x: 0.4718, y: 0.6869), control1: CGPoint(x: 0.4452, y: 0.8366), control2: CGPoint(x: 0.4936, y: 0.7526))
        path.addCurve(to: CGPoint(x: 0.3995, y: 0.7026), control1: CGPoint(x: 0.4475, y: 0.6136), control2: CGPoint(x: 0.3955, y: 0.6498))
        path.addCurve(to: CGPoint(x: 0.4091, y: 0.731), control1: CGPoint(x: 0.3995, y: 0.7026), control2: CGPoint(x: 0.3958, y: 0.7233))
        path.addCurve(to: CGPoint(x: 0.3782, y: 0.7553), control1: CGPoint(x: 0.4223, y: 0.7388), control2: CGPoint(x: 0.4019, y: 0.7701))
        path.addCurve(to: CGPoint(x: 0.3551, y: 0.5313), control1: CGPoint(x: 0.3544, y: 0.7405), control2: CGPoint(x: 0.3022, y: 0.7032))
        path.addCurve(to: CGPoint(x: 0.7372, y: 0.4428), control1: CGPoint(x: 0.4113, y: 0.3486), control2: CGPoint(x: 0.5339, y: 0.2411))
        path.addCurve(to: CGPoint(x: 0.8914, y: 0.4255), control1: CGPoint(x: 0.8691, y: 0.5737), control2: CGPoint(x: 0.9012, y: 0.4906))
        path.addCurve(to: CGPoint(x: 0.8896, y: 0.4155), control1: CGPoint(x: 0.8916, y: 0.4221), control2: CGPoint(x: 0.8908, y: 0.4188))
        path.addCurve(to: CGPoint(x: 0.8707, y: 0.3759), control1: CGPoint(x: 0.8858, y: 0.3985), control2: CGPoint(x: 0.8791, y: 0.3839))
        path.addCurve(to: CGPoint(x: 0.8599, y: 0.1983), control1: CGPoint(x: 0.8533, y: 0.324), control2: CGPoint(x: 0.8546, y: 0.2511))
        path.addCurve(to: CGPoint(x: 0.8984, y: 0.0987), control1: CGPoint(x: 0.8639, y: 0.1584), control2: CGPoint(x: 0.8802, y: 0.1263))
        path.addCurve(to: CGPoint(x: 0.9618, y: 0.1277), control1: CGPoint(x: 0.9203, y: 0.0656), control2: CGPoint(x: 0.9686, y: 0.0675))
        path.addCurve(to: CGPoint(x: 0.9439, y: 0.1734), control1: CGPoint(x: 0.9597, y: 0.1459), control2: CGPoint(x: 0.9528, y: 0.1615))
        path.addCurve(to: CGPoint(x: 0.9189, y: 0.1874), control1: CGPoint(x: 0.9361, y: 0.1531), control2: CGPoint(x: 0.9126, y: 0.1636))
        path.addCurve(to: CGPoint(x: 0.9311, y: 0.2173), control1: CGPoint(x: 0.9225, y: 0.2012), control2: CGPoint(x: 0.9244, y: 0.2065))
        path.addCurve(to: CGPoint(x: 0.9477, y: 0.2206), control1: CGPoint(x: 0.9353, y: 0.224), control2: CGPoint(x: 0.9425, y: 0.2253))
        path.addCurve(to: CGPoint(x: 0.985, y: 0.0727), control1: CGPoint(x: 0.9801, y: 0.1909), control2: CGPoint(x: 1.0, y: 0.1287))
        path.addCurve(to: CGPoint(x: 0.8912, y: 0.0543), control1: CGPoint(x: 0.9687, y: 0.0119), control2: CGPoint(x: 0.9193, y: 0.0264))
        path.addCurve(to: CGPoint(x: 0.8515, y: 0.41), control1: CGPoint(x: 0.8251, y: 0.1199), control2: CGPoint(x: 0.8063, y: 0.3073))
        path.addCurve(to: CGPoint(x: 0.8151, y: 0.4652), control1: CGPoint(x: 0.8523, y: 0.4408), control2: CGPoint(x: 0.847, y: 0.4774))
        path.addCurve(to: CGPoint(x: 0.6135, y: 0.3255), control1: CGPoint(x: 0.7759, y: 0.4502), control2: CGPoint(x: 0.715, y: 0.3637))
        path.addCurve(to: CGPoint(x: 0.615, y: 0.323), control1: CGPoint(x: 0.6142, y: 0.3249), control2: CGPoint(x: 0.6147, y: 0.324))
        path.addCurve(to: CGPoint(x: 0.6745, y: 0.3256), control1: CGPoint(x: 0.6338, y: 0.3309), control2: CGPoint(x: 0.6573, y: 0.3383))
        path.addCurve(to: CGPoint(x: 0.6946, y: 0.2693), control1: CGPoint(x: 0.6828, y: 0.3194), control2: CGPoint(x: 0.7082, y: 0.2839))
        path.addCurve(to: CGPoint(x: 0.6794, y: 0.2896), control1: CGPoint(x: 0.6856, y: 0.2596), control2: CGPoint(x: 0.6745, y: 0.2757))
        path.addCurve(to: CGPoint(x: 0.6268, y: 0.292), control1: CGPoint(x: 0.6634, y: 0.2974), control2: CGPoint(x: 0.6413, y: 0.2934))
        path.addCurve(to: CGPoint(x: 0.5959, y: 0.2794), control1: CGPoint(x: 0.6162, y: 0.2909), control2: CGPoint(x: 0.6056, y: 0.2866))
        path.addCurve(to: CGPoint(x: 0.5772, y: 0.258), control1: CGPoint(x: 0.5896, y: 0.273), control2: CGPoint(x: 0.5833, y: 0.2659))
        path.addCurve(to: CGPoint(x: 0.5704, y: 0.2467), control1: CGPoint(x: 0.5749, y: 0.2544), control2: CGPoint(x: 0.5724, y: 0.251))
        path.addCurve(to: CGPoint(x: 0.5697, y: 0.2446), control1: CGPoint(x: 0.5701, y: 0.2461), control2: CGPoint(x: 0.57, y: 0.2452))
        path.addCurve(to: CGPoint(x: 0.5697, y: 0.2438), control1: CGPoint(x: 0.5696, y: 0.2443), control2: CGPoint(x: 0.5698, y: 0.2441))
        path.addCurve(to: CGPoint(x: 0.5624, y: 0.2191), control1: CGPoint(x: 0.5672, y: 0.2357), control2: CGPoint(x: 0.5643, y: 0.2276))
        path.addCurve(to: CGPoint(x: 0.5611, y: 0.1888), control1: CGPoint(x: 0.5597, y: 0.2096), control2: CGPoint(x: 0.5593, y: 0.1995))
        path.addCurve(to: CGPoint(x: 0.5792, y: 0.197), control1: CGPoint(x: 0.5745, y: 0.1815), control2: CGPoint(x: 0.5806, y: 0.1843))
        path.addCurve(to: CGPoint(x: 0.5832, y: 0.2008), control1: CGPoint(x: 0.5792, y: 0.2003), control2: CGPoint(x: 0.5816, y: 0.2014))
        path.addCurve(to: CGPoint(x: 0.5894, y: 0.1929), control1: CGPoint(x: 0.5862, y: 0.1997), control2: CGPoint(x: 0.5881, y: 0.1967))
        path.addCurve(to: CGPoint(x: 0.5904, y: 0.1902), control1: CGPoint(x: 0.5899, y: 0.1924), control2: CGPoint(x: 0.5903, y: 0.1915))
        path.addCurve(to: CGPoint(x: 0.5905, y: 0.1892), control1: CGPoint(x: 0.5905, y: 0.1899), control2: CGPoint(x: 0.5905, y: 0.1895))
        path.addCurve(to: CGPoint(x: 0.5905, y: 0.1647), control1: CGPoint(x: 0.5921, y: 0.1813), control2: CGPoint(x: 0.5917, y: 0.1712))
        path.addCurve(to: CGPoint(x: 0.5606, y: 0.1332), control1: CGPoint(x: 0.5865, y: 0.1415), control2: CGPoint(x: 0.5748, y: 0.135))
        path.addCurve(to: CGPoint(x: 0.5598, y: 0.1323), control1: CGPoint(x: 0.5605, y: 0.1328), control2: CGPoint(x: 0.56, y: 0.1327))
        path.addCurve(to: CGPoint(x: 0.5713, y: 0.1067), control1: CGPoint(x: 0.5622, y: 0.1229), control2: CGPoint(x: 0.5658, y: 0.1144))
        path.addCurve(to: CGPoint(x: 0.5963, y: 0.0832), control1: CGPoint(x: 0.5756, y: 0.1006), control2: CGPoint(x: 0.5878, y: 0.0844))
        path.addCurve(to: CGPoint(x: 0.6051, y: 0.1029), control1: CGPoint(x: 0.5918, y: 0.091), control2: CGPoint(x: 0.5961, y: 0.1011))
        path.addCurve(to: CGPoint(x: 0.625, y: 0.0626), control1: CGPoint(x: 0.6203, y: 0.1061), control2: CGPoint(x: 0.6284, y: 0.0837))
        path.addCurve(to: CGPoint(x: 0.5826, y: 0.0124), control1: CGPoint(x: 0.6204, y: 0.0349), control2: CGPoint(x: 0.6005, y: 0.014))
        path.addCurve(to: CGPoint(x: 0.5678, y: 0.0146), control1: CGPoint(x: 0.5779, y: 0.012), control2: CGPoint(x: 0.5729, y: 0.0128))
        path.addCurve(to: CGPoint(x: 0.5161, y: 0.0422), control1: CGPoint(x: 0.5492, y: 0.0136), control2: CGPoint(x: 0.5294, y: 0.0227))
        path.addCurve(to: CGPoint(x: 0.4948, y: 0.1416), control1: CGPoint(x: 0.4984, y: 0.0679), control2: CGPoint(x: 0.4929, y: 0.1056))
        path.addCurve(to: CGPoint(x: 0.4931, y: 0.1435), control1: CGPoint(x: 0.4942, y: 0.1422), control2: CGPoint(x: 0.4937, y: 0.1429))
        path.addCurve(to: CGPoint(x: 0.4917, y: 0.1431), control1: CGPoint(x: 0.4923, y: 0.1432), control2: CGPoint(x: 0.4917, y: 0.1431))
        path.addCurve(to: CGPoint(x: 0.4893, y: 0.1479), control1: CGPoint(x: 0.4917, y: 0.1431), control2: CGPoint(x: 0.4906, y: 0.1445))
        path.addCurve(to: CGPoint(x: 0.4708, y: 0.2015), control1: CGPoint(x: 0.4785, y: 0.1613), control2: CGPoint(x: 0.4712, y: 0.1784))
        path.addCurve(to: CGPoint(x: 0.4716, y: 0.2142), control1: CGPoint(x: 0.4707, y: 0.2058), control2: CGPoint(x: 0.4712, y: 0.21))
        path.addCurve(to: CGPoint(x: 0.342, y: 0.1571), control1: CGPoint(x: 0.4249, y: 0.2137), control2: CGPoint(x: 0.3873, y: 0.2018))
        path.addCurve(to: CGPoint(x: 0.3207, y: 0.0507), control1: CGPoint(x: 0.3236, y: 0.1389), control2: CGPoint(x: 0.2729, y: 0.0465))
        path.addCurve(to: CGPoint(x: 0.3207, y: 0.009), control1: CGPoint(x: 0.3383, y: 0.0523), control2: CGPoint(x: 0.338, y: 0.011))
        path.addCurve(to: CGPoint(x: 0.2314, y: 0.2387), control1: CGPoint(x: 0.2402, y: 0.0), control2: CGPoint(x: 0.1888, y: 0.127))
        path.addCurve(to: CGPoint(x: 0.3377, y: 0.3409), control1: CGPoint(x: 0.2545, y: 0.2992), control2: CGPoint(x: 0.2908, y: 0.337))
        path.addCurve(to: CGPoint(x: 0.3608, y: 0.3408), control1: CGPoint(x: 0.3459, y: 0.3416), control2: CGPoint(x: 0.3534, y: 0.3415))
        path.addCurve(to: CGPoint(x: 0.3031, y: 0.4105), control1: CGPoint(x: 0.3397, y: 0.3596), control2: CGPoint(x: 0.3202, y: 0.3824))
        path.addCurve(to: CGPoint(x: 0.289, y: 0.439), control1: CGPoint(x: 0.2977, y: 0.4193), control2: CGPoint(x: 0.2934, y: 0.4292))
        path.addCurve(to: CGPoint(x: 0.222, y: 0.5157), control1: CGPoint(x: 0.278, y: 0.4456), control2: CGPoint(x: 0.2441, y: 0.4726))
        path.addCurve(to: CGPoint(x: 0.1712, y: 0.6746), control1: CGPoint(x: 0.1981, y: 0.5623), control2: CGPoint(x: 0.185, y: 0.6199))
        path.addCurve(to: CGPoint(x: 0.1428, y: 0.7568), control1: CGPoint(x: 0.164, y: 0.7033), control2: CGPoint(x: 0.1558, y: 0.7332))
        path.addCurve(to: CGPoint(x: 0.1071, y: 0.8252), control1: CGPoint(x: 0.1305, y: 0.7793), control2: CGPoint(x: 0.1205, y: 0.8039))
        path.addCurve(to: CGPoint(x: 0.0616, y: 0.8892), control1: CGPoint(x: 0.0931, y: 0.8474), control2: CGPoint(x: 0.078, y: 0.8713))
        path.addCurve(to: CGPoint(x: 0.0034, y: 0.9214), control1: CGPoint(x: 0.0432, y: 0.909), control2: CGPoint(x: 0.0257, y: 0.9188))
        path.addCurve(to: CGPoint(x: 0.0014, y: 0.9281), control1: CGPoint(x: 0.0014, y: 0.9216), control2: CGPoint(x: 0.0, y: 0.9256))
        path.addCurve(to: CGPoint(x: 0.025, y: 0.9416), control1: CGPoint(x: 0.0071, y: 0.9379), control2: CGPoint(x: 0.0169, y: 0.9394))
        path.addCurve(to: CGPoint(x: 0.0643, y: 0.943), control1: CGPoint(x: 0.0382, y: 0.9451), control2: CGPoint(x: 0.051, y: 0.9449))
        path.addCurve(to: CGPoint(x: 0.1369, y: 0.9091), control1: CGPoint(x: 0.0907, y: 0.9391), control2: CGPoint(x: 0.1148, y: 0.9327))
        path.addCurve(to: CGPoint(x: 0.1613, y: 0.8773), control1: CGPoint(x: 0.1457, y: 0.8997), control2: CGPoint(x: 0.1544, y: 0.89))
        path.addCurve(to: CGPoint(x: 0.1733, y: 0.8609), control1: CGPoint(x: 0.1656, y: 0.8693), control2: CGPoint(x: 0.1665, y: 0.8603))
        path.addCurve(to: CGPoint(x: 0.1852, y: 0.8746), control1: CGPoint(x: 0.1787, y: 0.8614), control2: CGPoint(x: 0.1815, y: 0.8688))
        path.addCurve(to: CGPoint(x: 0.2084, y: 0.9352), control1: CGPoint(x: 0.1973, y: 0.8937), control2: CGPoint(x: 0.2064, y: 0.9077))
        path.addCurve(to: CGPoint(x: 0.2103, y: 0.9953), control1: CGPoint(x: 0.2099, y: 0.9555), control2: CGPoint(x: 0.2098, y: 0.975))
        path.addCurve(to: CGPoint(x: 0.2141, y: 0.9989), control1: CGPoint(x: 0.2104, y: 0.9979), control2: CGPoint(x: 0.2125, y: 1.0))
        path.addCurve(to: CGPoint(x: 0.2352, y: 0.9493), control1: CGPoint(x: 0.2244, y: 0.9913), control2: CGPoint(x: 0.2306, y: 0.9638))
        path.closeSubpath()
        path.move(to: CGPoint(x: 0.5063, y: 0.1532))
        path.addCurve(to: CGPoint(x: 0.5009, y: 0.1482), control1: CGPoint(x: 0.5044, y: 0.1511), control2: CGPoint(x: 0.5025, y: 0.1495))
        path.addCurve(to: CGPoint(x: 0.5145, y: 0.0576), control1: CGPoint(x: 0.4983, y: 0.1164), control2: CGPoint(x: 0.5009, y: 0.0841))
        path.addCurve(to: CGPoint(x: 0.5495, y: 0.0256), control1: CGPoint(x: 0.5232, y: 0.0408), control2: CGPoint(x: 0.5359, y: 0.0302))
        path.addCurve(to: CGPoint(x: 0.5277, y: 0.0542), control1: CGPoint(x: 0.5405, y: 0.033), control2: CGPoint(x: 0.5326, y: 0.043))
        path.addCurve(to: CGPoint(x: 0.5169, y: 0.1659), control1: CGPoint(x: 0.5122, y: 0.0893), control2: CGPoint(x: 0.5107, y: 0.1283))
        path.addCurve(to: CGPoint(x: 0.5063, y: 0.1532), control1: CGPoint(x: 0.5131, y: 0.1607), control2: CGPoint(x: 0.5095, y: 0.1563))
        path.closeSubpath()
        path.move(to: CGPoint(x: 0.3181, y: 0.3994))
        path.addCurve(to: CGPoint(x: 0.3756, y: 0.3382), control1: CGPoint(x: 0.3353, y: 0.3741), control2: CGPoint(x: 0.3548, y: 0.3543))
        path.addCurve(to: CGPoint(x: 0.4318, y: 0.3138), control1: CGPoint(x: 0.3942, y: 0.3341), control2: CGPoint(x: 0.4118, y: 0.3262))
        path.addCurve(to: CGPoint(x: 0.4927, y: 0.3081), control1: CGPoint(x: 0.4505, y: 0.3021), control2: CGPoint(x: 0.4727, y: 0.3123))
        path.addCurve(to: CGPoint(x: 0.5054, y: 0.3019), control1: CGPoint(x: 0.4976, y: 0.31), control2: CGPoint(x: 0.5005, y: 0.2994))
        path.addCurve(to: CGPoint(x: 0.5227, y: 0.3074), control1: CGPoint(x: 0.5112, y: 0.3049), control2: CGPoint(x: 0.5169, y: 0.3061))
        path.addCurve(to: CGPoint(x: 0.4927, y: 0.3081), control1: CGPoint(x: 0.513, y: 0.3072), control2: CGPoint(x: 0.503, y: 0.3073))
        path.addCurve(to: CGPoint(x: 0.3021, y: 0.472), control1: CGPoint(x: 0.3955, y: 0.3153), control2: CGPoint(x: 0.3363, y: 0.3915))
        path.addCurve(to: CGPoint(x: 0.2605, y: 0.677), control1: CGPoint(x: 0.2982, y: 0.4764), control2: CGPoint(x: 0.2542, y: 0.5764))
        path.addCurve(to: CGPoint(x: 0.2634, y: 0.7088), control1: CGPoint(x: 0.2612, y: 0.6873), control2: CGPoint(x: 0.2621, y: 0.6981))
        path.addCurve(to: CGPoint(x: 0.2587, y: 0.6506), control1: CGPoint(x: 0.2593, y: 0.6902), control2: CGPoint(x: 0.2589, y: 0.6581))
        path.addCurve(to: CGPoint(x: 0.2639, y: 0.5525), control1: CGPoint(x: 0.2579, y: 0.6179), control2: CGPoint(x: 0.2594, y: 0.5845))
        path.addCurve(to: CGPoint(x: 0.3181, y: 0.3994), control1: CGPoint(x: 0.2723, y: 0.4919), control2: CGPoint(x: 0.289, y: 0.4422))
        path.closeSubpath()
        return path
    }()
}
