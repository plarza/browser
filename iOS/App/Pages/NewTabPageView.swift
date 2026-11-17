import BrowserKit
import SwiftUI
import UIKit

/// What a tab with nowhere to go shows: the picture, colour or blank
/// chosen in Settings.
final class NewTabPageView: UIView {
    private let picture = UIImageView()
    private var following: Observer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        picture.contentMode = .scaleAspectFill
        picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        picture.frame = bounds
        addSubview(picture)
        following = Observer { [weak self] in self?.show() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func show() {
        let settings = Preferences.shared.settings
        // Read so a newly chosen picture under the same setting shows too.
        _ = Preferences.shared.newTabImageVersion
        picture.image = nil
        switch settings.newTabPage {
        case .image:
            backgroundColor = .systemBackground
            picture.image = Settings.newTabImageInUse.flatMap { UIImage(contentsOfFile: $0.path) }
        case .color:
            backgroundColor = UIColor(Color(hex: settings.newTabColor))
        case .blank:
            backgroundColor = .systemBackground
        }
    }
}
