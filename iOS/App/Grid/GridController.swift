import BrowserKit
import SwiftUI
import UIKit

/// The tab grid: two columns of cards, in the order of the tabs. Cards
/// fade out under the clock. Along the bottom, Settings and an address bar
/// that opens a new tab. It stays laid out under the page, so the page
/// always knows where its card is.
final class GridController: UIViewController, UICollectionViewDelegate {
    private let browser: Browser
    private let pictures: Pictures
    private unowned let screen: ScreenActions

    private lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: layout())
    private var cards: UICollectionViewDiffableDataSource<Int, UUID>!
    private let fade = BackdropFade()
    private let empty = UILabel()
    /// The grid's own bar, which rises as the grid comes.
    let bar = UIView()
    private var following: Observer?

    /// The tab whose page is on its way to or from its card: the page's
    /// picture stands in for the card's until it lands.
    var away: UUID? {
        didSet {
            for case let card as Card in collection.visibleCells { card.isAway = card.tab?.id == away }
        }
    }

    init(browser: Browser, pictures: Pictures, screen: ScreenActions) {
        self.browser = browser
        self.pictures = pictures
        self.screen = screen
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        collection.backgroundColor = .clear
        collection.delegate = self
        collection.alwaysBounceVertical = true
        collection.showsVerticalScrollIndicator = false
        collection.frame = view.bounds
        collection.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(collection)
        view.addSubview(fade)

        empty.text = "No Tabs"
        empty.font = .preferredFont(forTextStyle: .title3).withWeight(.medium)
        empty.textColor = .secondaryLabel
        empty.textAlignment = .center
        view.addSubview(empty)

        let content = UIHostingController(rootView: GridBar(screen: screen))
        addChild(content)
        content.view.backgroundColor = .clear
        content.view.frame = bar.bounds
        content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        bar.addSubview(content.view)
        view.addSubview(bar)
        content.didMove(toParent: self)

        let registration = UICollectionView.CellRegistration<Card, UUID> { [weak self] card, _, id in
            guard let self, let tab = browser.tabs.first(where: { $0.id == id }) else { return }
            card.show(tab, pictures: pictures) { [weak self] in await self?.browser.closeAsking(tab) ?? false }
            card.isAway = id == away
        }
        cards = UICollectionViewDiffableDataSource(collectionView: collection) { collection, index, id in
            collection.dequeueConfiguredReusableCell(using: registration, for: index, item: id)
        }
        following = Observer { [weak self] in self?.update() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        fade.layout(in: view.bounds, top: view.safeAreaInsets.top)
        empty.frame = view.bounds
        let height = Look.barHeight + view.safeAreaInsets.bottom
        bar.bounds = CGRect(x: 0, y: 0, width: view.bounds.width, height: height)
        bar.center = CGPoint(x: view.bounds.midX, y: view.bounds.maxY - height / 2)
    }

    /// Two cards to a row, each as tall as its picture and its title.
    private func layout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let width = (environment.container.effectiveContentSize.width - Card.spacing) / 2
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(Card.height(forWidth: width)))
            let row = NSCollectionLayoutGroup.horizontal(layoutSize: size, repeatingSubitem: NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(0.5), heightDimension: .fractionalHeight(1))), count: 2)
            row.interItemSpacing = .fixed(Card.spacing)
            let section = NSCollectionLayoutSection(group: row)
            section.interGroupSpacing = 18
            section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: Look.barHeight + 28, trailing: 16)
            return section
        }
    }

    /// The cards, in the order of the tabs. A closed tab's card goes and
    /// the rest close up, on the spring.
    private func update() {
        let ids = browser.tabs.map(\.id)
        empty.isHidden = !ids.isEmpty
        var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        guard snapshot.itemIdentifiers != cards.snapshot().itemIdentifiers else { return }
        let showing = view.window != nil && view.alpha > 0
        UIView.animate(springDuration: Move.duration, bounce: Move.bounce) {
            cards.apply(snapshot, animatingDifferences: showing)
        }
    }

    // MARK: The page's card

    /// Opening the grid scrolls it to the selected card.
    func scroll(to tab: Tab) {
        guard let index = cards.indexPath(for: tab.id) else { return }
        collection.scrollToItem(at: index, at: .centeredVertically, animated: false)
        collection.layoutIfNeeded()
    }

    /// Where `tab`'s picture sits in its card, in `view`'s coordinates:
    /// what the page shrinks into. Nil for a tab with no card yet.
    func picture(of tab: Tab, in view: UIView) -> CGRect? {
        guard let index = cards.indexPath(for: tab.id), let card = collection.layoutAttributesForItem(at: index) else { return nil }
        var frame = card.frame
        frame.size.height = Card.pictureHeight(forWidth: frame.width)
        return collection.convert(frame, to: view)
    }

    // MARK: Cards

    func collectionView(_ collection: UICollectionView, didSelectItemAt index: IndexPath) {
        collection.deselectItem(at: index, animated: false)
        guard let tab = (collection.cellForItem(at: index) as? Card)?.tab else { return }
        screen.show(tab)
    }

    /// Long press: Persist, Close Tab.
    func collectionView(_ collection: UICollectionView, contextMenuConfigurationForItemsAt indexes: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let index = indexes.first, let tab = (collection.cellForItem(at: index) as? Card)?.tab else { return nil }
        return UIContextMenuConfiguration(identifier: index as NSIndexPath, previewProvider: nil) { [browser] _ in
            var actions: [UIMenuElement] = []
            if !tab.isPopup {
                actions.append(UIAction(title: "Persist", image: UIImage(systemName: "lock"), state: tab.persist ? .on : .off) { _ in
                    tab.persist.toggle()
                })
            }
            actions.append(UIAction(title: "Close Tab", image: UIImage(systemName: "xmark"), attributes: .destructive) { _ in
                Task { await browser.closeAsking(tab) }
            })
            return UIMenu(children: actions)
        }
    }

    /// The menu lifts the card's picture, in its own shape.
    func collectionView(_ collection: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration, highlightPreviewForItemAt index: IndexPath) -> UITargetedPreview? {
        (collection.cellForItem(at: index) as? Card)?.preview
    }

    func collectionView(_ collection: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration, dismissalPreviewForItemAt index: IndexPath) -> UITargetedPreview? {
        (collection.cellForItem(at: index) as? Card)?.preview
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont(descriptor: fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]]), size: 0)
    }
}

/// Along the bottom of the grid: Settings and an address bar that opens a
/// new tab.
private struct GridBar: View {
    unowned let screen: ScreenActions

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                GlassCircle(symbol: "ellipsis", label: "Settings") { screen.showSettings() }
                Button {
                    screen.edit(.newTab)
                } label: {
                    Text(Look.placeholder)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 18)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 4)
    }
}
