import Foundation

public struct RecordChange: Equatable, Sendable {
    public let before: StudyInterval?
    public let after: StudyInterval?
    public var id: UUID { (after ?? before!).id }
    public var reversed: RecordChange { RecordChange(before: after, after: before) }
    public init(before: StudyInterval?, after: StudyInterval?) { self.before = before; self.after = after }
}

public struct RecordHistory: Sendable {
    private var undoStack: [RecordChange] = []
    private var redoStack: [RecordChange] = []
    public let limit: Int
    public init(limit: Int = 20) { self.limit = max(1, limit) }
    public var undo: RecordChange? { undoStack.last }
    public var redo: RecordChange? { redoStack.last }
    public var undoCount: Int { undoStack.count }
    public var redoCount: Int { redoStack.count }
    public mutating func record(_ change: RecordChange) {
        guard change.before != change.after else { return }
        undoStack.append(change)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
    }
    /// 仅在数据库提交成功后移动栈。
    public mutating func didUndo() { if let change = undoStack.popLast() { redoStack.append(change) } }
    public mutating func didRedo() { if let change = redoStack.popLast() { undoStack.append(change) } }
    public mutating func clear() { undoStack.removeAll(); redoStack.removeAll() }
}
