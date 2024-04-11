//
//  FaviconDownloader.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 11/19/17.
//  Copyright © 2017 Ranchero Software. All rights reserved.
//

import Foundation
import CoreServices
import Articles
import Account
import UniformTypeIdentifiers
import Core

extension Notification.Name {
	static let FaviconDidBecomeAvailable = Notification.Name("FaviconDidBecomeAvailableNotification") // userInfo key: FaviconDownloader.UserInfoKey.faviconURL
}

@MainActor final class FaviconDownloader {

	private static let saveQueue = CoalescingQueue(name: "Cache Save Queue", interval: 1.0)

	private let folder: String
	private let diskCache: BinaryDiskCache
	private var singleFaviconDownloaderCache = [String: SingleFaviconDownloader]() // faviconURL: SingleFaviconDownloader
	private var remainingFaviconURLs = [String: ArraySlice<String>]() // homePageURL: array of faviconURLs that haven't been checked yet
	private var currentHomePageHasOnlyFaviconICO = false

	private var homePageToFaviconURLCache = [String: String]() //homePageURL: faviconURL
	private var homePageToFaviconURLCachePath: String
	private var homePageToFaviconURLCacheDirty = false {
		didSet {
			queueSaveHomePageToFaviconURLCacheIfNeeded()
		}
	}

	private var homePageURLsWithNoFaviconURLCache = Set<String>()
	private var homePageURLsWithNoFaviconURLCachePath: String
	private var homePageURLsWithNoFaviconURLCacheDirty = false {
		didSet {
			queueSaveHomePageURLsWithNoFaviconURLCacheIfNeeded()
		}
	}

	private let queue: DispatchQueue
	private var cache = [Feed: IconImage]() // faviconURL: RSImage

	struct UserInfoKey {
		static let faviconURL = "faviconURL"
	}

	init(folder: String) {

		self.folder = folder
		self.diskCache = BinaryDiskCache(folder: folder)
		self.queue = DispatchQueue(label: "FaviconDownloader serial queue - \(folder)")

		self.homePageToFaviconURLCachePath = (folder as NSString).appendingPathComponent("HomePageToFaviconURLCache.plist")
		self.homePageURLsWithNoFaviconURLCachePath = (folder as NSString).appendingPathComponent("HomePageURLsWithNoFaviconURLCache.plist")
		loadHomePageToFaviconURLCache()
		loadHomePageURLsWithNoFaviconURLCache()

		NotificationCenter.default.addObserver(self, selector: #selector(didLoadFavicon(_:)), name: .DidLoadFavicon, object: nil)
	}

	// MARK: - API

	func resetCache() {
		cache = [Feed: IconImage]()
	}
	
	func favicon(for feed: Feed) -> IconImage? {

		assert(Thread.isMainThread)

		var homePageURL = feed.homePageURL
		if let faviconURL = feed.faviconURL {
			return favicon(with: faviconURL, homePageURL: homePageURL)
		}

		if homePageURL == nil {
			// Base homePageURL off feedURL if needed. Won’t always be accurate, but is good enough.
			if let feedURL = URL(string: feed.url), let scheme = feedURL.scheme, let host = feedURL.host {
				homePageURL = scheme + "://" + host + "/"
			}
		}
		if let homePageURL = homePageURL {
			return favicon(withHomePageURL: homePageURL)
		}

		return nil
	}
	
	func faviconAsIcon(for feed: Feed) -> IconImage? {
		
		if let image = cache[feed] {
			return image
		}
		
		if let iconImage = favicon(for: feed), let imageData = iconImage.image.dataRepresentation() {
			if let scaledImage = RSImage.scaledForIcon(imageData) {
				let scaledIconImage = IconImage(scaledImage)
				cache[feed] = scaledIconImage
				return scaledIconImage
			}
		}
		
		return nil
	}

	func favicon(with faviconURL: String, homePageURL: String?) -> IconImage? {
		let downloader = faviconDownloader(withURL: faviconURL, homePageURL: homePageURL)
		return downloader.iconImage
	}

	func favicon(withHomePageURL homePageURL: String) -> IconImage? {

		let url = homePageURL.normalizedURL

		if let url = URL(string: homePageURL) {
			if url.host == "nnw.ranchero.com" || url.host == "netnewswire.blog" {
				return IconImage.appIcon
			}
		}

		if homePageURLsWithNoFaviconURLCache.contains(url) {
			return nil
		}

		if let faviconURL = homePageToFaviconURLCache[url] {
			return favicon(with: faviconURL, homePageURL: url)
		}

		Task { @MainActor in

			if let faviconURLs = await findFaviconURLs(with: url) {

				// If the site explicitly specifies favicon.ico, it will appear twice.
				self.currentHomePageHasOnlyFaviconICO = faviconURLs.count == 1

				if let firstIconURL = faviconURLs.first {
					let _ = self.favicon(with: firstIconURL, homePageURL: url)
					self.remainingFaviconURLs[url] = faviconURLs.dropFirst()
				}
			}
		}

		return nil
	}

	// MARK: - Notifications

	@objc func didLoadFavicon(_ note: Notification) {

		guard let singleFaviconDownloader = note.object as? SingleFaviconDownloader else {
			return
		}
		guard let homePageURL = singleFaviconDownloader.homePageURL else {
			return
		}
		guard let _ = singleFaviconDownloader.iconImage else {
			if let faviconURLs = remainingFaviconURLs[homePageURL] {
				if let nextIconURL = faviconURLs.first {
					let _ = favicon(with: nextIconURL, homePageURL: singleFaviconDownloader.homePageURL)
					remainingFaviconURLs[homePageURL] = faviconURLs.dropFirst();
				} else {
					remainingFaviconURLs[homePageURL] = nil

					if currentHomePageHasOnlyFaviconICO {
						self.homePageURLsWithNoFaviconURLCache.insert(homePageURL)
						self.homePageURLsWithNoFaviconURLCacheDirty = true
					}
				}
			}
			return
		}

		remainingFaviconURLs[homePageURL] = nil

		postFaviconDidBecomeAvailableNotification(singleFaviconDownloader.faviconURL)
	}
	
	@objc func saveHomePageToFaviconURLCacheIfNeeded() {
		if homePageToFaviconURLCacheDirty {
			saveHomePageToFaviconURLCache()
		}
	}
	
	@objc func saveHomePageURLsWithNoFaviconURLCacheIfNeeded() {
		if homePageURLsWithNoFaviconURLCacheDirty {
			saveHomePageURLsWithNoFaviconURLCache()
		}
	}
}

private extension FaviconDownloader {

	static let localeForLowercasing = Locale(identifier: "en_US")

	func findFaviconURLs(with homePageURL: String) async -> [String]? {

		guard let url = URL(unicodeString: homePageURL) else {
			return nil
		}
		guard let faviconURLs = await FaviconURLFinder.findFaviconURLs(with: homePageURL) else {
			return nil
		}

		guard let scheme = url.scheme, let host = url.host else {
			return faviconURLs
		}

		let defaultFaviconURL = "\(scheme)://\(host)/favicon.ico".lowercased(with: FaviconDownloader.localeForLowercasing)
		return faviconURLs + [defaultFaviconURL]
	}

	func faviconDownloader(withURL faviconURL: String, homePageURL: String?) -> SingleFaviconDownloader {

		var firstTimeSeeingHomepageURL = false
		
		if let homePageURL = homePageURL, self.homePageToFaviconURLCache[homePageURL] == nil {
			self.homePageToFaviconURLCache[homePageURL] = faviconURL
			self.homePageToFaviconURLCacheDirty = true
			firstTimeSeeingHomepageURL = true
		}

		if let downloader = singleFaviconDownloaderCache[faviconURL] {
			if firstTimeSeeingHomepageURL && !downloader.downloadFaviconIfNeeded() {
				// This is to handle the scenario where we have different homepages, but the same favicon.
				// This happens for Twitter and probably other sites like Blogger.  Because the favicon
				// is cached, we wouldn't send out a notification that it is now available unless we send
				// it here.
				postFaviconDidBecomeAvailableNotification(faviconURL)
			}
			return downloader
		}

		let downloader = SingleFaviconDownloader(faviconURL: faviconURL, homePageURL: homePageURL, diskCache: diskCache)
		singleFaviconDownloaderCache[faviconURL] = downloader
		return downloader
	}

	func postFaviconDidBecomeAvailableNotification(_ faviconURL: String) {

		DispatchQueue.main.async {
			let userInfo: [AnyHashable: Any] = [UserInfoKey.faviconURL: faviconURL]
			NotificationCenter.default.post(name: .FaviconDidBecomeAvailable, object: self, userInfo: userInfo)
		}
	}

	func loadHomePageToFaviconURLCache() {
		let url = URL(fileURLWithPath: homePageToFaviconURLCachePath)
		guard let data = try? Data(contentsOf: url) else {
			return
		}
		let decoder = PropertyListDecoder()
		homePageToFaviconURLCache = (try? decoder.decode([String: String].self, from: data)) ?? [String: String]()
	}

	func loadHomePageURLsWithNoFaviconURLCache() {
		let url = URL(fileURLWithPath: homePageURLsWithNoFaviconURLCachePath)
		guard let data = try? Data(contentsOf: url) else {
			return
		}
		let decoder = PropertyListDecoder()
		let decoded = (try? decoder.decode([String].self, from: data)) ?? [String]()
		homePageURLsWithNoFaviconURLCache = Set(decoded)
	}

	func queueSaveHomePageToFaviconURLCacheIfNeeded() {
		Task { @MainActor in
			FaviconDownloader.saveQueue.add(self, #selector(saveHomePageToFaviconURLCacheIfNeeded))
		}
	}

	func queueSaveHomePageURLsWithNoFaviconURLCacheIfNeeded() {
		Task { @MainActor in
			FaviconDownloader.saveQueue.add(self, #selector(saveHomePageURLsWithNoFaviconURLCacheIfNeeded))
		}
	}

	func saveHomePageToFaviconURLCache() {
		homePageToFaviconURLCacheDirty = false

		let encoder = PropertyListEncoder()
		encoder.outputFormat = .binary
		let url = URL(fileURLWithPath: homePageToFaviconURLCachePath)
		do {
			let data = try encoder.encode(homePageToFaviconURLCache)
			try data.write(to: url)
		} catch {
			assertionFailure(error.localizedDescription)
		}
	}
	
	func saveHomePageURLsWithNoFaviconURLCache() {
		homePageURLsWithNoFaviconURLCacheDirty = false

		let encoder = PropertyListEncoder()
		encoder.outputFormat = .binary
		let url = URL(fileURLWithPath: homePageURLsWithNoFaviconURLCachePath)
		do {
			let data = try encoder.encode(Array(homePageURLsWithNoFaviconURLCache))
			try data.write(to: url)
		} catch {
			assertionFailure(error.localizedDescription)
		}
	}
}
