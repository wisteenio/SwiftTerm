//
//  TerminalCheckpoint.swift
//  SwiftTerm
//
//  AirCLI production checkpoint contract.
//

import Foundation

/// `TerminalCheckpoint` 是 SwiftTerm terminal core 的版本化、不透明快照。
///
/// 业务层只持有编码后的值，不接触 `Terminal`、`Buffer` 或 parser 私有字段。构造函数会先完成
/// schema、长度与结构校验；真正 import 仍由 `Terminal` 在隔离 candidate 上完成语义校验，最后
/// 经过唯一 commit point 替换 live state。
public struct TerminalCheckpoint: Sendable {
    public static let schemaVersion = 1
    public static let maximumEncodedBytes = 4 * 1024 * 1024
    public static let maximumNormalScrollbackLines = 2_000
    public static let maximumNormalScrollbackBytes = 2 * 1024 * 1024

    private let bytes: Data
    let storage: TerminalCheckpointStorageV1

    /// 已校验 envelope 的实际 byte 数。#57 可以用它执行 capacity/logging，但仍不得解析内容。
    public var encodedByteCount: Int { bytes.count }

    /// 从持久化或 wire bytes 恢复不透明 checkpoint。成功只表示 envelope 完整有效；调用
    /// `Terminal.importCheckpoint(_:)` 后才会提交到指定 terminal。
    public init(encodedBytes: Data) throws {
        guard encodedBytes.count <= Self.maximumEncodedBytes else {
            throw TerminalCheckpointError.encodedLengthExceeded(
                actual: encodedBytes.count,
                maximum: Self.maximumEncodedBytes
            )
        }
        let header: TerminalCheckpointHeader
        do {
            header = try JSONDecoder().decode(TerminalCheckpointHeader.self, from: encodedBytes)
        } catch {
            throw TerminalCheckpointError.malformedEncoding
        }
        guard header.version == Self.schemaVersion else {
            throw TerminalCheckpointError.unsupportedSchemaVersion(header.version)
        }
        let decoded: TerminalCheckpointStorageV1
        do {
            decoded = try JSONDecoder().decode(TerminalCheckpointStorageV1.self, from: encodedBytes)
        } catch {
            throw TerminalCheckpointError.malformedEncoding
        }
        try decoded.validate()
        self.bytes = Data(encodedBytes)
        self.storage = decoded
    }

    init(storage: TerminalCheckpointStorageV1) throws {
        try storage.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(storage)
        try self.init(encodedBytes: encoded)
    }

    /// 返回可持久化或传输的稳定 JSON bytes。调用方必须把它作为不透明 payload 处理。
    /// Session ID、epoch、PTY absolute output offset、hash/chunk/commit 属于 AirCLI #57 的
    /// envelope authority，不得塞进 engine checkpoint 或在此建立第二套 transcript cursor。
    public func encodedBytes() -> Data {
        bytes
    }
}

private struct TerminalCheckpointHeader: Decodable {
    var version: Int
}

/// checkpoint schema 当前无法无损表达的稳定、content-free 原因。
///
/// 调用方可以据此区分“parser 正处于尚未完成的 unknown DCS”与已经进入 terminal state 的
/// unsupported content；禁止依赖诊断字符串决定 retry。新增 case 是公开 checkpoint contract
/// 变更，必须同步 Mac producer 的 retry mapping 与既有跨 engine Gate。
public enum TerminalCheckpointUnsupportedContent: String, Sendable, Equatable {
    case images
    case imagesOrUnknownDCSInFlight
    case nonStringCellPayload
    case payloadCapacity
}

/// Checkpoint export/import 的稳定失败分类。错误不携带 terminal content。
public enum TerminalCheckpointError: Error, Sendable, Equatable {
    case malformedEncoding
    case unsupportedSchemaVersion(Int)
    case encodedLengthExceeded(actual: Int, maximum: Int)
    case normalScrollbackLengthExceeded(actual: Int, maximum: Int)
    case invalidStructure(String)
    case unsupportedContent(TerminalCheckpointUnsupportedContent)
    case cancelled
}

/// V1 的完整 engine state。该类型及其子类型只属于 SwiftTerm module；AirCLI 业务层只能持有
/// `TerminalCheckpoint` 的 opaque bytes。`Terminal.exportCheckpoint()` 是唯一 writer，
/// `Terminal.importCheckpoint(_:)` 是唯一 reader/commit authority，后续版本不得让业务层逐字段拼装。
struct TerminalCheckpointStorageV1: Codable, Sendable {
    var version: Int
    var columns: Int
    var rows: Int
    var activeBuffer: TerminalCheckpointActiveBuffer
    var normal: TerminalCheckpointBufferV1
    var alternate: TerminalCheckpointBufferV1
    var modes: TerminalCheckpointModesV1
    var palette: TerminalCheckpointPaletteV1
    var parser: TerminalCheckpointParserV1

    func validate() throws {
        guard version == TerminalCheckpoint.schemaVersion else {
            throw TerminalCheckpointError.unsupportedSchemaVersion(version)
        }
        guard columns >= 2, columns <= 1_000, rows >= 1, rows <= 1_000 else {
            throw TerminalCheckpointError.invalidStructure("dimensions")
        }
        try normal.validate(columns: columns, rows: rows, isNormal: true)
        try alternate.validate(columns: columns, rows: rows, isNormal: false)
        let activeLineCount = activeBuffer == .normal ? normal.lines.count : alternate.lines.count
        try modes.validate(columns: columns, activeLineCount: activeLineCount)
        try palette.validate()
        try parser.validate()
    }
}

enum TerminalCheckpointActiveBuffer: String, Codable, Sendable {
    case normal
    case alternate
}

/// 一个 terminal buffer 的自足记录。
///
/// `lines` 的下标是 checkpoint 内相对行号；normal 可以是 `[history..., viewport...]`，alternate
/// 必须只含 viewport。`yBase` 指向 viewport 顶行，`yDisplay` 指向用户当前看到的顶行，二者都
/// 相对 `lines[0]`；`linesTrimmed` 是 engine 自创建以来已从顶部淘汰的单调计数，不参与寻址。
/// `x/y` 是 viewport 内 0-based cursor，其中 x 可以等于 columns 表示 autowrap pending。
/// `savedX` 具有同样的横向范围；`savedY` 则是 SwiftTerm resize/reflow 保留的 deferred DECRC
/// 坐标，可能暂时位于 viewport 外，只有真正 restore 时才 clamp。checkpoint 必须原样保存它，
/// 否则恢复后再 resize/DECRC 会改变行为。V1 只接受 Int32 serialized domain：这不是 viewport
/// clamp，而是不可信输入的算术边界；若允许任意 Int，Buffer 会在 resize/reflow 内部运算时溢出。
/// 其余坐标在构造 live `Buffer` 前整体校验，不能边写 live state 边修正。
struct TerminalCheckpointBufferV1: Codable, Sendable {
    /// 固定宽度避免 schema 的安全边界随 host word size 漂移。AirCLI geometry 是 UInt16，V1 又把
    /// viewport/history 限到 1,000/2,000 行，因此 Int32 足以承载当前 production deferred
    /// cursor，并在 64-bit runtime 上为 resize/reflow 留出数个数量级的 Int 运算余量。若 live
    /// engine 理论上累积越界，export 必须 fail closed，不能 clamp。未来扩大此域前，必须先把
    /// normal/alternate Buffer 内全部 savedY 加减法改成 total arithmetic，禁止只放宽此 guard。
    private static let deferredSavedCursorYRange = Int(Int32.min)...Int(Int32.max)
    /// `linesTrimmed` 会在每次 history 淘汰时继续 `+= 1`。V1 只接受 Int32 的非负域，既能
    /// 表达超过二十亿行的累计值，又在 64-bit production runtime 留出充足增长 headroom；
    /// 禁止接受 `Int.max` 之类会让下一次正常 scroll 触发溢出的 checkpoint。
    private static let maximumSerializedLinesTrimmed = Int(Int32.max)

    var lines: [TerminalCheckpointLineV1]
    var scrollbackLimit: Int?
    var x: Int
    var y: Int
    var yBase: Int
    var yDisplay: Int
    var linesTrimmed: Int
    var scrollTop: Int
    var scrollBottom: Int
    var marginLeft: Int
    var marginRight: Int
    var tabStops: [Bool]
    var savedX: Int
    var savedY: Int
    var savedPen: TerminalCheckpointPenV1
    var savedOriginMode: Bool
    var savedMarginMode: Bool
    var savedWraparound: Bool
    var savedReverseWraparound: Bool
    var semantic: TerminalCheckpointBufferSemanticV1

    func validate(columns: Int, rows: Int, isNormal: Bool) throws {
        guard !lines.isEmpty, lines.count >= rows else {
            throw TerminalCheckpointError.invalidStructure("buffer-lines")
        }
        if isNormal {
            let historyLines = lines.count - rows
            guard historyLines <= TerminalCheckpoint.maximumNormalScrollbackLines else {
                throw TerminalCheckpointError.normalScrollbackLengthExceeded(
                    actual: historyLines,
                    maximum: TerminalCheckpoint.maximumNormalScrollbackLines
                )
            }
            guard let scrollbackLimit,
                  scrollbackLimit >= historyLines,
                  scrollbackLimit <= TerminalCheckpoint.maximumNormalScrollbackLines else {
                throw TerminalCheckpointError.invalidStructure("normal-scrollback-limit")
            }
            let historyBytes = try JSONEncoder().encode(Array(lines.prefix(historyLines))).count
            guard historyBytes <= TerminalCheckpoint.maximumNormalScrollbackBytes else {
                throw TerminalCheckpointError.invalidStructure("normal-scrollback-bytes")
            }
        } else {
            guard scrollbackLimit == nil, lines.count == rows else {
                throw TerminalCheckpointError.invalidStructure("alternate-scrollback")
            }
        }
        guard x >= 0, x <= columns else {
            throw TerminalCheckpointError.invalidStructure("cursor-x")
        }
        guard (0..<rows).contains(y) else {
            throw TerminalCheckpointError.invalidStructure("cursor-y")
        }
        // `yBase` 来自不可信 JSON；必须用已经证明非负的差值比较，不能先计算
        // `yBase + rows`，否则 Int.max 会让验证器本身在返回 error 前 trap。
        guard yBase >= 0, yBase <= lines.count - rows else {
            throw TerminalCheckpointError.invalidStructure("buffer-base")
        }
        guard yDisplay >= 0, yDisplay <= yBase else {
            throw TerminalCheckpointError.invalidStructure("buffer-display")
        }
        guard (0...Self.maximumSerializedLinesTrimmed).contains(linesTrimmed) else {
            throw TerminalCheckpointError.invalidStructure("lines-trimmed")
        }
        guard (0..<rows).contains(scrollTop),
              (0..<rows).contains(scrollBottom), scrollTop <= scrollBottom else {
            throw TerminalCheckpointError.invalidStructure("scroll-region")
        }
        guard (0..<columns).contains(marginLeft),
              (0..<columns).contains(marginRight), marginLeft <= marginRight else {
            throw TerminalCheckpointError.invalidStructure("horizontal-margins")
        }
        guard tabStops.count == columns else {
            throw TerminalCheckpointError.invalidStructure("tab-stops")
        }
        guard savedX >= 0, savedX <= columns,
              Self.deferredSavedCursorYRange.contains(savedY) else {
            throw TerminalCheckpointError.invalidStructure("saved-cursor")
        }
        try savedPen.validate()
        try semantic.validate(lineCount: lines.count)
        for line in lines {
            try line.validate(columns: columns, maximumSemanticGroup: semantic.groupCounter)
        }
    }
}

struct TerminalCheckpointLineV1: Codable, Sendable {
    var cells: [TerminalCheckpointCellV1]
    var isWrapped: Bool
    var renderMode: TerminalCheckpointRenderMode
    var bidi: TerminalCheckpointBidiV1
    var semanticMarks: [TerminalCheckpointSemanticMarkV1]
    var semanticHardContinuationGroup: UInt64?

    func validate(columns: Int, maximumSemanticGroup: UInt64) throws {
        guard cells.count == columns else {
            throw TerminalCheckpointError.invalidStructure("line-width")
        }
        try bidi.validate()
        guard semanticMarks.count <= 3,
              Set(semanticMarks.map(\.kind)).count == semanticMarks.count,
              semanticMarks.allSatisfy({ (0..<columns).contains($0.column) && $0.group <= maximumSemanticGroup }),
              semanticHardContinuationGroup.map({ $0 <= maximumSemanticGroup }) ?? true else {
            throw TerminalCheckpointError.invalidStructure("semantic-line")
        }
        for cell in cells {
            try cell.validate()
        }
        for column in cells.indices {
            switch cells[column].width {
            case 2:
                guard column + 1 < cells.count, cells[column + 1].width == 0 else {
                    throw TerminalCheckpointError.invalidStructure("wide-cell-leading")
                }
            case 0:
                guard column > 0, cells[column - 1].width == 2, cells[column].character == nil else {
                    throw TerminalCheckpointError.invalidStructure("wide-cell-continuation")
                }
            default:
                break
            }
        }
    }
}

enum TerminalCheckpointRenderMode: String, Codable, Sendable {
    case single
    case doubleWidth
    case doubledTop
    case doubledDown
}

struct TerminalCheckpointCellV1: Codable, Sendable {
    var character: String?
    var width: Int
    var attribute: TerminalCheckpointAttributeV1
    var stringPayload: String?
    var semanticContent: TerminalCheckpointSemanticContent

    func validate() throws {
        guard width == 0 || width == 1 || width == 2 else {
            throw TerminalCheckpointError.invalidStructure("cell-width")
        }
        if let character {
            guard character.count == 1, character.utf8.count <= 128 else {
                throw TerminalCheckpointError.invalidStructure("cell-character")
            }
        }
        if let stringPayload, stringPayload.utf8.count > 16 * 1024 {
            throw TerminalCheckpointError.invalidStructure("cell-payload")
        }
        try attribute.validate()
    }
}

enum TerminalCheckpointSemanticContent: String, Codable, Sendable {
    case none
    case promptInitial
    case promptRight
    case promptContinuation
    case promptSecondary
    case input
    case output
}

/// OSC 133 的 per-buffer authority。`promptStartRow` 只保存相对 checkpoint lines 的索引；
/// import 会重新绑定到新 BufferLine identity，绝不跨 candidate/live 转移对象引用。
struct TerminalCheckpointBufferSemanticV1: Codable, Sendable {
    var content: TerminalCheckpointSemanticContent
    var input: TerminalCheckpointSemanticInputV1
    var clickMode: TerminalCheckpointSemanticClickModeV1
    var usesSpecialCursorKeys: Bool
    var groupCounter: UInt64
    var activeGroupID: UInt64
    var promptStartRow: Int?

    func validate(lineCount: Int) throws {
        guard activeGroupID <= groupCounter,
              promptStartRow.map({ (0..<lineCount).contains($0) }) ?? true else {
            throw TerminalCheckpointError.invalidStructure("semantic-buffer")
        }
    }
}

enum TerminalCheckpointSemanticInputV1: String, Codable, Sendable {
    case idle
    case prompt
    case armed
    case submitted
}

enum TerminalCheckpointSemanticClickModeV1: String, Codable, Sendable {
    case none
    case clickEventsAbsolute
    case clickEventsRelative
    case cursorLine
    case cursorMultiple
    case cursorConservativeVertical
    case cursorSmartVertical
}

struct TerminalCheckpointSemanticMarkV1: Codable, Sendable {
    var kind: TerminalCheckpointSemanticMarkKindV1
    var column: Int
    var group: UInt64
}

enum TerminalCheckpointSemanticMarkKindV1: String, Codable, Sendable, Hashable {
    case initial
    case right
    case secondary
}

struct TerminalCheckpointAttributeV1: Codable, Sendable {
    var foreground: TerminalCheckpointAttributeColorV1
    var background: TerminalCheckpointAttributeColorV1
    var style: UInt8
    var underlineStyle: UInt8
    var underlineColor: TerminalCheckpointAttributeColorV1?

    func validate() throws {
        guard underlineStyle <= 5 else {
            throw TerminalCheckpointError.invalidStructure("underline-style")
        }
        try foreground.validate()
        try background.validate()
        try underlineColor?.validate()
    }
}

enum TerminalCheckpointAttributeColorV1: Codable, Sendable {
    case ansi256(UInt8)
    case trueColor(UInt8, UInt8, UInt8)
    case defaultColor
    case defaultInvertedColor

    private enum CodingKeys: String, CodingKey { case kind, first, second, third }
    private enum Kind: String, Codable { case ansi256, trueColor, defaultColor, defaultInvertedColor }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .ansi256:
            self = .ansi256(try values.decode(UInt8.self, forKey: .first))
        case .trueColor:
            self = .trueColor(
                try values.decode(UInt8.self, forKey: .first),
                try values.decode(UInt8.self, forKey: .second),
                try values.decode(UInt8.self, forKey: .third)
            )
        case .defaultColor:
            self = .defaultColor
        case .defaultInvertedColor:
            self = .defaultInvertedColor
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ansi256(let code):
            try values.encode(Kind.ansi256, forKey: .kind)
            try values.encode(code, forKey: .first)
        case .trueColor(let red, let green, let blue):
            try values.encode(Kind.trueColor, forKey: .kind)
            try values.encode(red, forKey: .first)
            try values.encode(green, forKey: .second)
            try values.encode(blue, forKey: .third)
        case .defaultColor:
            try values.encode(Kind.defaultColor, forKey: .kind)
        case .defaultInvertedColor:
            try values.encode(Kind.defaultInvertedColor, forKey: .kind)
        }
    }

    func validate() throws {}
}

struct TerminalCheckpointPenV1: Codable, Sendable {
    var attribute: TerminalCheckpointAttributeV1
    var charset: [UInt8: String]?

    func validate() throws {
        try attribute.validate()
        try Self.validateCharset(charset)
    }

    /// Charset map 会被 Terminal 的 byte fast path 直接以 `String.first` 读取。checkpoint 必须
    /// 在 commit 前证明每个 replacement 恰好是一个非空 `Character`；只限制 UTF-8 byte 数会
    /// 让空串在后续普通 output 上 trap，也会让多 Character 值静默丢尾。此 helper 是 saved pen、
    /// current pen 与四个 G0...G3 map 的单一校验 seam，新增 charset owner 时必须复用。
    static func validateCharset(_ charset: [UInt8: String]?) throws {
        guard let charset else { return }
        guard charset.count <= 256,
              charset.values.allSatisfy({ $0.count == 1 && $0.utf8.count <= 16 }) else {
            throw TerminalCheckpointError.invalidStructure("charset")
        }
    }
}

/// 会影响后续 bytes 解释、输入编码或 renderer 呈现的 Terminal-owned modes。
/// Buffer-owned saved modes 随各自 buffer 保存；这里保存跨 buffer 或 active-terminal authority。
struct TerminalCheckpointModesV1: Codable, Sendable {
    var applicationKeypad: Bool
    var applicationCursor: Bool
    var keyboardNormalFlags: Int
    var keyboardNormalStack: [Int]
    var keyboardAlternateFlags: Int
    var keyboardAlternateStack: [Int]
    var sendFocus: Bool
    var synchronizedOutput: Bool
    var cursorHidden: Bool
    var cursorBlink: Bool
    var cursorStyle: TerminalCheckpointCursorStyleV1
    var origin: Bool
    var margins: Bool
    var insert: Bool
    var wraparound: Bool
    var reverseWraparound: Bool
    var bracketedPaste: Bool
    var lineFeed: Bool
    var smoothScroll: Bool
    var send8BitControls: Bool
    var terminalConformance: TerminalCheckpointConformanceV1
    var xtermTitleSetUTF: Bool
    var xtermTitleSetHex: Bool
    var xtermTitleQueryUTF: Bool
    var xtermTitleQueryHex: Bool
    var mouseMode: TerminalCheckpointMouseModeV1
    var mouseProtocol: TerminalCheckpointMouseProtocolV1
    var mouseShiftCapture: Bool
    var activeHyperlink: TerminalCheckpointHyperlinkV1?
    var currentPen: TerminalCheckpointPenV1
    var charsets: [[UInt8: String]?]
    var activeCharset: Int
    var charsetLevel: UInt8
    var bidi: TerminalCheckpointBidiV1
    var bidiArrowKeySwap: Bool
    var allow80To132: Bool
    var savedBidiPrivateModes: [Int: Bool]

    func validate(columns: Int, activeLineCount: Int) throws {
        guard keyboardNormalFlags & ~KittyKeyboardFlags.knownMask == 0,
              keyboardAlternateFlags & ~KittyKeyboardFlags.knownMask == 0,
              keyboardNormalStack.count <= 16,
              keyboardAlternateStack.count <= 16,
              keyboardNormalStack.allSatisfy({ $0 & ~KittyKeyboardFlags.knownMask == 0 }),
              keyboardAlternateStack.allSatisfy({ $0 & ~KittyKeyboardFlags.knownMask == 0 }),
              charsets.count == 4,
              (0..<charsets.count).contains(activeCharset),
              Set(savedBidiPrivateModes.keys).isSubset(of: [1243, 2500, 2501]) else {
            throw TerminalCheckpointError.invalidStructure("modes")
        }
        try currentPen.validate()
        for charset in charsets {
            try TerminalCheckpointPenV1.validateCharset(charset)
        }
        try bidi.validate()
        try activeHyperlink?.validate(columns: columns, activeLineCount: activeLineCount)
    }
}

enum TerminalCheckpointCursorStyleV1: String, Codable, Sendable {
    case blinkBlock
    case steadyBlock
    case blinkUnderline
    case steadyUnderline
    case blinkBar
    case steadyBar
}

enum TerminalCheckpointMouseModeV1: String, Codable, Sendable {
    case off
    case x10
    case vt200
    case buttonEventTracking
    case anyEvent
}

enum TerminalCheckpointMouseProtocolV1: String, Codable, Sendable {
    case x10
    case utf8
    case sgr
    case urxvt
    case sgrPixel
}

enum TerminalCheckpointConformanceV1: String, Codable, Sendable {
    case vt100
    case vt200
    case vt300
    case vt400
    case vt500
}

/// Palette 是 renderer state，也是后续 OSC 4/10/11/12 query/reset 的 authority，不能只恢复
/// cell 内的 ANSI index。三组数组分别保留安装基线、动态 reset 基线与当前有效值。
struct TerminalCheckpointPaletteV1: Codable, Sendable {
    var strategy: TerminalCheckpointPaletteStrategyV1
    var installed: [TerminalCheckpointColorV1]
    var defaults: [TerminalCheckpointColorV1]
    var active: [TerminalCheckpointColorV1]
    var foreground: TerminalCheckpointColorV1
    var background: TerminalCheckpointColorV1
    var cursor: TerminalCheckpointColorV1?

    func validate() throws {
        guard installed.count == 16, defaults.count == 256, active.count == 256 else {
            throw TerminalCheckpointError.invalidStructure("palette")
        }
    }
}

struct TerminalCheckpointColorV1: Codable, Sendable {
    var red: UInt16
    var green: UInt16
    var blue: UInt16
}

enum TerminalCheckpointPaletteStrategyV1: String, Codable, Sendable {
    case xterm
    case base16Lab
    case base16LabHarmonious
}

struct TerminalCheckpointHyperlinkV1: Codable, Sendable {
    var column: Int
    var row: Int
    var payload: String

    func validate(columns: Int, activeLineCount: Int) throws {
        guard column >= 0, column <= columns,
              row >= 0, row < activeLineCount,
              payload.utf8.count <= 16 * 1024 else {
            throw TerminalCheckpointError.invalidStructure("active-hyperlink")
        }
    }
}

struct TerminalCheckpointBidiV1: Codable, Sendable {
    var supportMode: TerminalCheckpointBidiSupportModeV1
    var autodetectDirection: Bool
    var fallbackDirection: TerminalCheckpointBidiDirectionV1
    var boxMirroring: Bool

    func validate() throws {}
}

enum TerminalCheckpointBidiSupportModeV1: String, Codable, Sendable {
    case implicit
    case explicit
}

enum TerminalCheckpointBidiDirectionV1: String, Codable, Sendable {
    case leftToRight
    case rightToLeft
}

/// `EscapeSequenceParser` 在 feed chunk 之间保留的全部 value state。
///
/// `initialState/currentState` 决定下一 byte 的 transition；OSC/APC/parameter/collect buffers
/// 是尚未 dispatch 的前缀；`pendingUTF8` 由 Terminal reading buffer 拥有。`activeDCS` 只允许
/// 可无损重建的 DECRQSS handler，Sixel/Kitty graphics 按 schema capability 整体拒绝。
struct TerminalCheckpointParserV1: Codable, Sendable {
    var initialState: UInt8
    var currentState: UInt8
    var osc: [UInt8]
    var apc: [UInt8]
    var parameters: [Int]
    var parameterText: [UInt8]
    var collect: [UInt8]
    var parameterLimitExceeded: Bool
    var pendingUTF8: [UInt8]
    var activeDCS: TerminalCheckpointDCSV1?

    func validate() throws {
        guard ParserState(rawValue: initialState) != nil,
              let currentState = ParserState(rawValue: currentState),
              osc.count <= 64 * 1024,
              apc.count <= 64 * 1024,
              !parameters.isEmpty,
              parameters.count <= EscapeSequenceParser.maximumParameterCount,
              parameters.allSatisfy({ (0...EscapeSequenceParser.maximumParameterValue).contains($0) }),
              parameterText.count == parameters.count - 1,
              parameterText.allSatisfy({ $0 == UInt8(ascii: ";") || $0 == UInt8(ascii: ":") }),
              parameterText.count <= 512,
              collect.count <= 64,
              pendingUTF8.count <= 4 else {
            throw TerminalCheckpointError.invalidStructure("parser")
        }

        // `_pars` 在 parser reset/clear 后也必须至少保留 `[0]`；`.csiParam` 的数字 fast path
        // 会直接写最后一个元素。separator text 与 value slots 必须一一对应，且参数溢出只可能
        // 在第 24 个 slot 已占满后发生。若让损坏值进入 live parser，下一 byte 可能越界或产生
        // 一个正常 feed 永远无法构造的 transition，因此必须在 candidate 构造前整体拒绝。
        guard !parameterLimitExceeded || parameters.count == EscapeSequenceParser.maximumParameterCount else {
            throw TerminalCheckpointError.invalidStructure("parser-parameters")
        }
        guard currentState == .oscString || osc.isEmpty,
              currentState == .apcString || apc.isEmpty else {
            throw TerminalCheckpointError.invalidStructure("parser-string-state")
        }
        if let activeDCS {
            guard currentState == .dcsPassthrough else {
                throw TerminalCheckpointError.invalidStructure("dcs-state")
            }
            try activeDCS.validate()
        }
    }
}

/// Sixel 属于本 ticket 明确排除的图片扩展；目前唯一可恢复的 DCS handler 是纯文本
/// `DECRQSS`。保存 handler 已消费的 bytes，恢复后继续接收尾部并产生同一响应。
struct TerminalCheckpointDCSV1: Codable, Sendable {
    var kind: TerminalCheckpointDCSKindV1
    var data: [UInt8]

    func validate() throws {
        guard data.count <= 64 * 1024 else {
            throw TerminalCheckpointError.invalidStructure("dcs-handler")
        }
    }
}

enum TerminalCheckpointDCSKindV1: String, Codable, Sendable {
    case decrqss
}

extension TerminalCheckpointAttributeV1 {
    init(attribute: Attribute) {
        self.init(
            foreground: TerminalCheckpointAttributeColorV1(color: attribute.fg),
            background: TerminalCheckpointAttributeColorV1(color: attribute.bg),
            style: attribute.style.rawValue,
            underlineStyle: attribute.underlineStyle.rawValue,
            underlineColor: attribute.underlineColor.map(TerminalCheckpointAttributeColorV1.init(color:))
        )
    }

    var attribute: Attribute {
        Attribute(
            fg: foreground.attributeColor,
            bg: background.attributeColor,
            style: CharacterStyle(rawValue: style),
            underlineStyle: UnderlineStyle(rawValue: underlineStyle) ?? .none,
            underlineColor: underlineColor?.attributeColor
        )
    }
}

extension TerminalCheckpointAttributeColorV1 {
    init(color: Attribute.Color) {
        switch color {
        case .ansi256(let code): self = .ansi256(code)
        case .trueColor(let red, let green, let blue): self = .trueColor(red, green, blue)
        case .defaultColor: self = .defaultColor
        case .defaultInvertedColor: self = .defaultInvertedColor
        }
    }

    var attributeColor: Attribute.Color {
        switch self {
        case .ansi256(let code): return .ansi256(code: code)
        case .trueColor(let red, let green, let blue): return .trueColor(red: red, green: green, blue: blue)
        case .defaultColor: return .defaultColor
        case .defaultInvertedColor: return .defaultInvertedColor
        }
    }
}

extension TerminalCheckpointBidiV1 {
    init(state: BidiPresentationState) {
        self.init(
            supportMode: state.supportMode == .implicit ? .implicit : .explicit,
            autodetectDirection: state.autodetectDirection,
            fallbackDirection: state.fallbackDirection == .leftToRight ? .leftToRight : .rightToLeft,
            boxMirroring: state.boxMirroring
        )
    }

    var state: BidiPresentationState {
        BidiPresentationState(
            supportMode: supportMode == .implicit ? .implicit : .explicit,
            autodetectDirection: autodetectDirection,
            fallbackDirection: fallbackDirection == .leftToRight ? .leftToRight : .rightToLeft,
            boxMirroring: boxMirroring
        )
    }
}

extension TerminalCheckpointCursorStyleV1 {
    init(style: CursorStyle) {
        self = Self(rawValue: style.tagName)!
    }

    var style: CursorStyle {
        CursorStyle(tagName: rawValue)!
    }
}

extension TerminalCheckpointMouseModeV1 {
    init(mode: Terminal.MouseMode) {
        switch mode {
        case .off: self = .off
        case .x10: self = .x10
        case .vt200: self = .vt200
        case .buttonEventTracking: self = .buttonEventTracking
        case .anyEvent: self = .anyEvent
        }
    }

    var mode: Terminal.MouseMode {
        switch self {
        case .off: return .off
        case .x10: return .x10
        case .vt200: return .vt200
        case .buttonEventTracking: return .buttonEventTracking
        case .anyEvent: return .anyEvent
        }
    }
}

extension TerminalCheckpointMouseProtocolV1 {
    init(protocol value: Terminal.MouseProtocolEncoding) {
        switch value {
        case .x10: self = .x10
        case .utf8: self = .utf8
        case .sgr: self = .sgr
        case .urxvt: self = .urxvt
        case .sgrPixel: self = .sgrPixel
        }
    }

    var `protocol`: Terminal.MouseProtocolEncoding {
        switch self {
        case .x10: return .x10
        case .utf8: return .utf8
        case .sgr: return .sgr
        case .urxvt: return .urxvt
        case .sgrPixel: return .sgrPixel
        }
    }
}

extension TerminalCheckpointConformanceV1 {
    init(conformance: Terminal.TerminalConformance) {
        switch conformance {
        case .vt100: self = .vt100
        case .vt200: self = .vt200
        case .vt300: self = .vt300
        case .vt400: self = .vt400
        case .vt500: self = .vt500
        }
    }

    var conformance: Terminal.TerminalConformance {
        switch self {
        case .vt100: return .vt100
        case .vt200: return .vt200
        case .vt300: return .vt300
        case .vt400: return .vt400
        case .vt500: return .vt500
        }
    }
}

extension TerminalCheckpointColorV1 {
    init(color: Color) {
        self.init(red: color.red, green: color.green, blue: color.blue)
    }

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }
}

extension TerminalCheckpointPaletteStrategyV1 {
    init(strategy: Ansi256PaletteStrategy) {
        switch strategy {
        case .xterm: self = .xterm
        case .base16Lab: self = .base16Lab
        case .base16LabHarmonious: self = .base16LabHarmonious
        }
    }

    var strategy: Ansi256PaletteStrategy {
        switch self {
        case .xterm: return .xterm
        case .base16Lab: return .base16Lab
        case .base16LabHarmonious: return .base16LabHarmonious
        }
    }
}

extension TerminalCheckpointSemanticContent {
    init(content: SemanticContent) {
        switch content {
        case .none: self = .none
        case .prompt(.initial): self = .promptInitial
        case .prompt(.right): self = .promptRight
        case .prompt(.continuation): self = .promptContinuation
        case .prompt(.secondary): self = .promptSecondary
        case .input: self = .input
        case .output: self = .output
        }
    }

    var content: SemanticContent {
        switch self {
        case .none: return .none
        case .promptInitial: return .prompt(.initial)
        case .promptRight: return .prompt(.right)
        case .promptContinuation: return .prompt(.continuation)
        case .promptSecondary: return .prompt(.secondary)
        case .input: return .input
        case .output: return .output
        }
    }
}

extension TerminalCheckpointSemanticInputV1 {
    init(input: SemanticInputState) {
        switch input {
        case .idle: self = .idle
        case .prompt: self = .prompt
        case .armed: self = .armed
        case .submitted: self = .submitted
        }
    }

    var input: SemanticInputState {
        switch self {
        case .idle: return .idle
        case .prompt: return .prompt
        case .armed: return .armed
        case .submitted: return .submitted
        }
    }
}

extension TerminalCheckpointSemanticClickModeV1 {
    init(mode: SemanticPromptClickMode) {
        switch mode {
        case .none: self = .none
        case .clickEventsAbsolute: self = .clickEventsAbsolute
        case .clickEventsRelative: self = .clickEventsRelative
        case .cursorKeys(.line): self = .cursorLine
        case .cursorKeys(.multiple): self = .cursorMultiple
        case .cursorKeys(.conservativeVertical): self = .cursorConservativeVertical
        case .cursorKeys(.smartVertical): self = .cursorSmartVertical
        }
    }

    var mode: SemanticPromptClickMode {
        switch self {
        case .none: return .none
        case .clickEventsAbsolute: return .clickEventsAbsolute
        case .clickEventsRelative: return .clickEventsRelative
        case .cursorLine: return .cursorKeys(.line)
        case .cursorMultiple: return .cursorKeys(.multiple)
        case .cursorConservativeVertical: return .cursorKeys(.conservativeVertical)
        case .cursorSmartVertical: return .cursorKeys(.smartVertical)
        }
    }
}

extension TerminalCheckpointSemanticMarkKindV1 {
    init(kind: SemanticPromptKind) {
        switch kind {
        case .initial: self = .initial
        case .right: self = .right
        case .secondary: self = .secondary
        case .continuation:
            preconditionFailure("continuation 是派生 row kind，不能持久化为 semantic mark")
        }
    }

    var kind: SemanticPromptKind {
        switch self {
        case .initial: return .initial
        case .right: return .right
        case .secondary: return .secondary
        }
    }
}

extension TerminalCheckpointRenderMode {
    init(mode: BufferLine.RenderLineMode) {
        switch mode {
        case .single: self = .single
        case .doubleWidth: self = .doubleWidth
        case .doubledTop: self = .doubledTop
        case .doubledDown: self = .doubledDown
        }
    }

    var mode: BufferLine.RenderLineMode {
        switch self {
        case .single: return .single
        case .doubleWidth: return .doubleWidth
        case .doubledTop: return .doubledTop
        case .doubledDown: return .doubledDown
        }
    }
}
