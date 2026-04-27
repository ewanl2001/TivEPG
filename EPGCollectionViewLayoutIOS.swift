//
//  EPGCollectionViewLayout.swift
//

import UIKit

class EPGCollectionViewLayout: UICollectionViewLayout {
    // Public configuration
    #if os(tvOS)
    var channelColumnWidth: CGFloat = 500
    var timeHeaderHeight: CGFloat = 72
    var eventCardHourWidth: CGFloat = 1150
    var channelRowHeight: CGFloat = 180
    #else
    var channelColumnWidth: CGFloat = 80
    var timeHeaderHeight: CGFloat = 44
    var eventCardHourWidth: CGFloat = 190
    var channelRowHeight: CGFloat = 60
    #endif
    
    var channels: [Channel] = [] {
        didSet {
            dataHasChanged = true
        }
    }
    
    var epgEventsForDisplay: [Channel.ID: [EPGEvent]] = [:] {
        didSet {
            dataHasChanged = true
        }
    }
    
    var allHoursToDisplay: [Int] = [] {
        didSet {
            dataHasChanged = true
        }
    }
    
    var earliestDisplayDate: Date = Date()
    var expandedEventIndexPath: IndexPath? = nil

    var isSkeletonMode: Bool = false {
        didSet {
            if isSkeletonMode != oldValue { dataHasChanged = true }
        }
    }
    var iphoneChannelNameOverlayHeight: CGFloat = 0

    // Content measurements
    private var contentWidth: CGFloat = 0
    private var contentHeight: CGFloat = 0
    
    // Performance Cache
    private var channelEventStartIndices: [Int] = []
    private var dataHasChanged: Bool = true // Track when to rebuild indices

    // Kinds
    static let currentTimeIndicatorKind = "CurrentTimeIndicator"
    static let hourDividerKind = "HourDivider"
    static let channelNameOverlayKind = "ChannelNameOverlay"
    // MARK: - New Focus Anchor Kind
    static let rowFocusAnchorKind = "RowFocusAnchor"

    override var collectionViewContentSize: CGSize {
        return CGSize(width: contentWidth, height: contentHeight)
    }

    override class var layoutAttributesClass: AnyClass {
        return EPGLayoutAttributes.self
    }
    
    // MARK: - Preparation
    override func prepare() {
        super.prepare()
        guard let collectionView = collectionView else { return }

        let numberOfChannels = isSkeletonMode ? collectionView.numberOfItems(inSection: 2) : channels.count
        let numberOfTimeSlots = isSkeletonMode ? 5 : allHoursToDisplay.count
        
        contentWidth = channelColumnWidth + (CGFloat(numberOfTimeSlots) * eventCardHourWidth)
        contentHeight = timeHeaderHeight + (CGFloat(numberOfChannels) * channelRowHeight)
        
        // ONLY rebuild Index Cache if the data actually changed, NOT on every scroll frame
        if dataHasChanged {
            channelEventStartIndices.removeAll(keepingCapacity: true)
            if !isSkeletonMode {
                var runningTotal = 0
                for channel in channels {
                    channelEventStartIndices.append(runningTotal)
                    let count = epgEventsForDisplay[channel.id]?.count ?? 0
                    runningTotal += count
                }
            }
            dataHasChanged = false
        }
    }
    
    // MARK: - TVOS FOCUS FIX: STRICT X-LOCK (Velocity)
    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint, withScrollingVelocity velocity: CGPoint) -> CGPoint {
        guard let collectionView = collectionView else { return proposedContentOffset }
        
        #if os(tvOS)
        // STRICT X-LOCK: If vertical velocity is non-zero (moving up/down), or horizontal is zero, FORCE keep X.
        // This prevents diagonal drift when navigating channels.
        if velocity.x == 0 {
             return CGPoint(x: collectionView.contentOffset.x, y: proposedContentOffset.y)
        }
        #endif
        
        return proposedContentOffset
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        return true
    }

    // MARK: - Attribute Generation
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let cv = collectionView else { return nil }
        var visibleAttributes: [UICollectionViewLayoutAttributes] = []

        // 1. Calculate visible row range (Channels)
        let minRowIndex = max(0, Int(floor((rect.minY - timeHeaderHeight) / channelRowHeight)))
        let maxRowIndex: Int

        if isSkeletonMode {
            let skeletonCount = cv.numberOfItems(inSection: 2)
            // Guard: if there are no skeleton rows, skip all row-dependent work
            guard skeletonCount > 0 else {
                if let topLeft = layoutAttributesForItem(at: IndexPath(item: 0, section: 0)) {
                    visibleAttributes.append(topLeft)
                }
                return visibleAttributes
            }
            maxRowIndex = min(skeletonCount - 1, Int(ceil((rect.maxY - timeHeaderHeight) / channelRowHeight)))
        } else {
            // Guard: if there are no channels, only render the header row and return
            guard !channels.isEmpty else {
                if let topLeft = layoutAttributesForItem(at: IndexPath(item: 0, section: 0)) {
                    visibleAttributes.append(topLeft)
                }
                return visibleAttributes
            }
            maxRowIndex = min(channels.count - 1, Int(ceil((rect.maxY - timeHeaderHeight) / channelRowHeight)))
        }

        // 2. Calculate visible column range (Time Slots)
        let minColIndex = max(0, Int(floor((rect.minX - channelColumnWidth) / eventCardHourWidth)))
        let maxColIndex: Int
        if allHoursToDisplay.isEmpty {
            maxColIndex = 0
        } else {
            maxColIndex = min(allHoursToDisplay.count - 1, Int(ceil((rect.maxX - channelColumnWidth) / eventCardHourWidth)))
        }

        // --- SECTION 0: TOP HEADERS & TIME ---

        // A. Top-Left Corner (Sticky)
        if let topLeft = layoutAttributesForItem(at: IndexPath(item: 0, section: 0)) {
            visibleAttributes.append(topLeft)
        }

        // B. Time Headers (Sticky Top)
        if minColIndex <= maxColIndex {
            for col in minColIndex...maxColIndex {
                if col < allHoursToDisplay.count {
                    if let attr = layoutAttributesForItem(at: IndexPath(item: col + 1, section: 0)) {
                        visibleAttributes.append(attr)
                    }
                }
            }
        }

        // C. Hour Dividers
        if minColIndex <= maxColIndex {
            for col in minColIndex...maxColIndex {
                if let attr = layoutAttributesForSupplementaryView(
                    ofKind: EPGCollectionViewLayout.hourDividerKind,
                    at: IndexPath(item: col, section: 0)
                ) {
                    if attr.frame.intersects(rect) {
                        visibleAttributes.append(attr)
                    }
                }
            }
        }

        // D. Current Time Indicator
        if !isSkeletonMode,
           let attr = layoutAttributesForSupplementaryView(
                ofKind: EPGCollectionViewLayout.currentTimeIndicatorKind,
                at: IndexPath(item: 0, section: 0)
           ),
           attr.frame.intersects(rect) {
            visibleAttributes.append(attr)
        }

        // --- SECTIONS 1 & 2: CHANNELS & EVENTS ---

        guard minRowIndex <= maxRowIndex else { return visibleAttributes }

        for rowIndex in minRowIndex...maxRowIndex {
            // A. Channel Header (Sticky Left)
            if let chanHeader = layoutAttributesForItem(at: IndexPath(item: rowIndex, section: 1)) {
                visibleAttributes.append(chanHeader)
            }

            #if os(tvOS)
            // Row Focus Anchor
            let anchorIndexPath = IndexPath(item: rowIndex, section: 99)
            if let anchorAttr = layoutAttributesForSupplementaryView(
                ofKind: EPGCollectionViewLayout.rowFocusAnchorKind,
                at: anchorIndexPath
            ) {
                visibleAttributes.append(anchorAttr)
            }
            #endif

            // B. Events
            if isSkeletonMode {
                let skeletonIndexPath = IndexPath(item: rowIndex, section: 2)
                let attr = EPGLayoutAttributes(forCellWith: skeletonIndexPath)
                attr.frame = CGRect(
                    x: 0,
                    y: timeHeaderHeight + (CGFloat(rowIndex) * channelRowHeight),
                    width: contentWidth,
                    height: channelRowHeight
                )
                attr.zIndex = 50
                visibleAttributes.append(attr)
            } else {
                let channel = channels[rowIndex]

                if let channelEvents = epgEventsForDisplay[channel.id] {
                    let globalStartIndex = channelEventStartIndices.indices.contains(rowIndex)
                        ? channelEventStartIndices[rowIndex] : 0

                    for (evtIndex, event) in channelEvents.enumerated() {
                        let indexPath = IndexPath(item: globalStartIndex + evtIndex, section: 2)
                        let attr = calculateEventAttribute(for: event, at: indexPath, channelIndex: rowIndex)

                        if attr.frame.intersects(rect) {
                            visibleAttributes.append(attr)
                        }

                        if attr.frame.minX > rect.maxX {
                            break
                        }
                    }
                }
            }
        }

        return visibleAttributes
    } 

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let cv = collectionView else { return nil }
        
        // 1. Top Left Header
        if indexPath.section == 0 && indexPath.item == 0 {
            let attr = EPGLayoutAttributes(forCellWith: indexPath)
            attr.frame = CGRect(
                x: cv.contentOffset.x,
                y: cv.contentOffset.y,
                width: channelColumnWidth,
                height: timeHeaderHeight
            )
            attr.zIndex = 8000
            attr.isTopLeftHeader = true
            return attr
        }
        
        // 2. Time Header
        if indexPath.section == 0 {
            let colIndex = indexPath.item - 1
            let attr = EPGLayoutAttributes(forCellWith: indexPath)
            attr.frame = CGRect(
                x: channelColumnWidth + (CGFloat(colIndex) * eventCardHourWidth),
                y: cv.contentOffset.y,
                width: eventCardHourWidth,
                height: timeHeaderHeight
            )
            attr.zIndex = 7000
            attr.isTimeHeader = true
            return attr
        }
        
        let rowIndex = indexPath.item
        
        // 3. Channel Header
        if indexPath.section == 1 {
            let attr = EPGLayoutAttributes(forCellWith: indexPath)
            let yPos = timeHeaderHeight + (CGFloat(rowIndex) * channelRowHeight)
            attr.frame = CGRect(
                x: cv.contentOffset.x,
                y: yPos,
                width: channelColumnWidth,
                height: channelRowHeight
            )
            attr.zIndex = 6000
            attr.isChannelHeader = true
            return attr
        }
        
        // 4. Events
        if indexPath.section == 2 {
            if isSkeletonMode {
                let attr = EPGLayoutAttributes(forCellWith: indexPath)
                attr.frame = CGRect(x: 0, y: timeHeaderHeight + (CGFloat(rowIndex) * channelRowHeight), width: contentWidth, height: channelRowHeight)
                return attr
            }
            
            guard !channelEventStartIndices.isEmpty else { return nil }
            
            let globalIndex = indexPath.item
            var cIndex = -1
            
            // Find insertion point
            var low = 0
            var high = channelEventStartIndices.count - 1
            while low <= high {
                let mid = (low + high) / 2
                if channelEventStartIndices[mid] <= globalIndex {
                    cIndex = mid
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            
            if cIndex >= 0 && cIndex < channels.count {
                let channel = channels[cIndex]
                let events = epgEventsForDisplay[channel.id] ?? []
                let localIndex = globalIndex - channelEventStartIndices[cIndex]
                
                if localIndex < events.count {
                    let event = events[localIndex]
                    return calculateEventAttribute(for: event, at: indexPath, channelIndex: cIndex)
                }
            }
        }
        
        return nil
    }
    
    // MARK: - Production Grade Frame Calculation
    private func calculateEventAttribute(for event: EPGEvent, at indexPath: IndexPath, channelIndex: Int) -> EPGLayoutAttributes {
        let attr = EPGLayoutAttributes(forCellWith: indexPath)
        
        let rowTopY = timeHeaderHeight + (CGFloat(channelIndex) * channelRowHeight)
        
        let clampedStartTime = max(event.start, earliestDisplayDate)
        let clampedStartOffsetHours = clampedStartTime.timeIntervalSince(earliestDisplayDate) / 3600.0
        let startX = channelColumnWidth + (clampedStartOffsetHours * eventCardHourWidth)
        
        let clampedEndTime = event.end
        let clampedEndOffsetHours = clampedEndTime.timeIntervalSince(earliestDisplayDate) / 3600.0
        let width = max(30.0, (clampedEndOffsetHours - clampedStartOffsetHours) * eventCardHourWidth - 1)
        
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        let yOffset = isPhone ? iphoneChannelNameOverlayHeight : 0
        let adjustedHeight = isPhone ? channelRowHeight - yOffset : channelRowHeight
        
        #if os(tvOS)
        let cellGap: CGFloat = 8
        attr.frame = CGRect(
            x: startX + (cellGap / 2),
            y: rowTopY + (cellGap / 2),
            width: max(1, width - cellGap),
            height: max(1, adjustedHeight - cellGap)
        )
        #else
        attr.frame = CGRect(
            x: startX,
            y: rowTopY + yOffset,
            width: width,
            height: adjustedHeight
        )
        #endif
        
        attr.zIndex = (indexPath == expandedEventIndexPath) ? 100 : 50
        return attr
    }

    override func layoutAttributesForSupplementaryView(ofKind elementKind: String, at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let cv = collectionView else { return nil }
        
        if elementKind == EPGCollectionViewLayout.currentTimeIndicatorKind {
            if !isSkeletonMode {
                let attr = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: elementKind, with: indexPath)
                let now = Date()
                let currentHourOffset = now.timeIntervalSince(earliestDisplayDate) / 3600.0
                
                let indicatorWidth: CGFloat = UIDevice.current.userInterfaceIdiom == .tv ? 6 : 3
                
                attr.frame = CGRect(
                    x: channelColumnWidth + (currentHourOffset * eventCardHourWidth),
                    y: cv.contentOffset.y, // Sticky Y
                    width: indicatorWidth,
                    height: cv.bounds.height
                )
                attr.zIndex = 400
                return attr
            }
        } else if elementKind == EPGCollectionViewLayout.hourDividerKind {
            let attr = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: elementKind, with: indexPath)
            let item = indexPath.item
            attr.frame = CGRect(
                x: channelColumnWidth + (CGFloat(item + 1) * eventCardHourWidth) - 0.5,
                y: 0,
                width: 1,
                height: contentHeight
            )
            attr.zIndex = 10
            return attr
        } else if elementKind == EPGCollectionViewLayout.rowFocusAnchorKind {
            let attr = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: elementKind, with: indexPath)
            let rowIndex = indexPath.item
            let rowY = timeHeaderHeight + (CGFloat(rowIndex) * channelRowHeight)
            let stickyX = cv.contentOffset.x + channelColumnWidth
            
            attr.frame = CGRect(x: stickyX, y: rowY, width: 2, height: channelRowHeight)
            attr.zIndex = 1000
            attr.isHidden = false
            return attr
        }
        
        return nil
    }
}
