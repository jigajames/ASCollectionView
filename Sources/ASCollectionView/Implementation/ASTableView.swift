// ASCollectionView. Created by Apptek Studios 2019

import Combine
import SwiftUI

@available(iOS 13.0, *)
extension ASTableView where SectionID == Int
{
	/**
	 Initializes a  table view with a single section.

	 - Parameters:
	 - section: A single section (ASTableViewSection)
	 */
	public init(style: UITableView.Style = .plain, section: Section)
	{
		self.style = style
		sections = [section]
	}

	/**
	 Initializes a  table view with a single section.
	 */
	public init<DataCollection: RandomAccessCollection, DataID: Hashable, Content: View>(
		style: UITableView.Style = .plain,
		data: DataCollection,
		dataID dataIDKeyPath: KeyPath<DataCollection.Element, DataID>,
		@ViewBuilder contentBuilder: @escaping ((DataCollection.Element, ASCellContext) -> Content))
		where DataCollection.Index == Int
	{
		self.style = style
		let section = ASSection(
			id: 0,
			data: data,
			dataID: dataIDKeyPath,
			contentBuilder: contentBuilder)
		sections = [section]
	}

	/**
	 Initializes a  table view with a single section of identifiable data
	 */
	public init<DataCollection: RandomAccessCollection, Content: View>(
		style: UITableView.Style = .plain,
		data: DataCollection,
		@ViewBuilder contentBuilder: @escaping ((DataCollection.Element, ASCellContext) -> Content))
		where DataCollection.Index == Int, DataCollection.Element: Identifiable
	{
		self.init(style: style, data: data, dataID: \.id, contentBuilder: contentBuilder)
	}

	/**
	 Initializes a  table view with a single section of static content
	 */
	public static func `static`(@ViewArrayBuilder staticContent: () -> ViewArrayBuilder.Wrapper) -> ASTableView
	{
		ASTableView(
			style: .plain,
			sections: [ASTableViewSection(id: 0, content: staticContent)])
	}
}

@available(iOS 13.0, *)
public typealias ASTableViewSection = ASSection

@available(iOS 13.0, *)
public struct ASTableView<SectionID: Hashable>: UIViewControllerRepresentable, ContentSize
{
	// MARK: Type definitions

	public typealias Section = ASTableViewSection<SectionID>

	public typealias OnScrollCallback = ((_ contentOffset: CGPoint, _ contentSize: CGSize) -> Void)
	public typealias OnReachedBottomCallback = (() -> Void)

	// MARK: Key variables

	public var sections: [Section]
	public var style: UITableView.Style

	// MARK: Private vars set by public modifiers

	internal var onScrollCallback: OnScrollCallback?
	internal var onReachedBottomCallback: OnReachedBottomCallback?

	internal var scrollIndicatorEnabled: Bool = true
	internal var contentInsets: UIEdgeInsets = .zero

	internal var separatorsEnabled: Bool = true

	internal var onPullToRefresh: ((_ endRefreshing: @escaping (() -> Void)) -> Void)?

	internal var alwaysBounce: Bool = false
	internal var animateOnDataRefresh: Bool = true

	// MARK: Environment variables

	@Environment(\.editMode) private var editMode

	@Environment(\.invalidateCellLayout) var invalidateParentCellLayout // Call this if using content size binding (nested inside another ASCollectionView)

	// Other
	var contentSizeTracker: ContentSizeTracker?

	/**
	 Initializes a  table view with the given sections

	 - Parameters:
	 - sections: An array of sections (ASTableViewSection)
	 */
	@inlinable public init(style: UITableView.Style = .plain, sections: [Section])
	{
		self.style = style
		self.sections = sections
	}

	@inlinable public init(style: UITableView.Style = .plain, @SectionArrayBuilder <SectionID> sectionBuilder: () -> [Section])
	{
		self.style = style
		sections = sectionBuilder()
	}

	public func makeUIViewController(context: Context) -> AS_TableViewController
	{
		context.coordinator.parent = self

		let tableViewController = AS_TableViewController(style: style)
		tableViewController.coordinator = context.coordinator

		context.coordinator.tableViewController = tableViewController
		context.coordinator.updateTableViewSettings(tableViewController.tableView)

		context.coordinator.setupDataSource(forTableView: tableViewController.tableView)
		return tableViewController
	}

	public func updateUIViewController(_ tableViewController: AS_TableViewController, context: Context)
	{
		context.coordinator.parent = self
		context.coordinator.updateTableViewSettings(tableViewController.tableView)
		context.coordinator.updateContent(tableViewController.tableView, transaction: context.transaction, refreshExistingCells: true)
		context.coordinator.configureRefreshControl(for: tableViewController.tableView)
#if DEBUG
		debugOnly_checkHasUniqueSections()
#endif
	}

	public func makeCoordinator() -> Coordinator
	{
		Coordinator(self)
	}

#if DEBUG
	func debugOnly_checkHasUniqueSections()
	{
		var sectionIDs: Set<SectionID> = []
		var conflicts: Set<SectionID> = []
		sections.forEach {
			let (inserted, _) = sectionIDs.insert($0.id)
			if !inserted
			{
				conflicts.insert($0.id)
			}
		}
		if !conflicts.isEmpty
		{
			print("ASTABLEVIEW: The following section IDs are used more than once, please use unique section IDs to avoid unexpected behaviour:", conflicts)
		}
	}
#endif

	public class Coordinator: NSObject, ASTableViewCoordinator, UITableViewDelegate, UITableViewDataSourcePrefetching, UITableViewDragDelegate, UITableViewDropDelegate
	{
		var parent: ASTableView
		weak var tableViewController: AS_TableViewController?

		var dataSource: ASDiffableDataSourceTableView<SectionID>?

		let cellReuseID = UUID().uuidString
		let supplementaryReuseID = UUID().uuidString

		// MARK: Private tracking variables

		private var hasDoneInitialSetup = false
		private var rowsToReload: Set<IndexPath> = []

		// MARK: Caching

		private var autoCachingHostingControllers = ASPriorityCache<ASCollectionViewItemUniqueID, ASHostingControllerProtocol>()
		private var explicitlyCachedHostingControllers: [ASCollectionViewItemUniqueID: ASHostingControllerProtocol] = [:]
		private var autoCachingSupplementaryHostControllers = ASPriorityCache<ASSupplementaryCellID<SectionID>, ASHostingControllerProtocol>()
		
		
		typealias Cell = ASTableViewCell

		init(_ parent: ASTableView)
		{
			self.parent = parent
		}

		func itemID(for indexPath: IndexPath) -> ASCollectionViewItemUniqueID?
		{
			guard
				let sectionID = sectionID(fromSectionIndex: indexPath.section)
			else { return nil }
			return parent.sections[safe: indexPath.section]?.dataSource.getItemID(for: indexPath.item, withSectionID: sectionID)
		}

		func sectionID(fromSectionIndex sectionIndex: Int) -> SectionID?
		{
			parent.sections[safe: sectionIndex]?.id
		}

		func section(forItemID itemID: ASCollectionViewItemUniqueID) -> Section?
		{
			parent.sections
				.first(where: { $0.id.hashValue == itemID.sectionIDHash })
		}

		func updateTableViewSettings(_ tableView: UITableView)
		{
			assignIfChanged(tableView, \.backgroundColor, newValue: (parent.style == .plain) ? .clear : .systemGroupedBackground)
			assignIfChanged(tableView, \.separatorStyle, newValue: parent.separatorsEnabled ? .singleLine : .none)
			assignIfChanged(tableView, \.contentInset, newValue: parent.contentInsets)
			assignIfChanged(tableView, \.alwaysBounceVertical, newValue: parent.alwaysBounce)
			assignIfChanged(tableView, \.showsVerticalScrollIndicator, newValue: parent.scrollIndicatorEnabled)
			assignIfChanged(tableView, \.showsHorizontalScrollIndicator, newValue: parent.scrollIndicatorEnabled)
			assignIfChanged(tableView, \.keyboardDismissMode, newValue: .onDrag)

			let isEditing = parent.editMode?.wrappedValue.isEditing ?? false
			assignIfChanged(tableView, \.allowsMultipleSelection, newValue: isEditing)
			if assignIfChanged(tableView, \.allowsSelection, newValue: isEditing)
			{
				updateSelectionBindings(tableView)
			}
		}

		func setupDataSource(forTableView tv: UITableView)
		{
			tv.delegate = self
			tv.prefetchDataSource = self

			tv.dragDelegate = self
			tv.dropDelegate = self
			tv.dragInteractionEnabled = true

			tv.register(Cell.self, forCellReuseIdentifier: cellReuseID)
			tv.register(ASTableViewSupplementaryView.self, forHeaderFooterViewReuseIdentifier: supplementaryReuseID)

			dataSource = .init(tableView: tv)
			{ [weak self] tableView, indexPath, itemID in
				guard let self = self else { return nil }
				guard
					let cell = tableView.dequeueReusableCell(withIdentifier: self.cellReuseID, for: indexPath) as? Cell
				else { return nil }

				guard let section = self.parent.sections[safe: indexPath.section] else { return cell }

				cell.backgroundColor = (self.parent.style == .plain || section.disableDefaultTheming) ? .clear : .secondarySystemGroupedBackground

				cell.separatorInset = section.tableViewSeparatorInsets ?? UIEdgeInsets(top: 0, left: UITableView.automaticDimension, bottom: 0, right: UITableView.automaticDimension)

				// Cell layout invalidation callback
				cell.invalidateLayoutCallback = { [weak self] animated in
					self?.reloadRows([indexPath], animated: true) //Reload now in case the state change is within the cell (aka no reload of ASTableView)
					self?.rowsToReload.insert(indexPath)
				}
				cell.scrollToCellCallback = { [weak self] position in
					self?.scrollToRow(indexPath: indexPath, position: position)
				}

				// Self Sizing Settings
				let selfSizingContext = ASSelfSizingContext(cellType: .content, indexPath: indexPath)
				cell.selfSizingConfig =
					section.dataSource.getSelfSizingSettings(context: selfSizingContext)
						?? ASSelfSizingConfig(selfSizeHorizontally: false, selfSizeVertically: true)

				// Set itemID
				cell.indexPath = indexPath
				cell.itemID = itemID

				// Update hostingController
				let cachedHC = self.explicitlyCachedHostingControllers[itemID] ?? self.autoCachingHostingControllers[itemID]
				cell.hostingController = section.dataSource.updateOrCreateHostController(forItemID: itemID, existingHC: cachedHC)
				// Cache the HC
				self.autoCachingHostingControllers[itemID] = cell.hostingController
				if section.shouldCacheCells
				{
					self.explicitlyCachedHostingControllers[itemID] = cell.hostingController
				}

				return cell
			}
		}

		func populateDataSource(animated: Bool = true)
		{
			guard hasDoneInitialSetup else { return }
			let snapshot = ASDiffableDataSourceSnapshot(sections:
				parent.sections.map {
					ASDiffableDataSourceSnapshot.Section(id: $0.id, elements: $0.itemIDs)
				}
			)
			dataSource?.applySnapshot(snapshot, animated: animated)
			tableViewController.map { self.didUpdateContentSize($0.tableView.contentSize) }
		}

		func updateContent(_ tv: UITableView, transaction: Transaction?, refreshExistingCells: Bool)
		{
			guard hasDoneInitialSetup else { return }

			let transactionAnimationEnabled = (transaction?.animation != nil) && !(transaction?.disablesAnimations ?? false)
			populateDataSource(animated: parent.animateOnDataRefresh && transactionAnimationEnabled)

			if refreshExistingCells
			{
				withAnimation(parent.animateOnDataRefresh ? transaction?.animation : nil) {
					refreshVisibleCells()
					reloadRows(rowsToReload, animated: transactionAnimationEnabled)
					rowsToReload.removeAll()
				}
			}
			updateSelectionBindings(tv)
		}

		func refreshVisibleCells()
		{
			guard let tv = tableViewController?.tableView else { return }
			for case let cell as Cell in tv.visibleCells
			{
				guard
					let itemID = cell.itemID,
					let hc = cell.hostingController
				else { return }
				self.section(forItemID: itemID)?.dataSource.update(hc, forItemID: itemID)
			}

			tv.visibleHeaderViews.forEach { sectionIndex, view in
				configureSupplementary(view, supplementaryKind: UICollectionView.elementKindSectionHeader, forSection: sectionIndex)
			}

			tv.visibleFooterViews.forEach { sectionIndex, view in
				configureSupplementary(view, supplementaryKind: UICollectionView.elementKindSectionFooter, forSection: sectionIndex)
			}
		}

		func reloadRows(_ indexPaths: Set<IndexPath>, animated: Bool)
		{
			dataSource?.reloadItems(indexPaths, animated: animated)
		}

		func scrollToRow(indexPath: IndexPath, position: UITableView.ScrollPosition = .none)
		{
			tableViewController?.tableView.scrollToRow(at: indexPath, at: position, animated: true)
		}

		func onMoveToParent()
		{
			if !hasDoneInitialSetup
			{
				hasDoneInitialSetup = true

				// Populate data source
				populateDataSource(animated: false)

				// Check if reached bottom already
				tableViewController.map { checkIfReachedBottom($0.tableView) }
			}
		}

		func onMoveFromParent()
		{}

		// MARK: Function for updating contentSize binding

		var lastContentSize: CGSize = .zero
		func didUpdateContentSize(_ size: CGSize)
		{
			guard let tv = tableViewController?.tableView, tv.contentSize != lastContentSize else { return }
			let firstSize = lastContentSize == .zero
			lastContentSize = tv.contentSize
			parent.contentSizeTracker?.contentSize = size
			DispatchQueue.main.async {
				self.parent.invalidateParentCellLayout?(!firstSize)
			}
		}

		func configureRefreshControl(for tv: UITableView)
		{
			guard parent.onPullToRefresh != nil else
			{
				if tv.refreshControl != nil
				{
					tv.refreshControl = nil
				}
				return
			}
			if tv.refreshControl == nil
			{
				let refreshControl = UIRefreshControl()
				refreshControl.addTarget(self, action: #selector(tableViewDidPullToRefresh), for: .valueChanged)
				tv.refreshControl = refreshControl
			}
		}

		@objc
		public func tableViewDidPullToRefresh()
		{
			guard let tableView = tableViewController?.tableView else { return }
			let endRefreshing: (() -> Void) = { [weak tableView] in
				tableView?.refreshControl?.endRefreshing()
			}
			parent.onPullToRefresh?(endRefreshing)
		}

		public func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath)
		{
			tableViewController.map { (cell as? Cell)?.willAppear(in: $0) }
			parent.sections[safe: indexPath.section]?.dataSource.onAppear(indexPath)
		}

		public func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath)
		{
			(cell as? Cell)?.didDisappear()
			parent.sections[safe: indexPath.section]?.dataSource.onDisappear(indexPath)
		}

		public func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int)
		{
			tableViewController.map { (view as? ASTableViewSupplementaryView)?.willAppear(in: $0) }
		}

		public func tableView(_ tableView: UITableView, didEndDisplayingHeaderView view: UIView, forSection section: Int)
		{
			(view as? ASTableViewSupplementaryView)?.didDisappear()
		}

		public func tableView(_ tableView: UITableView, willDisplayFooterView view: UIView, forSection section: Int)
		{
			tableViewController.map { (view as? ASTableViewSupplementaryView)?.willAppear(in: $0) }
		}

		public func tableView(_ tableView: UITableView, didEndDisplayingFooterView view: UIView, forSection section: Int)
		{
			(view as? ASTableViewSupplementaryView)?.didDisappear()
		}

		public func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath])
		{
			let itemIDsToPrefetchBySection: [Int: [IndexPath]] = Dictionary(grouping: indexPaths) { $0.section }
			itemIDsToPrefetchBySection.forEach
			{
				parent.sections[safe: $0.key]?.dataSource.prefetch($0.value)
			}
		}

		public func tableView(_ tableView: UITableView, cancelPrefetchingForRowsAt indexPaths: [IndexPath])
		{
			let itemIDsToCancelPrefetchBySection: [Int: [IndexPath]] = Dictionary(grouping: indexPaths) { $0.section }
			itemIDsToCancelPrefetchBySection.forEach
			{
				parent.sections[safe: $0.key]?.dataSource.cancelPrefetch($0.value)
			}
		}

		// MARK: Swipe actions

		public func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration?
		{
			guard parent.sections[safe: indexPath.section]?.dataSource.supportsDelete(at: indexPath) == true else { return nil }
			let deleteAction = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completionHandler in
				self?.onDeleteAction(indexPath: indexPath, completionHandler: completionHandler)
			}
			return UISwipeActionsConfiguration(actions: [deleteAction])
		}

		public func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle
		{
			.none
		}

		private func onDeleteAction(indexPath: IndexPath, completionHandler: (Bool) -> Void)
		{
			parent.sections[safe: indexPath.section]?.dataSource.onDelete(indexPath: indexPath, completionHandler: completionHandler)
		}

		// MARK: Cell Selection

		public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath)
		{
			updateContent(tableView, transaction: nil, refreshExistingCells: true)
		}

		public func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath)
		{
			updateContent(tableView, transaction: nil, refreshExistingCells: true)
		}

		func updateSelectionBindings(_ tableView: UITableView)
		{
			let selected = tableView.allowsSelection ? (tableView.indexPathsForSelectedRows ?? []) : []
			let selectionBySection = Dictionary(grouping: selected) { $0.section }
				.mapValues
			{
				Set($0.map { $0.item })
			}
			parent.sections.enumerated().forEach { offset, section in
				section.dataSource.updateSelection(selectionBySection[offset] ?? [])
			}
		}

		public func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath?
		{
			guard parent.sections[safe: indexPath.section]?.dataSource.shouldSelect(indexPath) ?? false else
			{
				return nil
			}
			return indexPath
		}

		public func tableView(_ tableView: UITableView, willDeselectRowAt indexPath: IndexPath) -> IndexPath?
		{
			guard parent.sections[safe: indexPath.section]?.dataSource.shouldDeselect(indexPath) ?? false else
			{
				return nil
			}
			return indexPath
		}

		public func tableView(_ tableView: UITableView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem]
		{
			guard !indexPath.isEmpty else { return [] }
			guard let dragItem = parent.sections[safe: indexPath.section]?.dataSource.getDragItem(for: indexPath) else { return [] }
			return [dragItem]
		}

		func canDrop(at indexPath: IndexPath) -> Bool
		{
			guard !indexPath.isEmpty else { return false }
			return parent.sections[safe: indexPath.section]?.dataSource.dropEnabled ?? false
		}

		public func tableView(_ tableView: UITableView, dropSessionDidUpdate session: UIDropSession, withDestinationIndexPath destinationIndexPath: IndexPath?) -> UITableViewDropProposal
		{
			if tableView.hasActiveDrag
			{
				if let destination = destinationIndexPath
				{
					guard canDrop(at: destination) else
					{
						return UITableViewDropProposal(operation: .cancel)
					}
				}
				return UITableViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
			}
			else
			{
				return UITableViewDropProposal(operation: .copy, intent: .insertAtDestinationIndexPath)
			}
		}

		public func tableView(_ tableView: UITableView, performDropWith coordinator: UITableViewDropCoordinator)
		{
			guard
				let destinationIndexPath = coordinator.destinationIndexPath,
				!destinationIndexPath.isEmpty,
				let destinationSection = parent.sections[safe: destinationIndexPath.section]
			else { return }

			guard canDrop(at: destinationIndexPath) else { return }

			guard let oldSnapshot = dataSource?.currentSnapshot else { return }
			var dragSnapshot = oldSnapshot

			switch coordinator.proposal.operation
			{
			case .move:
				guard destinationSection.dataSource.reorderingEnabled else { return }
				let itemsBySourceSection = Dictionary(grouping: coordinator.items) { item -> Int? in
					if let sourceIndex = item.sourceIndexPath, !sourceIndex.isEmpty
					{
						return sourceIndex.section
					}
					else
					{
						return nil
					}
				}

				let sourceSections = itemsBySourceSection.keys.sorted { a, b in
					guard let a = a else { return false }
					guard let b = b else { return true }
					return a < b
				}

				var itemsToInsert: [UITableViewDropItem] = []

				for sourceSectionIndex in sourceSections
				{
					guard let items = itemsBySourceSection[sourceSectionIndex] else { continue }

					if
						let sourceSectionIndex = sourceSectionIndex,
						let sourceSection = parent.sections[safe: sourceSectionIndex]
					{
						guard sourceSection.dataSource.reorderingEnabled else { continue }

						let sourceIndices = items.compactMap { $0.sourceIndexPath?.item }

						// Remove from source section
						dragSnapshot.sections[sourceSectionIndex].elements.remove(atOffsets: IndexSet(sourceIndices))
						sourceSection.dataSource.applyRemove(atOffsets: IndexSet(sourceIndices))
					}

					// Add to insertion array (regardless whether sourceSection is nil)
					itemsToInsert.append(contentsOf: items)
				}

				let itemsToInsertIDs: [ASCollectionViewItemUniqueID] = itemsToInsert.compactMap { item in
					if let sourceIndexPath = item.sourceIndexPath
					{
						return oldSnapshot.sections[sourceIndexPath.section].elements[sourceIndexPath.item]
					}
					else
					{
						return destinationSection.dataSource.getItemID(for: item.dragItem, withSectionID: destinationSection.id)
					}
				}
				dragSnapshot.sections[destinationIndexPath.section].elements.insert(contentsOf: itemsToInsertIDs, at: destinationIndexPath.item)
				destinationSection.dataSource.applyInsert(items: itemsToInsert.map { $0.dragItem }, at: destinationIndexPath.item)

			case .copy:
				destinationSection.dataSource.applyInsert(items: coordinator.items.map { $0.dragItem }, at: destinationIndexPath.item)

			default: break
			}

			dataSource?.applySnapshot(dragSnapshot)
			refreshVisibleCells()

			if let dragItem = coordinator.items.first, let destination = coordinator.destinationIndexPath
			{
				if dragItem.sourceIndexPath != nil
				{
					coordinator.drop(dragItem.dragItem, toRowAt: destination)
				}
			}
		}

		public func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat
		{
			guard parent.sections[safe: section]?.supplementary(ofKind: UICollectionView.elementKindSectionHeader) != nil else
			{
				return CGFloat.leastNormalMagnitude
			}
			return UITableView.automaticDimension
		}

		public func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat
		{
			guard parent.sections[safe: section]?.supplementary(ofKind: UICollectionView.elementKindSectionFooter) != nil else
			{
				return CGFloat.leastNormalMagnitude
			}
			return UITableView.automaticDimension
		}

		public func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView?
		{
			guard let reusableView = tableView.dequeueReusableHeaderFooterView(withIdentifier: supplementaryReuseID) else { return nil }
			configureSupplementary(reusableView, supplementaryKind: UICollectionView.elementKindSectionHeader, forSection: section)
			return reusableView
		}
		
		public func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView?
		{
			guard let reusableView = tableView.dequeueReusableHeaderFooterView(withIdentifier: supplementaryReuseID) else { return nil }
			configureSupplementary(reusableView, supplementaryKind: UICollectionView.elementKindSectionFooter, forSection: section)
			return reusableView
		}

		func configureSupplementary(_ cell: UITableViewHeaderFooterView, supplementaryKind: String, forSection sectionIndex: Int)
		{
			guard let reusableView = cell as? ASTableViewSupplementaryView
			else { return }
		
			let ifEmpty = {
				reusableView.setupForEmpty()
			}
			
			reusableView.id = sectionIndex
			
			guard let section = parent.sections[safe: sectionIndex] else { ifEmpty(); return }
			let supplementaryID = ASSupplementaryCellID(sectionID: section.id, supplementaryKind: supplementaryKind)
			
			// Self Sizing Settings
			let selfSizingContext = ASSelfSizingContext(cellType: .supplementary(supplementaryKind), indexPath: IndexPath(row: 0, section: sectionIndex))
			reusableView.selfSizingConfig =
				section.dataSource.getSelfSizingSettings(context: selfSizingContext)
				?? ASSelfSizingConfig(selfSizeHorizontally: false, selfSizeVertically: true)
			
			// Update hostingController
			let cachedHC = self.autoCachingSupplementaryHostControllers[supplementaryID]
			reusableView.hostingController = section.dataSource.updateOrCreateHostController(forSupplementaryKind: supplementaryKind, existingHC: cachedHC)
			// Cache the HC
			self.autoCachingSupplementaryHostControllers[supplementaryID] = reusableView.hostingController
		}

		// MARK: Context Menu Support

		public func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration?
		{
			guard !indexPath.isEmpty else { return nil }
			return parent.sections[safe: indexPath.section]?.dataSource.getContextMenu(for: indexPath)
		}

		public func scrollViewDidScroll(_ scrollView: UIScrollView)
		{
			parent.onScrollCallback?(scrollView.contentOffset, scrollView.contentSizePlusInsets)
			checkIfReachedBottom(scrollView)
		}

		var hasAlreadyReachedBottom: Bool = false
		func checkIfReachedBottom(_ scrollView: UIScrollView)
		{
			if (scrollView.contentSize.height - scrollView.contentOffset.y) <= scrollView.frame.size.height
			{
				if !hasAlreadyReachedBottom
				{
					hasAlreadyReachedBottom = true
					parent.onReachedBottomCallback?()
				}
			}
			else
			{
				hasAlreadyReachedBottom = false
			}
		}
	}
}

@available(iOS 13.0, *)
protocol ASTableViewCoordinator: AnyObject
{
	func onMoveToParent()
	func onMoveFromParent()
	func didUpdateContentSize(_ size: CGSize)
}