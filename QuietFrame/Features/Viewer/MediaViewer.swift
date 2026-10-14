import SwiftData
import SwiftUI
import UIKit

func mediaPageState(pageIndex: Int, selectedIndex: Int) -> (isActive: Bool, shouldPrepare: Bool) {
    (pageIndex == selectedIndex, abs(pageIndex - selectedIndex) <= 1)
}

/// Page indexes to prepare, most urgent first: the selected page, then the next and previous pages.
func mediaPreparationOrder(selectedIndex: Int, count: Int) -> [Int] {
    guard (0..<count).contains(selectedIndex) else { return [] }
    return [selectedIndex, selectedIndex + 1, selectedIndex - 1].filter { (0..<count).contains($0) }
}

/// The new controls visibility after a page's video starts or stops playing, or nil when nothing changes.
func viewerControlsVisibility(
    afterPlaybackChange isPlaying: Bool,
    isSelectedPage: Bool,
    controlsAreVisible: Bool
) -> Bool? {
    guard isSelectedPage, controlsAreVisible == isPlaying else { return nil }
    return !isPlaying
}

struct MediaViewer: View {
    private enum LiftPhase {
        case idle
        case tracking
        case rejected
    }

    let items: [VaultMedia]
    let dependencies: AppDependencies
    let tileFrames: MediaTileFrames?
    let onCurrentMediaChange: ((UUID?) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverIsEnabled
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControlIsEnabled
    @AccessibilityFocusState private var infoButtonIsFocused: Bool
    @Query(sort: \VaultAlbum.position) private var albums: [VaultAlbum]
    @State private var selectedMediaID: UUID
    @State private var photoLoader: ViewerPhotoLoader
    @State private var playback: ViewerVideoPlayback
    @State private var controlsAreVisible = true
    @State private var detailsAreOpen = false
    @State private var mediaIsRaised = false
    @State private var selectedPhotoIsZoomed = false
    @State private var movingMedia: VaultMedia?
    @State private var shareLease: MediaExportLease?
    @State private var confirmsTrash = false
    @State private var confirmsPermanentDeletion = false
    @State private var isWorking = false
    @State private var userMessage: String?
    @State private var viewerFrame = CGRect.zero
    @State private var viewerOpacity = 0.0
    @State private var backdropLevel = 0.0
    @State private var chromeOpacity = 0.0
    @State private var pagerIsHidden = true
    @State private var flight: ViewerZoomFlight?
    @State private var transitionFallback: Task<Void, Never>?
    @State private var hasBegunOpening = false
    @State private var closesWhenOpened = false
    @State private var isDismissing = false
    @State private var hasDismissed = false
    @State private var liftPhase = LiftPhase.idle
    @State private var liftOrigin: CGFloat = 0
    @State private var liftTranslation: CGFloat = 0
    @State private var mediaIsLifted = false
    @GestureState private var dismissDragIsActive = false

    init(
        items: [VaultMedia],
        initialMediaID: UUID,
        dependencies: AppDependencies,
        tileFrames: MediaTileFrames? = nil,
        onCurrentMediaChange: ((UUID?) -> Void)? = nil
    ) {
        self.items = items
        self.dependencies = dependencies
        self.tileFrames = tileFrames
        self.onCurrentMediaChange = onCurrentMediaChange
        _selectedMediaID = State(initialValue: initialMediaID)
        _photoLoader = State(initialValue: ViewerPhotoLoader(storage: dependencies.secureStorage))
        _playback = State(initialValue: ViewerVideoPlayback())
    }

    private var selectedMedia: VaultMedia? {
        items.first { $0.id == selectedMediaID }
    }

    private var selectedIndex: Int {
        items.firstIndex { $0.id == selectedMediaID } ?? items.startIndex
    }

    private var photoRequests: [ViewerPhotoRequest] {
        mediaPreparationOrder(selectedIndex: selectedIndex, count: items.count)
            .map { items[$0] }
            .filter { $0.mediaType == .photo }
            .map { ViewerPhotoRequest(media: $0) }
    }

    var body: some View {
        GeometryReader { proxy in
            let windowFrame = proxy.frame(in: .global)
            viewerContent(in: windowFrame, safeAreaInsets: proxy.safeAreaInsets)
                .onAppear { viewerFrame = windowFrame }
                .onChange(of: windowFrame) { _, newFrame in viewerFrame = newFrame }
        }
        .opacity(viewerOpacity)
        .statusBarHidden(!controlsAreVisible)
        .persistentSystemOverlays(controlsAreVisible ? .automatic : .hidden)
        .onAppear { photoLoader.prepare(photoRequests) }
        .onAppear {
            onCurrentMediaChange?(selectedMediaID)
            beginOpening()
        }
        .onDisappear {
            photoLoader.releaseAll()
            playback.release()
        }
        .onDisappear { transitionFallback?.cancel() }
        .onChange(of: photoRequests) { _, requests in
            photoLoader.prepare(requests)
        }
        .onChange(of: selectedMediaID) { _, mediaID in
            selectedPhotoIsZoomed = false
            controlsAreVisible = true
            setDetails(open: false, animated: false)
            playback.pause()
            onCurrentMediaChange?(mediaID)
        }
        .onChange(of: playback.isPlaying) { _, isPlaying in
            updateVideoPlayback(isPlaying)
        }
        .onChange(of: dismissDragIsActive) { _, isActive in
            if !isActive { Task { liftDidStop() } }
        }
        .sheet(item: $movingMedia) { media in
            AlbumDestinationPicker(albums: albums, currentAlbumID: media.album?.id) { albumID in
                move(media: media, to: albumID)
                movingMedia = nil
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(QuietFrameTheme.elevated)
            .presentationCornerRadius(QuietFrameTheme.sheetCornerRadius)
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $shareLease, onDismiss: {
            shareLease?.cleanup()
            shareLease = nil
        }) { lease in
            ShareSheet(urls: lease.urls) {
                lease.cleanup()
                shareLease = nil
            }
        }
        .confirmationDialog(
            "Move this item to Trash?",
            isPresented: $confirmsTrash,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { trashSelectedMedia() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The encrypted item can be restored until it expires.")
        }
        .confirmationDialog(
            "Permanently delete this item?",
            isPresented: $confirmsPermanentDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete permanently", role: .destructive) { permanentlyDeleteSelectedMedia() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the encrypted file from this device and cannot be undone.")
        }
        .alert("QuietFrame", isPresented: messageIsPresented) {
            Button("OK", role: .cancel) { userMessage = nil }
        } message: {
            Text(userMessage ?? "The action could not be completed.")
        }
        .accessibilityIdentifier("media-viewer")
        .accessibilityAction(named: "Close Viewer") { closeViewer() }
        .accessibilityAction(.magicTap) { togglePlayback() }
    }

    private func viewerContent(in windowFrame: CGRect, safeAreaInsets: EdgeInsets) -> some View {
        let viewerBounds = CGRect(origin: .zero, size: windowFrame.size)
        let liftProgress = dismissProgress(translation: liftTranslation, height: windowFrame.height)
        let panelTop = detailsPanelTop(viewerHeight: windowFrame.height, topBarBottom: QuietFrameTheme.controlHeight)
        let raisedOffset = selectedMediaDetailsOffset(viewerBounds: viewerBounds, panelTop: panelTop)
        return ZStack {
            QuietFrameTheme.background
                .opacity(backdropLevel * backdropOpacity(translation: liftTranslation, height: windowFrame.height))
                .ignoresSafeArea()

            mediaPager
                .scaleEffect(dragScale(progress: liftProgress, reduceMotion: reduceMotion))
                .offset(y: dismissDragOffset(translation: liftTranslation) + raisedOffset)
                .opacity(pagerIsHidden ? 0 : 1)
                .allowsHitTesting(!detailsAreOpen)
                .accessibilityHidden(detailsAreOpen)

            if detailsAreOpen {
                detailsBackdrop(panelTop: panelTop)
                    .transition(.opacity)
            }

            if let flight {
                ViewerZoomFlyer(
                    image: flight.image,
                    from: flight.from.rect(imageSize: flight.image.size, viewerFrame: windowFrame),
                    to: flight.to.rect(imageSize: flight.image.size, viewerFrame: windowFrame),
                    fromCornerRadius: flight.fromCornerRadius,
                    toCornerRadius: flight.toCornerRadius,
                    fadesOut: flight.fadesOut,
                    animation: flight.animation
                ) {
                    finishFlight(flight.id)
                }
                .id(flight.id)
                .transition(.identity)
            }

            if controlsAreVisible {
                ViewerChrome(
                    media: selectedMedia,
                    items: items,
                    thumbnailService: dependencies.thumbnailService,
                    playback: playback,
                    isWorking: isWorking,
                    detailsAreOpen: detailsAreOpen,
                    safeAreaInsets: safeAreaInsets,
                    infoButtonFocus: $infoButtonIsFocused,
                    onClose: closeViewer,
                    onToggleDetails: { setDetails(open: !detailsAreOpen) },
                    onSelect: { selectedMediaID = $0 },
                    onAction: perform
                )
                .opacity(chromeOpacity)
                .allowsHitTesting(chromeOpacity > 0)
                .transition(.opacity)
            }

            if detailsAreOpen, let selectedMedia {
                ViewerDetailsPanel(media: selectedMedia, displaySize: displaySize(for: selectedMedia)) {
                    closeDetailsFromPanel()
                }
                .frame(height: max(windowFrame.height - panelTop, 0))
                .frame(maxHeight: .infinity, alignment: .bottom)
                .transition(detailsPanelTransition)
            }
        }
        .allowsHitTesting(!isDismissing)
    }

    private var mediaPager: some View {
        let selectedIndex = self.selectedIndex
        return TabView(selection: $selectedMediaID) {
            ForEach(Array(items.enumerated()), id: \.element.id) { pageIndex, media in
                let pageState = mediaPageState(pageIndex: pageIndex, selectedIndex: selectedIndex)
                SecureMediaPage(
                    media: media,
                    isActive: pageState.isActive,
                    shouldPrepare: pageState.shouldPrepare,
                    storage: dependencies.secureStorage,
                    photoLoader: photoLoader,
                    playback: playback,
                    onTap: toggleControls,
                    onPhotoZoomChanged: { updatePhotoZoom($0, mediaID: media.id) },
                    thumbnailService: dependencies.thumbnailService,
                    isLifted: pageState.isActive && mediaIsLifted
                )
                .tag(media.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .simultaneousGesture(dismissGesture)
    }

    /// Catches taps and downward drags on the raised media to put it back, and fades it into the panel.
    private func detailsBackdrop(panelTop: CGFloat) -> some View {
        let fadeHeight = min(100, panelTop)
        return VStack(spacing: 0) {
            Color.clear
                .frame(height: panelTop - fadeHeight)
            LinearGradient(
                stops: [
                    .init(color: QuietFrameTheme.night.opacity(0), location: 0),
                    .init(color: QuietFrameTheme.night.opacity(0.55), location: 0.55),
                    .init(color: QuietFrameTheme.night, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: fadeHeight)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { setDetails(open: false) }
        .gesture(detailsDismissGesture)
        .accessibilityHidden(true)
    }

    private var detailsPanelTransition: AnyTransition {
        reduceMotion ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .offset(y: 28))
    }

    /// A zoomed photo fills the viewer, so it stays put and the panel covers its lower part.
    private func selectedMediaDetailsOffset(viewerBounds: CGRect, panelTop: CGFloat) -> CGFloat {
        guard mediaIsRaised, !selectedPhotoIsZoomed, let media = selectedMedia else { return 0 }
        return detailsMediaOffset(mediaSize: displaySize(for: media), viewerBounds: viewerBounds, panelTop: panelTop)
    }

    /// The decoded image's size when there is one, since stored photo dimensions ignore EXIF orientation.
    private func displaySize(for media: VaultMedia) -> CGSize {
        zoomImage(for: media)?.size ?? CGSize(width: media.pixelWidth, height: media.pixelHeight)
    }

    private var messageIsPresented: Binding<Bool> {
        Binding(get: { userMessage != nil }, set: { if !$0 { userMessage = nil } })
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .global)
            .updating($dismissDragIsActive) { _, isActive, _ in isActive = true }
            .onChanged { value in updateLift(value) }
            .onEnded { value in endLift(value) }
    }

    private var detailsDismissGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .global)
            .onEnded { value in
                guard shouldCloseDetails(translation: value.translation.height, velocity: value.velocity.height)
                else { return }
                setDetails(open: false)
            }
    }

    private var presentsModal: Bool {
        movingMedia != nil || shareLease != nil
            || confirmsTrash || confirmsPermanentDeletion || userMessage != nil
    }

    private var canLiftMedia: Bool {
        !selectedPhotoIsZoomed && !isWorking && !isDismissing && flight == nil && !presentsModal && !detailsAreOpen
    }

    private func updateLift(_ value: DragGesture.Value) {
        switch liftPhase {
        case .rejected:
            return
        case .idle:
            let translation = value.translation
            guard abs(translation.height) > abs(translation.width), canLiftMedia else {
                liftPhase = .rejected
                return
            }
            liftPhase = .tracking
            liftOrigin = translation.height
            mediaIsLifted = true
        case .tracking:
            break
        }
        liftTranslation = value.translation.height - liftOrigin
        if liftTranslation > 0, chromeOpacity > 0 {
            withAnimation(.easeOut(duration: 0.1)) { chromeOpacity = 0 }
        }
    }

    private func endLift(_ value: DragGesture.Value) {
        let phase = liftPhase
        liftPhase = .idle
        guard phase == .tracking else { return }
        let translation = value.translation.height
        let velocity = value.velocity.height
        if !selectedPhotoIsZoomed, shouldDismiss(translation: translation, velocity: velocity) {
            closeViewer()
            return
        }
        if !selectedPhotoIsZoomed, shouldOpenDetails(translation: translation, velocity: velocity) {
            setDetails(open: true)
        }
        settleLift()
    }

    private func liftDidStop() {
        let phase = liftPhase
        liftPhase = .idle
        if phase == .tracking, !isDismissing {
            settleLift()
        }
    }

    private func settleLift() {
        withAnimation(.easeOut(duration: 0.16)) { chromeOpacity = 1 }
        guard liftTranslation != 0 else {
            mediaIsLifted = false
            return
        }
        withAnimation(.spring(duration: 0.26, bounce: 0)) {
            liftTranslation = 0
        } completion: {
            if liftPhase != .tracking, !isDismissing {
                withoutAnimation { mediaIsLifted = false }
            }
        }
    }

    /// Opening raises the media and brings the panel up; closing is faster. Reduce Motion only fades the panel.
    private func setDetails(open isOpen: Bool, animated: Bool = true) {
        guard detailsAreOpen != isOpen || mediaIsRaised != isOpen else { return }
        guard animated else {
            withoutAnimation {
                showDetails(isOpen)
                mediaIsRaised = isOpen
            }
            return
        }
        if reduceMotion {
            withoutAnimation { mediaIsRaised = isOpen }
            withAnimation(ViewerZoomMotion.easeOut(duration: 0.2)) { showDetails(isOpen) }
        } else {
            withAnimation(ViewerZoomMotion.easeOut(duration: isOpen ? 0.3 : 0.2)) {
                showDetails(isOpen)
                mediaIsRaised = isOpen
            }
        }
    }

    private func showDetails(_ isOpen: Bool) {
        if isOpen {
            controlsAreVisible = true
        }
        detailsAreOpen = isOpen
    }

    private func beginOpening() {
        guard !hasBegunOpening else { return }
        hasBegunOpening = true
        guard !reduceMotion,
              let media = selectedMedia,
              let tileFrame = tileFrames?.frame(for: media.id),
              let thumbnail = dependencies.thumbnailService.cachedImage(for: media) else {
            backdropLevel = 1
            chromeOpacity = 1
            pagerIsHidden = false
            withAnimation(.easeOut(duration: ViewerZoomMotion.fadeDuration)) { viewerOpacity = 1 }
            return
        }
        viewerOpacity = 1
        launch(ViewerZoomFlight(
            purpose: .opening,
            image: thumbnail,
            from: .window(tileFrame),
            to: .fitted,
            fromCornerRadius: QuietFrameTheme.tileCornerRadius,
            toCornerRadius: 0,
            duration: ViewerZoomMotion.openDuration,
            animation: ViewerZoomMotion.drawer(duration: ViewerZoomMotion.openDuration)
        ))
        withAnimation(ViewerZoomMotion.easeOut(duration: ViewerZoomMotion.backdropDuration)) {
            backdropLevel = 1
        }
        withAnimation(.easeOut(duration: 0.16).delay(0.12)) { chromeOpacity = 1 }
    }

    private func closeViewer() {
        guard !isDismissing else { return }
        if flight?.purpose == .opening {
            closesWhenOpened = true
            withAnimation(.easeOut(duration: 0.1)) { chromeOpacity = 0 }
            return
        }
        let viewerBounds = CGRect(origin: .zero, size: viewerFrame.size)
        guard !reduceMotion,
              !selectedPhotoIsZoomed,
              !viewerBounds.isEmpty,
              let media = selectedMedia,
              let image = zoomImage(for: media) else {
            fadeOutAndDismiss(revealsTile: true)
            return
        }
        isDismissing = true
        let fitted = aspectFitRect(imageSize: image.size, in: viewerBounds)
        let panelTop = detailsPanelTop(viewerHeight: viewerBounds.height, topBarBottom: QuietFrameTheme.controlHeight)
        let raisedOffset = mediaIsRaised
            ? detailsMediaOffset(mediaSize: image.size, viewerBounds: viewerBounds, panelTop: panelTop)
            : 0
        let start = dismissDragRect(
            fitting: fitted,
            in: viewerBounds,
            translation: liftTranslation,
            reduceMotion: reduceMotion
        )
        .offsetBy(dx: 0, dy: raisedOffset)
        setDetails(open: false, animated: false)
        pagerIsHidden = true
        withAnimation(.easeOut(duration: 0.1)) { chromeOpacity = 0 }

        if let tileFrame = visibleTileFrame(for: media.id, in: viewerBounds) {
            launch(ViewerZoomFlight(
                purpose: .closing,
                image: image,
                from: .viewer(start),
                to: .viewer(tileFrame),
                fromCornerRadius: 0,
                toCornerRadius: QuietFrameTheme.tileCornerRadius,
                duration: ViewerZoomMotion.returnDuration,
                animation: ViewerZoomMotion.easeOut(duration: ViewerZoomMotion.returnDuration)
            ))
            withAnimation(ViewerZoomMotion.easeOut(duration: ViewerZoomMotion.backdropDuration)) {
                backdropLevel = 0
            }
        } else {
            launch(ViewerZoomFlight(
                purpose: .closing,
                image: image,
                from: .viewer(start),
                to: .viewer(start.offsetBy(dx: 0, dy: 80)),
                fromCornerRadius: 0,
                toCornerRadius: 0,
                fadesOut: true,
                duration: ViewerZoomMotion.slideAwayDuration,
                animation: ViewerZoomMotion.easeOut(duration: ViewerZoomMotion.slideAwayDuration)
            ))
            withAnimation(ViewerZoomMotion.easeOut(duration: ViewerZoomMotion.slideAwayDuration)) {
                backdropLevel = 0
            }
        }
    }

    /// Used when the item leaves the grid or the media has no place to zoom back to.
    private func fadeOutAndDismiss(revealsTile: Bool) {
        guard !isDismissing else { return }
        isDismissing = true
        if revealsTile {
            onCurrentMediaChange?(nil)
        }
        withAnimation(.easeOut(duration: ViewerZoomMotion.fadeDuration)) {
            viewerOpacity = 0
        } completion: {
            dismissWithoutAnimation(revealingTile: false)
        }
        scheduleTransitionFallback(after: ViewerZoomMotion.fadeDuration)
    }

    private func zoomImage(for media: VaultMedia) -> UIImage? {
        if let image = photoLoader.image(for: media.id) {
            return image
        }
        if media.mediaType == .photo, photoLoader.failureMessage(for: media.id) != nil {
            return nil
        }
        return dependencies.thumbnailService.cachedImage(for: media)
    }

    private func visibleTileFrame(for mediaID: UUID, in viewerBounds: CGRect) -> CGRect? {
        guard let windowFrame = tileFrames?.frame(for: mediaID),
              isLandableTileFrame(windowFrame, viewport: tileFrames?.viewport) else { return nil }
        let tileFrame = windowFrame.offsetBy(dx: -viewerFrame.minX, dy: -viewerFrame.minY)
        return tileFrame.intersects(viewerBounds) ? tileFrame : nil
    }

    private func launch(_ newFlight: ViewerZoomFlight) {
        flight = newFlight
        scheduleTransitionFallback(after: newFlight.duration)
    }

    private func finishFlight(_ id: UUID) {
        guard let flight, flight.id == id else { return }
        switch flight.purpose {
        case .opening:
            transitionFallback?.cancel()
            transitionFallback = nil
            withoutAnimation {
                pagerIsHidden = false
                self.flight = nil
            }
            if closesWhenOpened {
                closesWhenOpened = false
                closeViewer()
            }
        case .closing:
            dismissWithoutAnimation(revealingTile: true)
        }
    }

    /// Finishes a transition whose animation completion never arrives, so the viewer can't get stuck.
    private func scheduleTransitionFallback(after duration: TimeInterval) {
        transitionFallback?.cancel()
        let delay = UInt64((duration + 0.3) * 1_000_000_000)
        transitionFallback = Task {
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            if let flight {
                finishFlight(flight.id)
            } else if isDismissing {
                dismissWithoutAnimation(revealingTile: false)
            }
        }
    }

    private func dismissWithoutAnimation(revealingTile: Bool) {
        guard !hasDismissed else { return }
        hasDismissed = true
        transitionFallback?.cancel()
        withoutAnimation {
            if revealingTile {
                onCurrentMediaChange?(nil)
            }
            dismiss()
        }
    }

    private func withoutAnimation(_ changes: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, changes)
    }

    private func toggleControls() {
        guard !detailsAreOpen else {
            setDetails(open: false)
            return
        }
        withAnimation(controlsAnimation(showing: !controlsAreVisible)) {
            controlsAreVisible.toggle()
        }
    }

    /// The chrome leaves faster than it arrives; with Reduce Motion it just appears and disappears.
    private func controlsAnimation(showing: Bool) -> Animation? {
        reduceMotion ? nil : ViewerZoomMotion.easeOut(duration: showing ? 0.26 : 0.18)
    }

    /// The panel's own close actions hand VoiceOver focus back to the info button once the panel has gone.
    private func closeDetailsFromPanel() {
        setDetails(open: false)
        Task {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            infoButtonIsFocused = true
        }
    }

    private func updatePhotoZoom(_ isZoomed: Bool, mediaID: UUID) {
        guard mediaID == selectedMediaID else { return }
        selectedPhotoIsZoomed = isZoomed
    }

    /// VoiceOver and Switch Control keep the chrome while a video plays, since it holds the only Pause control.
    private func updateVideoPlayback(_ isPlaying: Bool) {
        let keepsControls = playback.isScrubbing || detailsAreOpen || voiceOverIsEnabled || switchControlIsEnabled
        guard !isPlaying || !keepsControls else { return }
        guard let visibility = viewerControlsVisibility(
            afterPlaybackChange: isPlaying,
            isSelectedPage: selectedMedia?.mediaType == .video,
            controlsAreVisible: controlsAreVisible
        ) else { return }
        withAnimation(controlsAnimation(showing: visibility)) {
            controlsAreVisible = visibility
        }
    }

    private func togglePlayback() {
        guard let selectedMedia, selectedMedia.mediaType == .video,
              playback.unavailableMediaID != selectedMedia.id else { return }
        playback.togglePlayback()
    }

    private func perform(_ action: ViewerAction) {
        guard let selectedMedia else { return }
        switch action {
        case .favorite:
            favorite(selectedMedia)
        case .share:
            share(selectedMedia)
        case .saveToPhotos:
            saveToPhotos(selectedMedia)
        case .move:
            movingMedia = selectedMedia
        case .moveToTrash:
            confirmsTrash = true
        case .restore:
            restoreSelectedMedia()
        case .deletePermanently:
            confirmsPermanentDeletion = true
        case .togglePlayback:
            togglePlayback()
        }
    }

    private func favorite(_ media: VaultMedia) {
        do {
            try dependencies.repository.setFavorite(mediaID: media.id, isFavorite: !media.isFavorite)
        } catch {
            userMessage = VaultError.persistenceFailure.localizedDescription
        }
    }

    private func move(media: VaultMedia, to albumID: UUID?) {
        do {
            try dependencies.albumService.moveMedia(ids: [media.id], toAlbumID: albumID)
        } catch {
            userMessage = (error as? VaultError)?.localizedDescription
                ?? VaultError.persistenceFailure.localizedDescription
        }
    }

    private func share(_ media: VaultMedia) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            do {
                shareLease = try await dependencies.mediaExportService.prepareForSharing(mediaIDs: [media.id])
            } catch {
                userMessage = (error as? VaultError)?.localizedDescription
                    ?? VaultError.exportFailed.localizedDescription
            }
            isWorking = false
        }
    }

    private func saveToPhotos(_ media: VaultMedia) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            do {
                try await dependencies.mediaExportService.saveToPhotos(mediaIDs: [media.id])
                userMessage = "Saved to Photos."
            } catch {
                userMessage = (error as? VaultError)?.localizedDescription
                    ?? VaultError.exportFailed.localizedDescription
            }
            isWorking = false
        }
    }

    private func trashSelectedMedia() {
        guard let selectedMedia, !isWorking else { return }
        isWorking = true
        Task {
            do {
                try await dependencies.trashService.moveToTrash(ids: [selectedMedia.id])
                fadeOutAndDismiss(revealsTile: false)
            } catch {
                userMessage = (error as? VaultError)?.localizedDescription
                    ?? VaultError.fileOperationFailed.localizedDescription
                isWorking = false
            }
        }
    }

    private func restoreSelectedMedia() {
        guard let selectedMedia, !isWorking else { return }
        isWorking = true
        Task {
            do {
                try await dependencies.trashService.restore(ids: [selectedMedia.id])
                fadeOutAndDismiss(revealsTile: false)
            } catch {
                userMessage = (error as? VaultError)?.localizedDescription
                    ?? VaultError.fileOperationFailed.localizedDescription
                isWorking = false
            }
        }
    }

    private func permanentlyDeleteSelectedMedia() {
        guard let selectedMedia, !isWorking else { return }
        isWorking = true
        Task {
            do {
                try await dependencies.trashService.permanentlyDelete(ids: [selectedMedia.id])
                dependencies.thumbnailService.clearCache()
                fadeOutAndDismiss(revealsTile: false)
            } catch {
                userMessage = (error as? VaultError)?.localizedDescription
                    ?? VaultError.fileOperationFailed.localizedDescription
                isWorking = false
            }
        }
    }
}
