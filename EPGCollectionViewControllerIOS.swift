/// EPGCollectionViewController.swift

import UIKit
import Combine

extension Notification.Name {
    static let currentChannelDidChange = Notification.Name("currentChannelDidChange")
    static let customEPGMappingChanged = Notification.Name("CustomEPGMappingChanged")
}

// MARK: - Row Focus Anchor View
class EPGRowFocusAnchorView: UICollectionReusableView {
    override var canBecomeFocused: Bool { return true }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        self.backgroundColor = .clear
        self.isUserInteractionEnabled = true
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Controller Definition
final class EPGCollectionViewController: UICollectionViewController, UICollectionViewDataSourcePrefetching {
    
    // MARK: - Properties
    var epgViewModel: EPGViewModel!
    var playerManager: PlayerManager?
    var onChannelTapped: ((Channel) -> Void)?
    var onEventTapped: ((EPGEvent, Channel?) -> Void)?
    var onEventFocused: ((Channel, EPGEvent) -> Void)?
    
    #if os(tvOS)
    var channelColumnWidth: CGFloat = 500
    var timeHeaderHeight: CGFloat = 72
    var eventCardHourWidth: CGFloat = 1150
    var channelRowHeight: CGFloat = 180
    
    private var lastFocusedIndexPath: IndexPath?
    private var lastFocusedTime: Date?
    #else
    var channelColumnWidth: CGFloat = 85
    var timeHeaderHeight: CGFloat = 44
    var eventCardHourWidth: CGFloat = 190
    var channelRowHeight: CGFloat = 60
    #endif
    
    var expandedEventIndexPath: IndexPath?
    
    var currentPlayingChannelID: Channel.ID?
    
    private var isVisible = false

    var epgMappingMode: Bool = false
    var customDataManager: CustomDataManager?

    private var lastLayoutInvalidateTime: TimeInterval = 0
    private var lastKnownBounds: CGRect = .zero
    private var isUpdatingData = false
    private var pendingReloadAfterUpdate = false
    private var isShowingSkeletons: Bool = false

    private(set) var lastKnownChannelCount = 0
    private(set) var lastKnownEventCount = 0
    private(set) var lastKnownHoursCount = 0

    private var suppressEmptyTransitionUntil: Date?
    private var lastReloadTime: TimeInterval = 0
    private let minReloadInterval: TimeInterval = 0.12
    private let skeletonRowsDefault = 12

    // FIX: Using dynamic overlay pools instead of rendering all 3,000+ views
    private var stickyChannelNameOverlays: [EPGChannelNameOverlayView] = []
    
    private var layoutInvalidationWorkItem: DispatchWorkItem?
    private var reloadWorkItem: DispatchWorkItem?
    
    private var channelEventCumulativeCounts: [Int] = []
    private var flatTotalEventCount: Int = 0
    
    private var pendingPartialReloadChannelIDs: Set<Channel.ID> = []
    private var partialReloadWorkItem: DispatchWorkItem?
    
    private var reorderPickedChannelIndex: Int?
    
    private var favouritesCacheReadyObserver: AnyCancellable?

    var iphoneChannelNameOverlayHeight: CGFloat {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return 0 }
        return max(12.0, min(40.0, channelRowHeight * 0.28))
    }

    // MARK: - Lifecycle
    override init(collectionViewLayout layout: UICollectionViewLayout) {
        super.init(collectionViewLayout: layout)
    }

    convenience init() {
        let layout = EPGCollectionViewLayout()
        self.init(collectionViewLayout: layout)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented" ) }

    override func viewDidLoad() {
        super.viewDidLoad()
        
        #if os(tvOS)
        self.collectionView.remembersLastFocusedIndexPath = true
        self.collectionView.prefetchDataSource = self
        self.collectionView.isPrefetchingEnabled = true
        self.collectionView.clipsToBounds = false
        #endif
        
        setupCollectionView()
        setupDataBinding()
        setupNavigationBar()
        NotificationCenter.default.addObserver(self, selector: #selector(reloadAllEPGData(_:)), name: .customEPGMappingChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(toggleChannelReorderMode), name: NSNotification.Name("ToggleChannelReorderMode"), object: nil)
        
        // We no longer build all sticky channel names on load
        
        #if os(iOS)
        favouritesCacheReadyObserver = FavouritesManager.shared.$favouritesChanged
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reloadVisibleChannelHeaders()
            }
        #endif
    }
    
    #if os(tvOS)
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        // [Focus logic preserved]
        if let nextCell = context.nextFocusedView as? EPGEventCell,
           let indexPath = collectionView.indexPath(for: nextCell) {
            
            self.lastFocusedIndexPath = indexPath
            
            if let result = self.lookupEvent(forFlatIndex: indexPath.item) {
                self.onEventFocused?(result.channel, result.event)
                
                let now = Date()
                if result.event.start <= now && result.event.end >= now {
                    self.lastFocusedTime = now
                } else {
                    self.lastFocusedTime = result.event.start
                }
            }
        }
        
        if let nextAnchor = context.nextFocusedView as? EPGRowFocusAnchorView,
           let indexPath = collectionView.indexPath(forSupplementaryView: nextAnchor) {
            
            let channelIndex = indexPath.item
            if channelIndex < epgViewModel.pagedChannels.count {
                let channel = epgViewModel.pagedChannels[channelIndex]
                
                let visibleStartTime: Date
                if let lastTime = self.lastFocusedTime {
                    visibleStartTime = lastTime
                } else {
                    let currentOffsetX = collectionView.contentOffset.x
                    let hoursOffset = currentOffsetX / self.eventCardHourWidth
                    visibleStartTime = epgViewModel.earliestDisplayDate.addingTimeInterval(hoursOffset * 3600)
                }
                
                if let events = epgViewModel.epgEventsForDisplay[channel.id] {
                    if let event = events.first(where: { $0.end > visibleStartTime }) {
                        self.onEventFocused?(channel, event)
                    } else if let last = events.last {
                         self.onEventFocused?(channel, last)
                    }
                }
            }
        }
        
        if let nextHeader = context.nextFocusedView as? EPGChannelHeaderCell,
           let indexPath = collectionView.indexPath(for: nextHeader) {
            
            let channelIndex = indexPath.item
            if channelIndex < epgViewModel.pagedChannels.count {
                let channel = epgViewModel.pagedChannels[channelIndex]
                
                let now = Date()
                if let events = epgViewModel.epgEventsForDisplay[channel.id] {
                    if let currentEvent = events.first(where: { $0.start <= now && $0.end > now }) {
                        self.onEventFocused?(channel, currentEvent)
                    } else if let upcomingEvent = events.first(where: { $0.start > now }) {
                        self.onEventFocused?(channel, upcomingEvent)
                    } else if let lastEvent = events.last {
                         self.onEventFocused?(channel, lastEvent)
                    }
                }
            }
        }
    }
    
    override func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        if let last = lastFocusedIndexPath, last.section == 2 {
             return last
        }
        return nil
    }
    #endif

    private func setupNavigationBar() {
        let nowButton = UIBarButtonItem(title: "Now", style: .plain, target: self, action: #selector(scrollToNow))
        let epgMappingButton = UIBarButtonItem(title: epgMappingMode ? "Done Mapping" : "EPG Mapping", style: .plain, target: self, action: #selector(toggleEPGMappingMode))
        navigationItem.rightBarButtonItems = [epgMappingButton, nowButton]
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isVisible = true
        setupNavigationBar()
        
        if let playingChannel = playerManager?.currentChannel {
            if self.currentPlayingChannelID != playingChannel.id {
                self.currentPlayingChannelID = playingChannel.id
            }
        }
        
        scheduleReloadData(debounce: 0.05)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isVisible = false
        if !isVisible {
            collectionView.visibleCells.forEach { cell in
                cell.layer.removeAllAnimations()
            }
        }
    }
    
    @objc private func scrollToNow() {
        scrollToCurrentTime(animated: true)
    }

    @objc private func toggleEPGMappingMode() {
        epgMappingMode.toggle()
        setupNavigationBar()
        scheduleLayoutInvalidation()
        scheduleReloadData(debounce: 0.05)

        if UIDevice.current.userInterfaceIdiom == .phone {
            updateDynamicStickyOverlays()
        }
    }

    @objc func reloadAllEPGData(_ notification: Notification) {
        epgViewModel.reloadWithCustomMappings()
        scheduleReloadData(debounce: 0.05)

        if UIDevice.current.userInterfaceIdiom == .phone {
            updateDynamicStickyOverlays()
        }
    }
    
    // MARK: - Reordering Logic
    private func updateVisibleChannelCellsForReorder() {
        for indexPath in collectionView.indexPathsForVisibleItems where indexPath.section == 1 {
            guard let cell = collectionView.cellForItem(at: indexPath) else { continue }
            if let vm = epgViewModel, vm.isReorderingMode {
                if indexPath.item == reorderPickedChannelIndex {
                    cell.contentView.layer.borderColor = UIColor.systemOrange.cgColor
                    cell.contentView.layer.borderWidth = 3
                    cell.contentView.transform = CGAffineTransform(scaleX: 1.05, y: 1.05)
                } else {
                    cell.contentView.layer.borderColor = UIColor.clear.cgColor
                    cell.contentView.layer.borderWidth = 0
                    cell.contentView.transform = .identity
                }
            } else {
                cell.contentView.layer.borderColor = UIColor.clear.cgColor
                cell.contentView.layer.borderWidth = 0
                cell.contentView.transform = .identity
            }
        }
    }
    
    @objc private func toggleChannelReorderMode() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let vm = self.epgViewModel else { return }
            if !vm.isReorderingMode {
                self.reorderPickedChannelIndex = nil
            }
            self.updateVisibleChannelCellsForReorder()
        }
    }


    // MARK: - Layout Updates
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        updateVisibleFloatingContent()
        
        guard let layout = collectionViewLayout as? EPGCollectionViewLayout else { return }

        var needsInvalidate = false

        if layout.channelColumnWidth != channelColumnWidth {
            layout.channelColumnWidth = channelColumnWidth
            needsInvalidate = true
        }
        if layout.timeHeaderHeight != timeHeaderHeight {
            layout.timeHeaderHeight = timeHeaderHeight
            needsInvalidate = true
        }
        if layout.eventCardHourWidth != epgViewModel.eventCardHourWidth {
            layout.eventCardHourWidth = epgViewModel.eventCardHourWidth
            needsInvalidate = true
        }
        if layout.channelRowHeight != epgViewModel.channelRowHeight {
            layout.channelRowHeight = epgViewModel.channelRowHeight
            needsInvalidate = true
        }
        
        if layout.isSkeletonMode != self.isShowingSkeletons {
            layout.isSkeletonMode = self.isShowingSkeletons
            needsInvalidate = true
        }

        if layout.iphoneChannelNameOverlayHeight != self.iphoneChannelNameOverlayHeight {
            layout.iphoneChannelNameOverlayHeight = self.iphoneChannelNameOverlayHeight
            needsInvalidate = true
        }

        let vmChannels = epgViewModel?.pagedChannels ?? []
        let vmEvents = epgViewModel?.epgEventsForDisplay ?? [:]
        let vmHours = epgViewModel?.allHoursForEPG ?? []
        let vmEarliest = epgViewModel?.earliestDisplayDate ?? Date()

        let suppressEmpty = (vmChannels.isEmpty && lastKnownChannelCount > 0 && (suppressEmptyTransitionUntil ?? .distantPast) > Date())

        if !suppressEmpty {
            if layout.channels.count != vmChannels.count || layout.channels.first?.id != vmChannels.first?.id {
                layout.channels = vmChannels
                needsInvalidate = true
            }
            layout.epgEventsForDisplay = vmEvents
            layout.allHoursToDisplay = vmHours
            layout.earliestDisplayDate = vmEarliest
        }
        
        if needsInvalidate {
             scheduleLayoutInvalidation()
        }

        let now = Date().timeIntervalSince1970
        let boundsChangedSignificantly = abs(view.bounds.width - lastKnownBounds.width) > 2.0 || abs(view.bounds.height - lastKnownBounds.height) > 2.0
        
        if boundsChangedSignificantly {
            scheduleLayoutInvalidation()
            lastLayoutInvalidateTime = now
            lastKnownBounds = view.bounds
        }

        if UIDevice.current.userInterfaceIdiom == .phone {
            updateDynamicStickyOverlays()
        }
    }

    // MARK: - Data binding
    private func setupDataBinding() {
        NotificationCenter.default.addObserver(self, selector: #selector(updateCurrentPlayingChannel(_:)), name: .currentChannelDidChange, object: nil)

        epgViewModel?.reloadDataTrigger
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                self?.scheduleReloadData(debounce: 0)
            }
            .store(in: &epgViewModel.cancellables)
        
        #if os(iOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFavouritesChangedForVisibleCells),
            name: FavouritesManager.favouritesChangedNotification,
            object: nil
        )
        #endif
    }
    
    @objc private func handleFavouritesChangedForVisibleCells() {
        guard !isUpdatingData else { return }
        reloadVisibleChannelHeaders()
    }
    
    private func reloadVisibleChannelHeaders() {
        guard !isUpdatingData, isVisible else { return }
        guard let vm = epgViewModel else { return }
        
        let visibleIndexPaths = collectionView.indexPathsForVisibleItems.filter { $0.section == 1 }
        guard !visibleIndexPaths.isEmpty else { return }
        
        let channelCount = vm.pagedChannels.count
        let safeIndexPaths = visibleIndexPaths.filter { $0.item < channelCount }
        guard !safeIndexPaths.isEmpty else { return }
        
        for indexPath in safeIndexPaths {
            guard let cell = collectionView.cellForItem(at: indexPath) as? EPGChannelHeaderCell else { continue }
            guard indexPath.item < channelCount else { continue }
            
            let channel = vm.pagedChannels[indexPath.item]
            
            let isPlaying = channel.id == self.currentPlayingChannelID
            let showNameInColumn = UIDevice.current.userInterfaceIdiom != .phone
            cell.configure(
                with: channel,
                isPlaying: isPlaying,
                channelRowHeight: vm.channelRowHeight,
                showCopyEPGButton: epgMappingMode,
                showNameInColumn: showNameInColumn
            )
            if let customDataManager = self.customDataManager ?? CustomDataManager.shared as CustomDataManager? {
                cell.injectEPGDependencies(viewModel: vm, customDataManager: customDataManager, parentVC: self)
            }
            
            if vm.isReorderingMode && indexPath.item == reorderPickedChannelIndex {
                cell.contentView.layer.borderColor = UIColor.systemOrange.cgColor
                cell.contentView.layer.borderWidth = 3
                cell.contentView.transform = CGAffineTransform(scaleX: 1.05, y: 1.05)
            } else {
                cell.contentView.layer.borderColor = UIColor.clear.cgColor
                cell.contentView.layer.borderWidth = 0
                cell.contentView.transform = .identity
            }
        }
    }

    private func scheduleLayoutInvalidation(delay: TimeInterval = 0.04) {
        if !isVisible { return }
        if let pm = playerManager, pm.showFullScreenPlayer { return }
        
        layoutInvalidationWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.collectionView.collectionViewLayout.invalidateLayout()
        }
        layoutInvalidationWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func scheduleReloadData(debounce: TimeInterval = 0.1) {
        if let pm = playerManager, pm.showFullScreenPlayer { return }

        reloadWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.safeReloadData()
        }
        reloadWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: item)
    }
    
    // MARK: - Core reload logic
    private func safeReloadData() {
        guard !isUpdatingData else {
            pendingReloadAfterUpdate = true
            return
        }
        
        let nowTime = CFAbsoluteTimeGetCurrent()
        if nowTime - lastReloadTime < minReloadInterval {
            pendingReloadAfterUpdate = true
            DispatchQueue.main.asyncAfter(deadline: .now() + minReloadInterval) { [weak self] in
                guard let self = self else { return }
                if self.pendingReloadAfterUpdate {
                    self.pendingReloadAfterUpdate = false
                    self.safeReloadData()
                }
            }
            return
        }

        isUpdatingData = true
        defer {
            isUpdatingData = false
            lastReloadTime = CFAbsoluteTimeGetCurrent()
        }

        guard let layout = collectionViewLayout as? EPGCollectionViewLayout else { return }
        guard let vm = epgViewModel else { return }

        self.isShowingSkeletons = vm.pagedChannels.isEmpty && vm.isLoadingData

        let newChannels = vm.pagedChannels
        let newEvents = vm.epgEventsForDisplay
        let newHours = vm.allHoursForEPG
        let newEarliest = vm.earliestDisplayDate
        
        rebuildEventLookupCache(channels: newChannels, events: newEvents)

        let newChannelCount = newChannels.count
        let newEventCount = flatTotalEventCount
        let newHoursCount = newHours.count
        
        partialReloadWorkItem?.cancel()
        pendingPartialReloadChannelIDs.removeAll()
        
        UIView.performWithoutAnimation {
            layout.channels = newChannels
            layout.epgEventsForDisplay = newEvents
            layout.allHoursToDisplay = newHours
            layout.earliestDisplayDate = newEarliest

            collectionView.reloadData()
            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
        }

        lastKnownHoursCount = newHoursCount
        lastKnownChannelCount = newChannelCount
        lastKnownEventCount = newEventCount

        if UIDevice.current.userInterfaceIdiom == .phone {
            updateDynamicStickyOverlays()
        }
        
        #if os(iOS)
        if FavouritesManager.shared.isCacheReady {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, !self.isUpdatingData else { return }
                self.reloadVisibleChannelHeaders()
            }
        }
        #endif
    }
    
    private func rebuildEventLookupCache(channels: [Channel], events: [Int: [EPGEvent]]) {
        var counts: [Int] = []
        var runningTotal = 0
        
        for channel in channels {
            let count = events[channel.id]?.count ?? 0
            runningTotal += count
            counts.append(runningTotal)
        }
        
        self.channelEventCumulativeCounts = counts
        self.flatTotalEventCount = runningTotal
    }
    
    private func lookupEvent(forFlatIndex index: Int) -> (channel: Channel, event: EPGEvent)? {
        guard !channelEventCumulativeCounts.isEmpty else { return nil }
        
        var low = 0
        var high = channelEventCumulativeCounts.count - 1
        var channelIndex = -1
        
        while low <= high {
            let mid = (low + high) / 2
            if channelEventCumulativeCounts[mid] > index {
                channelIndex = mid
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        
        guard channelIndex != -1, channelIndex < epgViewModel.pagedChannels.count else { return nil }
        
        let startOfThisChannel = channelIndex > 0 ? channelEventCumulativeCounts[channelIndex - 1] : 0
        let localEventIndex = index - startOfThisChannel
        
        let channel = epgViewModel.pagedChannels[channelIndex]
        guard let events = epgViewModel.epgEventsForDisplay[channel.id] else { return nil }
        
        if localEventIndex < events.count {
            return (channel, events[localEventIndex])
        }
        
        return nil
    }

    // MARK: - CollectionView setup
    private func setupCollectionView() {
        collectionView.register(EPGTopLeftHeaderCell.self, forCellWithReuseIdentifier: "TopLeftHeader")
        collectionView.register(EPGTimeHeaderCell.self, forCellWithReuseIdentifier: "TimeHeader")
        collectionView.register(EPGChannelHeaderCell.self, forCellWithReuseIdentifier: "ChannelHeader")
        collectionView.register(EPGEventCell.self, forCellWithReuseIdentifier: "EventCell")
        
        collectionView.register(EPGFullSkeletonCell.self, forCellWithReuseIdentifier: "FullSkeletonCell")
        
        collectionView.register(
            EPGCurrentTimeIndicatorSupplementaryView.self,
            forSupplementaryViewOfKind: EPGCollectionViewLayout.currentTimeIndicatorKind,
            withReuseIdentifier: "CurrentTimeIndicator"
        )
        collectionView.register(
            EPGHourDividerSupplementaryView.self,
            forSupplementaryViewOfKind: EPGCollectionViewLayout.hourDividerKind,
            withReuseIdentifier: "HourDivider"
        )
        collectionView.register(
            EPGRowFocusAnchorView.self,
            forSupplementaryViewOfKind: EPGCollectionViewLayout.rowFocusAnchorKind,
            withReuseIdentifier: "RowFocusAnchor"
        )
        
        if UIDevice.current.userInterfaceIdiom != .phone {
            collectionView.register(
                EPGChannelNameOverlaySupplementaryView.self,
                forSupplementaryViewOfKind: EPGCollectionViewLayout.channelNameOverlayKind,
                withReuseIdentifier: "ChannelNameOverlay"
            )
        }
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = true
        collectionView.showsVerticalScrollIndicator = true
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.bounces = false
        collectionView.alwaysBounceVertical = false
        collectionView.alwaysBounceHorizontal = false

        if let layout = collectionViewLayout as? EPGCollectionViewLayout {
            layout.channelColumnWidth = channelColumnWidth
            layout.timeHeaderHeight = timeHeaderHeight
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.scrollToCurrentTime(animated: false)
        }
    }

    // MARK: - Current playing channel update
    @objc private func updateCurrentPlayingChannel(_ notification: Notification) {
        if let channel = notification.object as? Channel {
            updatePlayingChannel(channel.id)
        }
    }

    func updatePlayingChannel(_ newChannelID: Int?) {
        guard let newID = newChannelID else { return }
        guard !isUpdatingData else { return }

        let currentHoursCount = epgViewModel.allHoursForEPG.count
        if currentHoursCount != lastKnownHoursCount || epgViewModel.pagedChannels.count != lastKnownChannelCount {
            currentPlayingChannelID = newID
            safeReloadData()
            return
        }

        let oldID = currentPlayingChannelID
        
        currentPlayingChannelID = newID
        
        var channelIDsToRefresh: Set<Int> = []
        if let oldID = oldID {
            channelIDsToRefresh.insert(oldID)
        }
        channelIDsToRefresh.insert(newID)
        
        for id in channelIDsToRefresh {
            pendingPartialReloadChannelIDs.insert(id)
        }
        
        partialReloadWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.executePartialChannelHeaderReload()
        }
        partialReloadWorkItem = item
        DispatchQueue.main.async(execute: item)
    }
    
    private func executePartialChannelHeaderReload() {
        guard !isUpdatingData else {
            pendingPartialReloadChannelIDs.removeAll()
            return
        }
        
        let idsToReload = pendingPartialReloadChannelIDs
        pendingPartialReloadChannelIDs.removeAll()
        
        guard !idsToReload.isEmpty else { return }
        
        var indexPathsToReload: [IndexPath] = []
        for channelID in idsToReload {
            if let index = epgViewModel.pagedChannels.firstIndex(where: { $0.id == channelID }) {
                indexPathsToReload.append(IndexPath(item: index, section: 1))
            }
        }
        
        let uniquePaths = Array(Set(indexPathsToReload))
        guard !uniquePaths.isEmpty else { return }
        
        let channelCount = collectionView.numberOfItems(inSection: 1)
        let safePaths = uniquePaths.filter { $0.item < channelCount }
        guard !safePaths.isEmpty else { return }
        
        UIView.performWithoutAnimation {
            self.collectionView.reloadItems(at: safePaths)
        }
    }

    // MARK: - Scrolling helpers
    func scrollToCurrentTime(animated: Bool = true) {
        guard let epgViewModel = epgViewModel else { return }
        let now = Date()
        let offsetHours: Double = now.timeIntervalSince(epgViewModel.earliestDisplayDate) / 3600.0
        let maxOffsetX: CGFloat = max(0, collectionView.contentSize.width - collectionView.bounds.width)
        let contentOffsetX: CGFloat = max(0, min((CGFloat(offsetHours) * epgViewModel.eventCardHourWidth) - collectionView.bounds.width / 3, maxOffsetX))
        collectionView.setContentOffset(CGPoint(x: contentOffsetX, y: collectionView.contentOffset.y), animated: animated)
    }

    func scrollToChannel(_ channel: Channel, animated: Bool = true) {
        guard let epgViewModel = epgViewModel else { return }
        if let index = epgViewModel.pagedChannels.firstIndex(where: { $0.id == channel.id }) {
            let y = timeHeaderHeight + (CGFloat(index) * epgViewModel.channelRowHeight)
            collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: y), animated: animated)
        }
    }

    // MARK: - UICollectionView data source and delegates
    override func numberOfSections(in collectionView: UICollectionView) -> Int { 3 }

    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        guard let epgViewModel = epgViewModel else { return 0 }

        switch section {
        case 0:
            return isShowingSkeletons ? 5 + 1 : (epgViewModel.allHoursForEPG.count + 1)
        case 1:
            return isShowingSkeletons ? 0 : epgViewModel.pagedChannels.count
        case 2:
            if isShowingSkeletons {
                return skeletonRowsDefault
            }
            return flatTotalEventCount
        default:
            return 0
        }
    }

    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let epgViewModel = epgViewModel else {
            return collectionView.dequeueReusableCell(withReuseIdentifier: "EventCell", for: indexPath)
        }
        
        switch indexPath.section {
        case 0:
            if indexPath.item == 0 {
                return collectionView.dequeueReusableCell(withReuseIdentifier: "TopLeftHeader", for: indexPath) as! EPGTopLeftHeaderCell
            } else {
                let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "TimeHeader", for: indexPath) as! EPGTimeHeaderCell
                if !isShowingSkeletons && indexPath.item - 1 < epgViewModel.allHoursForEPG.count {
                    let hourOffset = Double(indexPath.item - 1) * 3600
                    let date = epgViewModel.earliestDisplayDate.addingTimeInterval(hourOffset)
                    cell.configure(with: date)
                } else {
                    let date = Date().addingTimeInterval(Double(indexPath.item - 1) * 3600)
                    cell.configure(with: date)
                }
                return cell
            }
        case 1:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "ChannelHeader", for: indexPath) as! EPGChannelHeaderCell
            
            guard indexPath.item < epgViewModel.pagedChannels.count else {
                cell.resetToDefaultState()
                return cell
            }
            
            let channel = epgViewModel.pagedChannels[indexPath.item]
            let showNameInColumn = UIDevice.current.userInterfaceIdiom != .phone
            
            let isPlaying = channel.id == self.currentPlayingChannelID
            cell.configure(with: channel, isPlaying: isPlaying, channelRowHeight: epgViewModel.channelRowHeight, showCopyEPGButton: epgMappingMode, showNameInColumn: showNameInColumn)

            if let customDataManager = self.customDataManager ?? CustomDataManager.shared as CustomDataManager? {
                cell.injectEPGDependencies(viewModel: epgViewModel, customDataManager: customDataManager, parentVC: self)
            }
            
            if epgViewModel.isReorderingMode && indexPath.item == reorderPickedChannelIndex {
                cell.contentView.layer.borderColor = UIColor.systemOrange.cgColor
                cell.contentView.layer.borderWidth = 3
                cell.contentView.transform = CGAffineTransform(scaleX: 1.05, y: 1.05)
            } else {
                cell.contentView.layer.borderColor = UIColor.clear.cgColor
                cell.contentView.layer.borderWidth = 0
                cell.contentView.transform = .identity
            }
            
            return cell
        case 2:
            if isShowingSkeletons {
                let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "FullSkeletonCell", for: indexPath) as! EPGFullSkeletonCell
                cell.configure(
                    channelColumnWidth: self.channelColumnWidth,
                    rowHeight: self.epgViewModel.channelRowHeight
                )
                return cell
            }
            
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "EventCell", for: indexPath) as! EPGEventCell
            
            if let result = lookupEvent(forFlatIndex: indexPath.item) {
                let isEventPlaying = Int(result.event.channelID) == self.currentPlayingChannelID
                let isSelected = indexPath == expandedEventIndexPath
                
                cell.configure(with: result.event, isPlaying: isEventPlaying, isSelectedCell: isSelected, channelRowHeight: epgViewModel.channelRowHeight, isExpanded: isSelected)
                
                let visibleRect = CGRect(origin: collectionView.contentOffset, size: collectionView.bounds.size)
                cell.updateFloatingContent(in: visibleRect)
            } else {
                cell.resetToDefaultState()
            }
            return cell
        default:
            return collectionView.dequeueReusableCell(withReuseIdentifier: "EventCell", for: indexPath)
        }
    }

    override func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        if kind == EPGCollectionViewLayout.currentTimeIndicatorKind {
            let view = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "CurrentTimeIndicator", for: indexPath) as! EPGCurrentTimeIndicatorSupplementaryView
            view.updateTime()
            return view
        } else if kind == EPGCollectionViewLayout.hourDividerKind {
            return collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "HourDivider", for: indexPath) as! EPGHourDividerSupplementaryView
        } else if kind == EPGCollectionViewLayout.rowFocusAnchorKind {
             return collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "RowFocusAnchor", for: indexPath)
        } else if kind == EPGCollectionViewLayout.channelNameOverlayKind {
            let view = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "ChannelNameOverlay", for: indexPath) as! EPGChannelNameOverlaySupplementaryView
            if let vm = epgViewModel, indexPath.item < vm.pagedChannels.count {
                let channel = vm.pagedChannels[indexPath.item]
                let displayName = CustomDataManager.shared.customName(for: ChannelReference(serverID: channel.serverID, channelID: String(channel.id))) ?? channel.name
                view.configure(with: displayName)
            } else {
                view.configure(with: "")
            }
            return view
        }
        fatalError("Unexpected supplementary view kind: \(kind)")
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard !isUpdatingData else { return }
            
            if isShowingSkeletons { return }

            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.isVisible, let epgViewModel = self.epgViewModel else { return }
                
                switch indexPath.section {
                case 1:
                    if epgViewModel.isReorderingMode {
                        if let picked = self.reorderPickedChannelIndex {
                            if picked == indexPath.item {
                                self.reorderPickedChannelIndex = nil
                                self.updateVisibleChannelCellsForReorder()
                            } else {
                                let sourceItem = picked
                                var destItem = indexPath.item
                                
                                if sourceItem < destItem {
                                    destItem -= 1
                                }
                                
                                epgViewModel.moveChannel(from: sourceItem, to: destItem)
                                
                                if let layout = self.collectionView.collectionViewLayout as? EPGCollectionViewLayout {
                                    layout.channels = epgViewModel.pagedChannels
                                }
                                
                                UIView.performWithoutAnimation {
                                    self.collectionView.moveItem(at: IndexPath(item: sourceItem, section: 1), to: IndexPath(item: destItem, section: 1))
                                    self.collectionView.collectionViewLayout.invalidateLayout()
                                }
                                
                                self.reorderPickedChannelIndex = nil
                                self.updateVisibleChannelCellsForReorder()
                                
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    epgViewModel.saveCurrentChannelOrder()
                                }
                            }
                        } else {
                            self.reorderPickedChannelIndex = indexPath.item
                            self.updateVisibleChannelCellsForReorder()
                        }
                        return
                    }

                    if epgViewModel.pagedChannels.isEmpty { return }
                    if indexPath.item < epgViewModel.pagedChannels.count {
                        let tappedChannel = epgViewModel.pagedChannels[indexPath.item]
                        self.changeChannel(to: tappedChannel)
                    }
                case 2:
                    if let result = self.lookupEvent(forFlatIndex: indexPath.item) {
                        #if os(tvOS)
                        self.changeChannel(to: result.channel)
                        #else
                        let oldExpanded = self.expandedEventIndexPath
                        self.expandedEventIndexPath = (self.expandedEventIndexPath == indexPath) ? nil : indexPath
                        var toReload: [IndexPath] = [indexPath]
                        if let old = oldExpanded { toReload.append(old) }
                        
                        UIView.performWithoutAnimation {
                            collectionView.reloadItems(at: toReload)
                            collectionView.collectionViewLayout.invalidateLayout()
                        }
                        self.onEventTapped?(result.event, result.channel)
                        #endif
                    }
                default:
                    break
                }
            }
        }
        
    private func changeChannel(to channel: Channel) {
        #if os(tvOS)
        if channel.id == self.currentPlayingChannelID {
            self.playerManager?.showFullScreenPlayer = true
            return
        }
        #endif
        
        self.updatePlayingChannel(channel.id)
        self.onChannelTapped?(channel)
    }

    // MARK: - Reset & Dynamic Overlays
    func reset() {
        isUpdatingData = true
        lastKnownChannelCount = 0
        lastKnownEventCount = 0
        lastKnownHoursCount = 0
        expandedEventIndexPath = nil
        channelEventCumulativeCounts = []
        flatTotalEventCount = 0
        
        partialReloadWorkItem?.cancel()
        pendingPartialReloadChannelIDs.removeAll()
        
        UIView.performWithoutAnimation {
            collectionView.reloadData()
        }
        scheduleLayoutInvalidation()
        if UIDevice.current.userInterfaceIdiom == .phone {
            updateDynamicStickyOverlays()
        }
        isUpdatingData = false
    }

    /// OPTIMIZATION: Dynamically adds and repositions only the sticky overlays needed for the currently visible rows.
    private func updateDynamicStickyOverlays() {
        guard UIDevice.current.userInterfaceIdiom == .phone, let vm = epgViewModel else { return }
        let channels = vm.pagedChannels
        guard !channels.isEmpty else {
            removeStickyChannelNameOverlays()
            return
        }
        
        let cv = collectionView!
        let visibleRect = CGRect(origin: cv.contentOffset, size: cv.bounds.size)
        let rowHeight = vm.channelRowHeight
        
        // Calculate which rows are currently visible
        let minRowIndex = max(0, Int(floor((visibleRect.minY - timeHeaderHeight) / rowHeight)))
        let maxRowIndex = min(channels.count - 1, Int(ceil((visibleRect.maxY - timeHeaderHeight) / rowHeight)))
        
        let visibleCount = max(0, maxRowIndex - minRowIndex + 1)
        
        // Ensure pool size matches the maximum possible visible rows (usually ~10-15 instead of 3000)
        while stickyChannelNameOverlays.count < visibleCount {
            let overlay = EPGChannelNameOverlayView()
            overlay.isUserInteractionEnabled = false
            cv.addSubview(overlay)
            stickyChannelNameOverlays.append(overlay)
        }
        
        let nameGapHeight: CGFloat = self.iphoneChannelNameOverlayHeight
        let startY = timeHeaderHeight
        let offsetX = cv.contentOffset.x
        let offsetY = cv.contentOffset.y
        
        // Assign the pooled overlays to visible channels and hide any extras
        for i in 0..<stickyChannelNameOverlays.count {
            let overlay = stickyChannelNameOverlays[i]
            let channelIndex = minRowIndex + i
            
            if channelIndex <= maxRowIndex {
                let channel = channels[channelIndex]
                let displayName = CustomDataManager.shared.customName(for: ChannelReference(serverID: channel.serverID, channelID: String(channel.id))) ?? channel.name
                
                overlay.configure(with: displayName)
                
                let yInCollection = startY + (CGFloat(channelIndex) * rowHeight)
                let visibleY = yInCollection - offsetY
                
                overlay.frame = CGRect(
                    x: channelColumnWidth + offsetX,
                    y: yInCollection,
                    width: cv.bounds.width - channelColumnWidth,
                    height: nameGapHeight
                )
                
                overlay.isHidden = (visibleY < timeHeaderHeight || visibleY > cv.bounds.height)
            } else {
                overlay.isHidden = true
            }
        }
    }

    private func removeStickyChannelNameOverlays() {
        for overlay in stickyChannelNameOverlays { overlay.removeFromSuperview() }
        stickyChannelNameOverlays.removeAll()
    }

    // MARK: - Floating Content Updates
    private func updateVisibleFloatingContent() {
        let visibleRect = CGRect(origin: collectionView.contentOffset, size: collectionView.bounds.size)
        
        for cell in collectionView.visibleCells {
            if let eventCell = cell as? EPGEventCell {
                eventCell.updateFloatingContent(in: visibleRect)
            }
        }
    }

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateVisibleFloatingContent()
        
        if UIDevice.current.userInterfaceIdiom == .phone { updateDynamicStickyOverlays() }
        #if os(tvOS)
        scheduleLayoutInvalidation(delay: 0.04)
        #else
        scheduleLayoutInvalidation(delay: 0.02)
        #endif
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        favouritesCacheReadyObserver?.cancel()
        removeStickyChannelNameOverlays()
    }
    
    // MARK: - Prefetching Protocol
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        // Placeholder for future prefetching
    }
}


// MARK: - Skeleton Cell Definition
final class EPGFullSkeletonCell: UICollectionViewCell {
    private let channelSection = UIView()
    private let timelineSection = UIView()
    private var shimmerLayer: CAGradientLayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError("Not implemented") }
    
    private func setupViews() {
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        
        channelSection.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(channelSection)
        
        timelineSection.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(timelineSection)
    }
    
    func configure(channelColumnWidth: CGFloat, rowHeight: CGFloat) {
        channelSection.subviews.forEach { $0.removeFromSuperview() }
        timelineSection.subviews.forEach { $0.removeFromSuperview() }
        
        channelSection.frame = CGRect(x: 0, y: 0, width: channelColumnWidth, height: rowHeight)
        
        let iconHeight = rowHeight * 0.55
        let iconWidth = iconHeight * 1.5
        let iconView = createPlaceholderView(cornerRadius: 6)
        iconView.frame = CGRect(
            x: (channelColumnWidth - iconWidth) / 2,
            y: (rowHeight - iconHeight) / 2,
            width: iconWidth,
            height: iconHeight
        )
        channelSection.addSubview(iconView)
        
        timelineSection.frame = CGRect(x: channelColumnWidth, y: 0, width: bounds.width - channelColumnWidth, height: rowHeight)
        
        let eventHeight = rowHeight * 0.7
        let eventY = (rowHeight - eventHeight) / 2
        let eventCount = Int.random(in: 2...3)
        var currentX: CGFloat = 10
        
        for _ in 0..<eventCount {
            let eventWidth = CGFloat.random(in: 120...250)
            let eventView = createPlaceholderView(cornerRadius: 8)
            eventView.frame = CGRect(x: currentX, y: eventY, width: eventWidth, height: eventHeight)
            timelineSection.addSubview(eventView)
            
            let gap = CGFloat.random(in: 8...20)
            currentX += eventWidth + gap
        }
        startShimmer()
    }
    
    private func createPlaceholderView(cornerRadius: CGFloat) -> UIView {
        let view = UIView()
        view.backgroundColor = UIColor(white: 0.2, alpha: 0.4)
        view.layer.cornerRadius = cornerRadius
        view.clipsToBounds = true
        return view
    }

    private func startShimmer() {
        shimmerLayer?.removeFromSuperlayer()
        let gradient = CAGradientLayer()
        gradient.frame = contentView.bounds.insetBy(dx: -contentView.bounds.width, dy: 0)
        let baseColor = UIColor.clear
        let shimmerColor = UIColor(white: 0.3, alpha: 0.3)
        gradient.colors = [baseColor.cgColor, shimmerColor.cgColor, baseColor.cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.locations = [0.4, 0.5, 0.6]
        contentView.layer.addSublayer(gradient)
        shimmerLayer = gradient

        let anim = CABasicAnimation(keyPath: "locations")
        anim.fromValue = [0.0, 0.1, 0.2]
        anim.toValue = [0.8, 0.9, 1.0]
        anim.duration = 1.5
        anim.repeatCount = .infinity
        gradient.add(anim, forKey: "shimmer")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        shimmerLayer?.frame = bounds.insetBy(dx: -bounds.width, dy: 0)
    }
}
