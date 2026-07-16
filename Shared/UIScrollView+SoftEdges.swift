import UIKit

extension UIScrollView {

    func preferSoftTopEdge() {
        if #available(iOS 26.0, *) {
            topEdgeEffect.style = .soft
        }
    }
}
