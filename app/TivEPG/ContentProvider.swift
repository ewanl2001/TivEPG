import TVServices

class ContentProvider: TVTopShelfContentProvider {

    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        guard
            let defaults = UserDefaults(suiteName: appGroupID),
            let data = defaults.data(forKey: "TopShelfSectionsData"),
            let exportedSections = try? JSONDecoder().decode([TopShelfExportSection].self, from: data),
            !exportedSections.isEmpty
        else {
            return nil
        }

        // Map your app sections into tvOS Top Shelf Collections natively
        let tvSections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = exportedSections.compactMap { section in
            // Filter out sections that are empty
            guard !section.items.isEmpty else { return nil }
            
            let items: [TVTopShelfSectionedItem] = section.items.compactMap { exportItem in
                guard let deepLink = URL(string: exportItem.deepLinkURL) else { return nil }

                let item = TVTopShelfSectionedItem(identifier: exportItem.id)
                item.title = exportItem.title
                item.playAction = TVTopShelfAction(url: deepLink)
                item.displayAction = TVTopShelfAction(url: deepLink)

                if let imageURLString = exportItem.imageURL, let imageURL = URL(string: imageURLString) {
                    item.setImageURL(imageURL, for: .screenScale1x)
                    item.setImageURL(imageURL, for: .screenScale2x)
                    
                    // Apply dynamic shaping based on content!
                    switch exportItem.imageShape {
                    case .poster:
                        item.imageShape = .poster
                    case .square:
                        item.imageShape = .square
                    case .hdtv:
                        item.imageShape = .hdtv
                    }
                }
                return item
            }
            
            guard !items.isEmpty else { return nil }
            
            // ✅ FIX: Pass title to initializer, not assignment
            let collection = TVTopShelfItemCollection(items: items)
            
            return collection
        }

        guard !tvSections.isEmpty else { return nil }

        // Returns multiple rows on the home screen!
        return TVTopShelfSectionedContent(sections: tvSections)
    }
}
