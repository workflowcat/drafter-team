// Vision's names for a kept picture (pictures round, 24 November 2026): VNClassifyImageRequest on this Mac, about
// 18 ms a picture. Nothing leaves the Mac. The labels are kept beside the picture (History.lookClip); what they mean
// for a row: app/PictureLookRules.swift.
import Vision

enum PictureLook {
    /// The top labels over 0.3 confidence, at most 5 (nearly every screen gets "document" and "screenshot").
    static func labels(_ img: CGImage) -> [String] {
        let r = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: img).perform([r])
        return (r.results ?? []).filter { $0.confidence > 0.3 }.prefix(5).map(\.identifier)
    }
}
