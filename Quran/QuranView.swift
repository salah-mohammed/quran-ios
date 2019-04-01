//
//  QuranView.swift
//  Quran
//
//  Created by Mohamed Afifi on 5/12/16.
//
//  Quran for iOS is a Quran reading application for iOS.
//  Copyright (C) 2017  Quran.com
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
import MenuItemKit
import Popover_OC
import UIKit
import ViewConstrainer

private struct GestureInfo {
    let cell: QuranBasePageCollectionViewCell
    let indexPath: IndexPath
    let page: QuranPage
    let position: AyahWord.Position
}

protocol QuranViewDelegate: class {
    func quranViewHideBars()
    func onQuranViewTapped(_ quranView: QuranView)
    func quranView(_ quranView: QuranView, didSelectTextLinesToShare textLines: [String], sourceView: UIView, sourceRect: CGRect)
    func onErrorOccurred(error: Error)
    func onWordPointerTapped()
    func play(from: AyahNumber)
}

class QuranView: UIView, UIGestureRecognizerDelegate {

    weak var delegate: QuranViewDelegate?

    private weak var bottomBarConstraint: NSLayoutConstraint?

    private let dismissBarsTapGesture = UITapGestureRecognizer()
    private let bookmarksPersistence: BookmarksPersistence
    private let verseTextRetrieval: AnyInteractor<QuranShareData, [String]>
    private let wordByWordPersistence: WordByWordTranslationPersistence
    private let simplePersistence: SimplePersistence

    private var shareData: QuranShareData? {
        didSet {
            // remove old gestures
            oldValue?.gestures.forEach { $0.view?.removeGestureRecognizer($0) }

            // add new gestures
            shareData?.gestures.forEach { addGestureRecognizer($0) }
            shareData?.gestures.forEach { $0.delegate = self }
        }
    }

    lazy var audioView: DefaultAudioBannerView = {
        let audioView = DefaultAudioBannerView()
        self.addAutoLayoutSubview(audioView)
        self.bottomBarConstraint = audioView.vc
            .horizontalEdges()
            .bottom().constraint
        return audioView
    }()

    lazy var collectionView: UICollectionView = {
        let layout = QuranPageFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0

        let collectionView = ThemedCollectionView(frame: self.bounds, collectionViewLayout: layout)
        collectionView.kind = .backgroundOLED
        if #available(iOS 11.0, *) {
            collectionView.contentInsetAdjustmentBehavior = .never
        }
        if #available(iOS 9.0, *) {
            collectionView.semanticContentAttribute = .forceRightToLeft
        }
        self.addAutoLayoutSubview(collectionView)
        collectionView.vc
            .verticalEdges()
            .horizontalEdges(inset: -Layout.QuranCell.horizontalInset)

        collectionView.isPagingEnabled = true
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.ds_register(cellNib: QuranImagePageCollectionViewCell.self)
        collectionView.ds_register(cellNib: QuranTranslationCollectionPageCollectionViewCell.self)

        return collectionView
    }()

    private var _pointerTop: NSLayoutConstraint?
    private var _pointerLeft: NSLayoutConstraint?
    private var _pointerParentSize: CGSize = .zero
    private func setPointerTop(_ value: CGFloat) {
        _pointerTop?.constant = value
        _pointerParentSize = bounds.size
    }
    private var minX: CGFloat {
        return Layout.windowDirectionalSafeAreaInsets.leading
    }
    private var maxX: CGFloat {
        return bounds.width - Layout.windowDirectionalSafeAreaInsets.trailing
    }

    lazy var pointer: UIView = {
        let imageView = UIImageView()
        imageView.image = #imageLiteral(resourceName: "pointer-25").withRenderingMode(.alwaysTemplate)

        imageView.layer.shadowColor = Theme.Kind.labelWeak.color.cgColor
        imageView.layer.shadowOpacity = 0.6
        imageView.layer.shadowRadius = 3
        imageView.layer.shadowOffset = CGSize(width: 1, height: 1)

        let container = UIView()
        container.isHidden = true
        container.addAutoLayoutSubview(imageView)
        imageView.vc.center()

        self.addAutoLayoutSubview(container)
        self._pointerTop = container.vc
            .size(by: 44)
            .top().constraint
        self._pointerLeft = container.leftAnchor.constraint(equalTo: self.leftAnchor)
        self._pointerLeft?.isActive = true
        return container
    }()

    required init?(coder aDecoder: NSCoder) {
        unimplemented()
    }

    init(bookmarksPersistence: BookmarksPersistence,
         verseTextRetrieval: AnyInteractor<QuranShareData, [String]>,
         wordByWordPersistence: WordByWordTranslationPersistence,
         simplePersistence: SimplePersistence) {
        self.bookmarksPersistence = bookmarksPersistence
        self.verseTextRetrieval = verseTextRetrieval
        self.wordByWordPersistence = wordByWordPersistence
        self.simplePersistence = simplePersistence
        super.init(frame: .zero)
        setUp()
    }

    private func setUp() {
        clipsToBounds = true
        dismissBarsTapGesture.addTarget(self, action: #selector(onViewTapped(_:)))
        dismissBarsTapGesture.delegate = self
        addGestureRecognizer(dismissBarsTapGesture)

        sendSubviewToBack(collectionView)
        bringSubviewToFront(audioView)
        bringSubviewToFront(pointer)

        // Long press gesture on verses to select
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(onLongPress(_:))))

        // Prevent long tap gesture on audio bottom bar
        audioView.addGestureRecognizer(UILongPressGestureRecognizer(target: nil, action: nil))

        // pointer dragging
        let pointerPanGesture = UIPanGestureRecognizer(target: self, action: #selector(onPointerPanned(_:)))
        pointer.addGestureRecognizer(pointerPanGesture)

        // pointer tapping
        pointer.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(pointerTapped)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !pointer.isHidden && _pointerParentSize != bounds.size {
            setPointerTop(pointer.frame.minY * bounds.height / _pointerParentSize.height)
            // using bounds.height because it has been rotated but pointer.frame.minX has not
            if pointer.frame.minX > bounds.height / 2 {
                _pointerLeft?.constant = maxX - pointer.bounds.width
            } else {
                _pointerLeft?.constant = minX
            }
        }
    }

    func visibleIndexPath() -> IndexPath? {
        let offset = collectionView.contentOffset
        return collectionView.indexPathForItem(at: CGPoint(x: offset.x + bounds.width / 2, y: 0))
    }

    func setBarsHidden(_ hidden: Bool) {
        if let bottomBarConstraint = self.bottomBarConstraint {
            removeConstraint(bottomBarConstraint)
        }
        if hidden {
            bottomBarConstraint = self.vc.verticalLine(audioView, by: -1).constraint
        } else {
            bottomBarConstraint = audioView.vc.bottom().constraint
        }
    }

    @objc
    func onViewTapped(_ sender: UITapGestureRecognizer) {
        guard !audioView.bounds.contains(sender.location(in: audioView)) else {
            return
        }
        delegate?.onQuranViewTapped(self)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        return gestureRecognizer != dismissBarsTapGesture || !isFirstResponder // dismiss bars only if not first responder
    }

    // MARK: - MenuItems

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func onLongPress(_ sender: UILongPressGestureRecognizer) {
        guard sender.state == .began else {
            return
        }
        guard let info = gestureInfo(at: sender.location(in: self)) else {
            return
        }

        // set up dismiss gestures
        subviews.forEach { $0.isUserInteractionEnabled = false }

        let localPoint = sender.location(in: self)

        let tap = UITapGestureRecognizer(target: self, action: #selector(viewPannedOrTapped))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(viewPannedOrTapped))
        let shareData = QuranShareData(location: localPoint, gestures: [tap, pan], cell: info.cell, page: info.page, ayah: info.position.ayah)
        self.shareData = shareData

        // highlight the ayah UI
        info.cell.setHighlightedVerses([info.position.ayah], forType: .share)

        // become first responder
        assert(becomeFirstResponder(), "UIMenuController will not work with a view that cannot become first responder")

        UIMenuController.shared.menuItems = [
            createPlayMenuItem(ayah: shareData.ayah),
            configuredBookmarkMenuItem(shareData: shareData),
            createCopyMenuItem(),
            createShareMenuItem()
        ]
        UIMenuController.shared.setTargetRect(targetRect(for: localPoint), in: self)
        UIMenuController.shared.setMenuVisible(true, animated: true)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(resignFirstResponder),
                                               name: UIMenuController.willHideMenuNotification,
                                               object: nil)
    }

    private func gestureInfo(at point: CGPoint) -> GestureInfo? {
        let collectionLocalPoint = collectionView.convert(point, from: self)
        guard let indexPath = collectionView.indexPathForItem(at: collectionLocalPoint) else {
            return nil
        }
        guard let cell = collectionView.cellForItem(at: indexPath) as? QuranBasePageCollectionViewCell else {
            return nil
        }
        guard let page = cell.page else {
            return nil
        }
        let cellLocalPoint = cell.convert(point, from: self)
        guard let position = cell.ayahWordPosition(at: cellLocalPoint) else {
            return nil
        }
        return GestureInfo(cell: cell, indexPath: indexPath, page: page, position: position)
    }

    override var canBecomeFirstResponder: Bool {
        return true
    }

    override func resignFirstResponder() -> Bool {
        // update the model
        shareData?.cell.setHighlightedVerses(nil, forType: .share)

        // hide the menu controller
        NotificationCenter.default.removeObserver(self, name: UIMenuController.willHideMenuNotification, object: nil)
        UIMenuController.shared.setMenuVisible(false, animated: true)

        // remove gestures
        subviews.forEach { $0.isUserInteractionEnabled = true }

        shareData = nil

        return super.resignFirstResponder()
    }

    @objc
    private func viewPannedOrTapped() {
        // resign first responder
        _ = resignFirstResponder()
    }

    /// Did click on copy menu item
    private func copyVerse() {
        retrieveSelectedAyahText { textLines in
            let pasteBoard = UIPasteboard.general
            pasteBoard.string = textLines.joined(separator: "\n")
        }
    }

    /// Did click on share menu item
    private func shareVerse() {
        guard let shareData = shareData else {
            return
        }

        retrieveSelectedAyahText { textLines in
            self.delegate?.quranView(self,
                                     didSelectTextLinesToShare: textLines,
                                     sourceView: self,
                                     sourceRect: self.targetRect(for: shareData.location))
        }
    }

    private func createCopyMenuItem() -> UIMenuItem {
        return UIMenuItem(title: l("verseCopy")) { [weak self] _ in
            self?.copyVerse()
        }
    }

    private func createShareMenuItem() -> UIMenuItem {
        return UIMenuItem(title: l("verseShare")) { [weak self] _ in
            self?.shareVerse()
        }
    }

    private func createPlayMenuItem(ayah: AyahNumber) -> UIMenuItem {
        let image = #imageLiteral(resourceName: "ic_play").scaled(toHeight: 25)?.tintedImage(withColor: .white)
        return UIMenuItem(title: "Play", image: image) { [weak self] _ in
            Analytics.shared.playFrom(menu: true)
            self?.delegate?.play(from: ayah)
        }
    }

    private func configuredBookmarkMenuItem(shareData: QuranShareData) -> UIMenuItem {
        let isBookmarked = shareData.cell.highlightedVerse(forType: .bookmark)?.contains(shareData.ayah) ?? false
        if isBookmarked {
            let image = #imageLiteral(resourceName: "bookmark-filled").tintedImage(withColor: .bookmark())
            return UIMenuItem(title: "Unbookmark", image: image) { [weak self] _ in
                self?.removeAyahFromBookmarks(atPage: shareData.page.pageNumber, ayah: shareData.ayah, cell: shareData.cell)
            }
        } else {
            let image = #imageLiteral(resourceName: "bookmark-empty").tintedImage(withColor: .white)
            return UIMenuItem(title: "Bookmark", image: image) { [weak self] _ in
                self?.addAyahToBookmarks(atPage: shareData.page.pageNumber, ayah: shareData.ayah, cell: shareData.cell)
            }
        }
    }

    private func removeAyahFromBookmarks(atPage page: Int, ayah: AyahNumber, cell: QuranBasePageCollectionViewCell) {
        Analytics.shared.unbookmark(ayah: ayah)
        DispatchQueue.global()
            .async(.promise) { try self.bookmarksPersistence.removeAyahBookmark(atPage: page, ayah: ayah) }
            .done(on: .main) { _ -> Void in
                // remove bookmark from model
                var bookmarks = cell.highlightedVerse(forType: .bookmark) ?? Set()
                bookmarks.remove(ayah)
                cell.setHighlightedVerses(bookmarks, forType: .bookmark)
            }.cauterize(tag: "BookmarksPersistence.removeAyahBookmark")
    }

    private func addAyahToBookmarks(atPage page: Int, ayah: AyahNumber, cell: QuranBasePageCollectionViewCell) {
        Analytics.shared.bookmark(ayah: ayah)
        DispatchQueue.global()
            .async(.promise) { try self.bookmarksPersistence.insertAyahBookmark(forPage: page, ayah: ayah) }
            .done(on: .main) { _ -> Void in
                // add a bookmark to the model
                var bookmarks = cell.highlightedVerse(forType: .bookmark) ?? Set()
                bookmarks.insert(ayah)
                cell.setHighlightedVerses(bookmarks, forType: .bookmark)
            }.cauterize(tag: "BookmarksPersistence.insertAyahBookmark")
    }

    /**
     Get the current highlighted ayah text.
     */
    private func retrieveSelectedAyahText(completion: @escaping ([String]) -> Void) {
        guard let shareData = shareData else {
            return
        }

        verseTextRetrieval
            .execute(shareData)
            .map { $0 + [shareData.ayah.localizedName] + l("shareMarketingSuffix").components(separatedBy: "\n") }
            .done(on: .main, completion)
            .catch(on: .main) { (error) in
                self.delegate?.onErrorOccurred(error: error)
            }
    }

    private func targetRect(for point: CGPoint) -> CGRect {
        let size = CGSize(width: 20, height: 20)
        return CGRect(origin: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), size: size)
    }

    // MARK: - Word-by-word Pointer

    @objc
    func pointerTapped() {
        delegate?.onWordPointerTapped()
    }

    func showPointer() {
        pointer.isHidden = false

        setPointerTop(bounds.height)
        _pointerLeft?.constant = bounds.width / 2
        layoutIfNeeded()

        setPointerTop(bounds.height / 4)
        _pointerLeft?.constant = minX
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: [], animations: {
            self.layoutIfNeeded()
        }, completion: nil)
    }

    func hidePointer() {
        setPointerTop(bounds.height + 200)
        _pointerLeft?.constant = bounds.width / 2
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: [], animations: {
            self.layoutIfNeeded()
        }, completion: { _ in
            if self._pointerTop?.constant == self.bounds.height + 200 {
                self.pointer.isHidden = true
            }
        })
    }

    private var pointerPositionOld: CGPoint = .zero
    @objc
    private func onPointerPanned(_ gesture: UIPanGestureRecognizer) {

        switch gesture.state {
        case .began:
            delegate?.quranViewHideBars()
            pointerPositionOld = CGPoint(x: pointer.frame.minX, y: pointer.frame.minY)
        case .changed:
            let translation = gesture.translation(in: self)
            setPointerTop(pointerPositionOld.y + translation.y)
            _pointerLeft?.constant = pointerPositionOld.x + translation.x
            layoutIfNeeded()
            showTip(at: CGPoint(x: pointer.frame.maxX - 15, y: pointer.frame.minY + 15))
        case .ended, .cancelled, .failed:
            hideTip()

            let velocity = gesture.velocity(in: self)

            let goLeft: Bool
            if abs(velocity.x) > 100 {
                goLeft = velocity.x < 0
            } else {
                goLeft = pointer.center.x < bounds.width / 2
            }

            let finalY = max(10, min(bounds.height - pointer.bounds.height, velocity.y * 0.3 + pointer.frame.minY))
            let finalX = goLeft ? minX : maxX - pointer.bounds.width

            let y = finalY - pointer.frame.minY
            let x = finalX - pointer.frame.minX
            let springVelocity = abs(velocity.x) / sqrt(x * x + y * y)

            setPointerTop(finalY)
            _pointerLeft?.constant = finalX
            UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: springVelocity, options: [], animations: {
                self.layoutIfNeeded()
            }, completion: nil)

        case .possible: break
        }
    }

    private var lastWord: AyahWord?

    private func showTip(at point: CGPoint) {
        guard let info = gestureInfo(at: point) else {
            hideTip()
            return
        }
        info.cell.highlight(position: info.position)

        let frame = convert(info.position.frame, from: info.cell)

        let isUpward = frame.minY < 63
        let point = CGPoint(x: frame.midX, y: isUpward ? frame.maxY + 10 : frame.minY - 10)

        var word: AyahWord?
        if lastWord?.position == info.position {
            word = lastWord
            show(word: lastWord, at: point, isUpward: isUpward)
        } else {
            let textType = simplePersistence.valueForKey(.wordTranslationType)
            suppress {
                word = try wordByWordPersistence.getWord(for: info.position, type: AyahWord.TextType(rawValue: textType) ?? .translation)
            }
        }
        show(word: word, at: point, isUpward: isUpward)
    }

    private func show(word: AyahWord?, at point: CGPoint, isUpward: Bool) {
        if let text = word?.text {
            let action = PopoverAction(title: text, handler: nil)
            popover.show(to: point, isUpward: isUpward, with: [action])
        } else {
            hideTip(updateLastWord: false)
        }
        if let word = word {
            lastWord = word
        }
    }

    private func hideTip(updateLastWord: Bool = true) {
        if updateLastWord {
            lastWord = nil
            for cell in collectionView.visibleCells {
                (cell as? QuranBasePageCollectionViewCell)?.highlight(position: nil)
            }
        }
        popover.hideNoAnimation()
    }

    lazy var popover: PopoverView = {
        let popup = PopoverView(view: self)
        return popup
    }()
}
