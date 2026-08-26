import Foundation
import Testing
@testable import SwiftTerm

@Suite("Terminal checkpoint")
final class TerminalCheckpointTests {
    private let esc = "\u{1b}"

    /// Candidate construction may run on a worker, but only the exact live Terminal that issued
    /// the opaque context may consume the prepared state. Preparation never mutates live state,
    /// and the successful commit is a single-use transfer.
    @Test func preparedMaterializationCommitsOnceToItsExactTerminal() async throws {
        let (source, _) = TerminalTestHarness.makeTerminal(cols: 24, rows: 6, scrollback: 32)
        source.feed(text: "prepared checkpoint 🙂\r\nsecond line")
        let checkpoint = try source.exportCheckpoint()

        let (live, _) = TerminalTestHarness.makeTerminal(cols: 12, rows: 3, scrollback: 4)
        live.feed(text: "live state must survive preparation")
        let beforePreparation = try live.exportCheckpoint().encodedBytes()
        let context = live.checkpointMaterializationContext()

        let prepared = try await Task.detached {
            try Terminal.prepareCheckpointMaterialization(checkpoint, context: context)
        }.value
        #expect(try live.exportCheckpoint().encodedBytes() == beforePreparation)

        let (sibling, _) = TerminalTestHarness.makeTerminal(cols: 12, rows: 3, scrollback: 4)
        #expect(throws: TerminalCheckpointError.materializationOwnerMismatch) {
            try sibling.commitCheckpointMaterialization(prepared)
        }
        try live.commitCheckpointMaterialization(prepared)
        assertEquivalentBehavior(source, live)
        #expect(throws: TerminalCheckpointError.materializationAlreadyConsumed) {
            try live.commitCheckpointMaterialization(prepared)
        }
    }

    /// 固定反例覆盖 UTF-8、OSC、DCS 与重复 unit 边界；其后 500 个确定性随机切点
    /// 覆盖 parser/mode/cell 组合。探针不读取 checkpoint schema，只比较 engine 行为。
    @Test func fixedAndRandomByteCutsResumeEquivalentBehavior() throws {
        let unit = checkpointCorpusUnit()
        let unitBytes = Array(unit.utf8)
        let bytes = Array(String(repeating: unit, count: 12).utf8)
        let encoded = Data(bytes)
        let dcsStart = encoded.range(of: Data("\(esc)P$qm".utf8))!.lowerBound
        let oscStart = encoded.range(of: Data("\(esc)]8;;".utf8))!.lowerBound
        let emojiStart = encoded.range(of: Data("🙂".utf8))!.lowerBound
        var cuts = [
            0,
            1,
            dcsStart + 2,
            dcsStart + 4,
            oscStart + 3,
            emojiStart + 2,
            unitBytes.count - 1,
            unitBytes.count,
            bytes.count,
        ]
        var randomState: UInt64 = 0xA1_C1_0125
        for _ in 0..<500 {
            randomState = randomState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            cuts.append(Int(randomState % UInt64(bytes.count + 1)))
        }

        for cut in cuts {
            let (source, sourceDelegate) = TerminalTestHarness.makeTerminal(cols: 40, rows: 12, scrollback: 64)
            source.feed(buffer: bytes[..<cut])
            let checkpoint = try source.exportCheckpoint()

            let (restored, restoredDelegate) = TerminalTestHarness.makeTerminal(cols: 8, rows: 3, scrollback: 1)
            restored.feed(text: "must-disappear")
            try restored.importCheckpoint(checkpoint)
            assertEquivalentBehavior(source, restored)

            sourceDelegate.clearSentData()
            restoredDelegate.clearSentData()
            source.feed(buffer: bytes[cut...])
            restored.feed(buffer: bytes[cut...])
            assertEquivalentBehavior(source, restored)
            #expect(sourceDelegate.sentData == restoredDelegate.sentData)
        }
    }

    /// cancellation 可以发生在 candidate 构造期间；无论在哪个 gate 命中，live terminal
    /// 都必须保持逐字节可再次导出的原状态。损坏 envelope 也必须在 import 前被拒绝。
    @Test func cancellationAndMalformedEnvelopePreserveLiveTerminal() throws {
        let bytes = Array(String(repeating: checkpointCorpusUnit(), count: 12).utf8)
        let (source, _) = TerminalTestHarness.makeTerminal(cols: 40, rows: 12, scrollback: 64)
        source.feed(buffer: bytes[...])
        let checkpoint = try source.exportCheckpoint()
        #expect(throws: TerminalCheckpointError.cancelled) {
            try source.exportCheckpoint { true }
        }

        let (live, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 4, scrollback: 4)
        live.feed(text: "live-state-must-survive")
        let beforeCancellation = try live.exportCheckpoint().encodedBytes()
        var cancellationChecks = 0
        #expect(throws: TerminalCheckpointError.cancelled) {
            try live.importCheckpoint(checkpoint) {
                cancellationChecks += 1
                return cancellationChecks >= 3
            }
        }
        #expect(try live.exportCheckpoint().encodedBytes() == beforeCancellation)

        let corrupted = Data(checkpoint.encodedBytes().dropLast())
        #expect(throws: TerminalCheckpointError.malformedEncoding) {
            try TerminalCheckpoint(encodedBytes: corrupted)
        }
    }

    /// normal history 的产品上限独立于调用者配置；超出部分从最旧逻辑行开始裁剪，
    /// alternate buffer 不携带 scrollback。
    @Test func normalScrollbackIsBoundedAndAlternateHasNoHistory() throws {
        let (source, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 4, scrollback: 4_000)
        for line in 0..<2_100 {
            source.feed(text: "line-\(line)\r\n")
        }
        let hyperlink = "https://www.aircli.app/checkpoint"
        source.feed(text: "\(esc)]8;;\(hyperlink)\u{7}linked-tail")
        let checkpoint = try source.exportCheckpoint()
        let (restored, _) = TerminalTestHarness.makeTerminal(cols: 2, rows: 1, scrollback: 0)
        try restored.importCheckpoint(checkpoint)

        #expect(restored.normalBuffer.lines.count <= 4 + TerminalCheckpoint.maximumNormalScrollbackLines)
        #expect(restored.normalBuffer.scrollback == TerminalCheckpoint.maximumNormalScrollbackLines)
        #expect(restored.altBuffer.lines.count == 4)

        // OSC 8 tracking 的 row 来自裁剪前 live Buffer；checkpoint 必须把它平移到被 2 MiB
        // byte cap 保留的 history 后缀。关闭 sequence 后 payload 应落到相同的保留行，而非因
        // stale absolute row 越界、拒绝合法 export，或静默标记另一行。
        let tracking = try #require(restored.hyperLinkTracking)
        let trackedStart = tracking.start
        #expect(trackedStart.row == restored.buffer.yBase + restored.buffer.y)
        restored.feed(text: "\(esc)]8;;\u{7}")
        #expect(
            restored.buffer.lines[trackedStart.row][trackedStart.col].getPayload() as? String
                == tracking.payload
        )

        let (empty, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 4, scrollback: 64)
        let emptyCheckpoint = try empty.exportCheckpoint()
        try restored.importCheckpoint(emptyCheckpoint)
        #expect(restored.normalBuffer.scrollback == 64)
    }

    @Test func schemaVersionSizeAndWideCellStructureAreStrictlyValidated() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 8, rows: 3, scrollback: 4)
        terminal.feed(text: "界")
        let checkpoint = try terminal.exportCheckpoint()
        var json = try #require(
            JSONSerialization.jsonObject(with: checkpoint.encodedBytes()) as? [String: Any]
        )

        var future = json
        future["version"] = 2
        let futureBytes = try JSONSerialization.data(withJSONObject: future)
        #expect(throws: TerminalCheckpointError.unsupportedSchemaVersion(2)) {
            try TerminalCheckpoint(encodedBytes: futureBytes)
        }

        var normal = try #require(json["normal"] as? [String: Any])
        var lines = try #require(normal["lines"] as? [[String: Any]])
        var firstLine = lines[0]
        var cells = try #require(firstLine["cells"] as? [[String: Any]])
        cells[1]["width"] = 1
        firstLine["cells"] = cells
        lines[0] = firstLine
        normal["lines"] = lines
        json["normal"] = normal
        let invalidWideCell = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: TerminalCheckpointError.invalidStructure("wide-cell-leading")) {
            try TerminalCheckpoint(encodedBytes: invalidWideCell)
        }

        // `.csiParam` 的数字 fast path 会直接写 `parameters.last`；空数组虽可被 Codable
        // 解出，却不是 live parser 可产生的状态，必须在 import 之前拒绝。
        var invalidParser = try #require(
            JSONSerialization.jsonObject(with: checkpoint.encodedBytes()) as? [String: Any]
        )
        var parser = try #require(invalidParser["parser"] as? [String: Any])
        parser["currentState"] = ParserState.csiParam.rawValue
        parser["parameters"] = []
        parser["parameterText"] = []
        invalidParser["parser"] = parser
        let invalidParserBytes = try JSONSerialization.data(withJSONObject: invalidParser)
        #expect(throws: TerminalCheckpointError.invalidStructure("parser")) {
            try TerminalCheckpoint(encodedBytes: invalidParserBytes)
        }

        // parser.initialState 的 production authority 永远是 ground；pendingUTF8 又只能是尚未
        // 收齐的 2...4-byte scalar 前缀。若接受其他 enum 或 ASCII putback，下一次 feed 会执行
        // live parser 永远无法产生的 reset／字节注入。
        var mutatedInitialState = checkpoint.storage
        mutatedInitialState.parser.initialState = ParserState.escape.rawValue
        #expect(throws: TerminalCheckpointError.invalidStructure("parser")) {
            try TerminalCheckpoint(encodedBytes: JSONEncoder().encode(mutatedInitialState))
        }
        for pendingUTF8 in [[UInt8(ascii: "A")], [0xC2, 0xA0]] {
            var invalidPendingUTF8 = checkpoint.storage
            invalidPendingUTF8.parser.pendingUTF8 = pendingUTF8
            #expect(throws: TerminalCheckpointError.invalidStructure("parser")) {
                try TerminalCheckpoint(encodedBytes: JSONEncoder().encode(invalidPendingUTF8))
            }
        }

        // 结构校验本身也必须对任意解码 Int 是 total 的；不得在准备拒绝损坏 payload 时
        // 先因 `yBase + rows` 溢出。`linesTrimmed` 又会被正常 scroll 递增，不能让 Int.max
        // commit 后把下一次 output 变成 trap。
        var overflowingBase = checkpoint.storage
        overflowingBase.normal.yBase = Int.max
        #expect(throws: TerminalCheckpointError.invalidStructure("buffer-base")) {
            try TerminalCheckpoint(encodedBytes: JSONEncoder().encode(overflowingBase))
        }
        var exhaustedLineCounter = checkpoint.storage
        exhaustedLineCounter.normal.linesTrimmed = Int.max
        #expect(throws: TerminalCheckpointError.invalidStructure("lines-trimmed")) {
            try TerminalCheckpoint(encodedBytes: JSONEncoder().encode(exhaustedLineCounter))
        }

        // Charset replacement 是后续 byte feed 的直接 engine state。active pen 空串会让
        // `String.first` trap；G0...G3 的多 Character 值则会静默丢尾。saved/current/registered
        // maps 必须复用 exact-one-Character validation，不能只验证当前 active map。
        var emptyActiveCharset = checkpoint.storage
        emptyActiveCharset.modes.currentPen.charset = [UInt8(ascii: "A"): ""]
        #expect(throws: TerminalCheckpointError.invalidStructure("charset")) {
            try TerminalCheckpoint(encodedBytes: JSONEncoder().encode(emptyActiveCharset))
        }
        var multipleCharacterCharset = checkpoint.storage
        multipleCharacterCharset.modes.charsets[0] = [UInt8(ascii: "A"): "AB"]
        #expect(throws: TerminalCheckpointError.invalidStructure("charset")) {
            try TerminalCheckpoint(encodedBytes: JSONEncoder().encode(multipleCharacterCharset))
        }
        // gLevel 只由 locking-shift commands 设为 0...3。越界值会让后续 setgCharset 不再
        // 更新 active charset，造成恢复后才出现的 renderer divergence。
        var invalidCharsetLevel = checkpoint.storage
        invalidCharsetLevel.modes.charsetLevel = .max
        #expect(throws: TerminalCheckpointError.invalidStructure("modes")) {
            try TerminalCheckpoint(encodedBytes: JSONEncoder().encode(invalidCharsetLevel))
        }

        let oversized = Data(repeating: 0, count: TerminalCheckpoint.maximumEncodedBytes + 1)
        #expect(throws: TerminalCheckpointError.encodedLengthExceeded(
            actual: oversized.count,
            maximum: TerminalCheckpoint.maximumEncodedBytes
        )) {
            try TerminalCheckpoint(encodedBytes: oversized)
        }

        // savedY 是 resize/reflow 后延迟到 DECRC 才 clamp 的 engine state，不能套用 viewport
        // invariant；但 checkpoint 是不可信输入，V1 只接受固定 Int32 domain。Int 极值必须在
        // candidate/live Buffer 建立前拒绝，否则 normal/alternate 的内部 reflow 算术都可能 trap。
        for bufferKey in ["normal", "alternate"] {
            for savedY in [Int.min, Int.max] {
                var invalidSavedCursor = try #require(
                    JSONSerialization.jsonObject(with: checkpoint.encodedBytes())
                        as? [String: Any]
                )
                var buffer = try #require(invalidSavedCursor[bufferKey] as? [String: Any])
                buffer["savedY"] = savedY
                invalidSavedCursor[bufferKey] = buffer
                let bytes = try JSONSerialization.data(withJSONObject: invalidSavedCursor)
                #expect(throws: TerminalCheckpointError.invalidStructure("saved-cursor")) {
                    try TerminalCheckpoint(encodedBytes: bytes)
                }
            }
        }

        // 使用带 history 且 current y > 0 的 normal buffer，再激活 alternate；随后同时恢复两个
        // buffer 的 Int32 endpoint 并改变 columns/rows。这样 normal 会实际经过 reflow，active
        // alternate 会执行 DECRC，证明 serialized bound 既保留 deferred state 又不引入溢出。
        let (extremeSource, _) = TerminalTestHarness.makeTerminal(
            cols: 8, rows: 3, scrollback: 8)
        for line in 0..<6 {
            extremeSource.feed(text: "line-\(line)\r\n")
        }
        #expect(extremeSource.normalBuffer.y > 0)
        #expect(extremeSource.normalBuffer.yBase > 0)
        extremeSource.feed(text: "\(esc)[?1049h\(esc)[3;1H")
        let extremeBase = try extremeSource.exportCheckpoint()

        for (savedY, expectedY) in [(Int(Int32.min), 0), (Int(Int32.max), 3)] {
            var extreme = try #require(
                JSONSerialization.jsonObject(with: extremeBase.encodedBytes()) as? [String: Any]
            )
            for bufferKey in ["normal", "alternate"] {
                var buffer = try #require(extreme[bufferKey] as? [String: Any])
                buffer["savedY"] = savedY
                extreme[bufferKey] = buffer
            }
            let bytes = try JSONSerialization.data(withJSONObject: extreme)
            let extremeCheckpoint = try TerminalCheckpoint(encodedBytes: bytes)
            let (extremeTerminal, _) = TerminalTestHarness.makeTerminal(
                cols: 2, rows: 1, scrollback: 0)
            try extremeTerminal.importCheckpoint(extremeCheckpoint)
            extremeTerminal.resize(cols: 5, rows: 4)
            extremeTerminal.feed(text: "\(esc)8")
            #expect(extremeTerminal.buffer.y == expectedY)
        }
    }

    /// resize 是 owner 串行队列上的离散事件；checkpoint 不捕获“半次 resize”，但必须完整
    /// 保存最近一次已提交 grid/reflow 结果，#57 才能把它与同一 output offset 绑定。
    @Test func checkpointAfterConsecutiveResizesPreservesReflowedGrid() throws {
        let (source, sourceDelegate) = TerminalTestHarness.makeTerminal(cols: 18, rows: 5, scrollback: 32)
        source.feed(text: "one two three four five six seven eight nine\r\n中🙂e\u{301}")
        source.resize(cols: 11, rows: 7)
        source.resize(cols: 26, rows: 4)
        source.resize(cols: 14, rows: 6)
        source.feed(text: "\(esc)[6;1H\(esc)7\(esc)[4;1H")
        source.resize(cols: 14, rows: 4)
        #expect(source.normalBuffer.savedY >= source.rows)

        let checkpoint = try source.exportCheckpoint()
        let (restored, restoredDelegate) = TerminalTestHarness.makeTerminal(cols: 3, rows: 2, scrollback: 0)
        try restored.importCheckpoint(checkpoint)
        assertEquivalentBehavior(source, restored)

        sourceDelegate.clearSentData()
        restoredDelegate.clearSentData()
        let suffix = Array("\(esc)8\r\nafter-resize\t界".utf8)
        source.feed(buffer: suffix[...])
        restored.feed(buffer: suffix[...])
        assertEquivalentBehavior(source, restored)
        #expect(sourceDelegate.sentData == restoredDelegate.sentData)

        // `savedY` 在缩小 viewport 后可以合法地落在可见行之外；checkpoint 必须保存 deferred
        // 坐标，而不是在 export/import 时提前 clamp。重新放大后再执行 DECRC，才能把“原样保留”
        // 与错误地钳制到旧 viewport 底行区分开。normal/alternate 共用同一 schema 合同，二者都要
        // 经历这个行为验证，避免只修 production 常见的 normal buffer。
        for usesAlternateBuffer in [false, true] {
            let (deferredSource, _) = TerminalTestHarness.makeTerminal(
                cols: 10, rows: 6, scrollback: 0)
            if usesAlternateBuffer {
                deferredSource.feed(text: "\(esc)[?1049h")
            }
            deferredSource.feed(text: "\(esc)[6;1H\(esc)7\(esc)[4;1H")
            deferredSource.resize(cols: 10, rows: 4)
            #expect(deferredSource.buffer.savedY == 5)

            let deferredCheckpoint = try deferredSource.exportCheckpoint()
            let (deferredRestored, _) = TerminalTestHarness.makeTerminal(
                cols: 2, rows: 1, scrollback: 0)
            try deferredRestored.importCheckpoint(deferredCheckpoint)
            #expect(deferredRestored.buffer.savedY == 5)

            deferredSource.resize(cols: 10, rows: 6)
            deferredRestored.resize(cols: 10, rows: 6)
            deferredSource.feed(text: "\(esc)8")
            deferredRestored.feed(text: "\(esc)8")
            #expect(deferredSource.buffer.y == 5)
            #expect(deferredRestored.buffer.y == 5)
            assertEquivalentBehavior(deferredSource, deferredRestored)
        }
    }

    private func checkpointCorpusUnit() -> String {
        [
            "\(esc)[2J\(esc)[H",
            "plain\t\(esc)[31;44;1mred-blue\(esc)[0m 中🙂e\u{301}\r\n",
            "\(esc)[2;9r\(esc)[?69h\(esc)[3;35s\(esc)[5;7Hmargin\(esc)7saved\(esc)8",
            "\(esc)[?25l\(esc)[?1006h\(esc)[?1002h\(esc)[?2004h\(esc)[?1002$p\(esc)[?1006$p",
            "\(esc)[?40h\(esc)[?2500h\(esc)[?2500;2501;1243s\(esc)[?2500l\(esc)[?40$p",
            "\(esc)[?1049halt-screen\r\n\(esc)[4 q\(esc)[?1h\(esc)[?1049l",
            "\(esc)]133;A;cl=m;special_key=1\u{7}>\(esc)]133;B\u{7}cmd\r\nnext",
            "\(esc)]4;1;#123456\u{7}\(esc)]10;#abcdef\u{7}\(esc)]11;#101010\u{7}\(esc)]12;#fedcba\u{7}",
            "\(esc)]8;;https://www.aircli.app\u{7}AirCLI\(esc)]8;;\u{7}\r\n",
            "\(esc)P$qm\(esc)\\",
            "\(esc)[?1002l\(esc)[?25h\(esc)[?69l\(esc)[r\(esc)[?2004l",
        ].joined()
    }

    private func assertEquivalentBehavior(_ lhs: Terminal, _ rhs: Terminal) {
        #expect(lhs.getDims().cols == rhs.getDims().cols)
        #expect(lhs.getDims().rows == rhs.getDims().rows)
        #expect(lhs.isCurrentBufferAlternate == rhs.isCurrentBufferAlternate)
        #expect(lhs.applicationCursor == rhs.applicationCursor)
        #expect(lhs.bracketedPasteMode == rhs.bracketedPasteMode)
        #expect(mouseModeName(lhs.mouseMode) == mouseModeName(rhs.mouseMode))
        #expect(lhs.keyboardEnhancementFlags.rawValue == rhs.keyboardEnhancementFlags.rawValue)
        #expect(colorSignature(lhs.installedColors) == colorSignature(rhs.installedColors))
        #expect(colorSignature(lhs.defaultAnsiColors) == colorSignature(rhs.defaultAnsiColors))
        #expect(colorSignature(lhs.ansiColors) == colorSignature(rhs.ansiColors))
        #expect(lhs.foregroundColor == rhs.foregroundColor)
        #expect(lhs.backgroundColor == rhs.backgroundColor)
        #expect(lhs.cursorColor == rhs.cursorColor)
        assertEquivalentBuffer(lhs.normalBuffer, rhs.normalBuffer, lhs, rhs)
        assertEquivalentBuffer(lhs.altBuffer, rhs.altBuffer, lhs, rhs)
    }

    /// 用稳定的数值摘要比较 palette，避免 Testing 在失败时打印 256 个无字段信息的
    /// `Color` 对象；差异会直接落到具体 index 与 RGB16 值。
    private func colorSignature(_ colors: [Color]) -> [String] {
        colors.enumerated().map { index, color in
            "\(index):\(color.red),\(color.green),\(color.blue)"
        }
    }

    private func assertEquivalentBuffer(
        _ lhs: Buffer,
        _ rhs: Buffer,
        _ lhsTerminal: Terminal,
        _ rhsTerminal: Terminal
    ) {
        if lhs.lines.count != rhs.lines.count {
            let longer = lhs.lines.count > rhs.lines.count ? lhs : rhs
            let shorterCount = min(lhs.lines.count, rhs.lines.count)
            for row in shorterCount..<longer.lines.count {
                #expect(!longer.lines[row].hasAnyContent())
                #expect(!longer.lines[row].isWrapped)
            }
        }
        #expect(lhs.x == rhs.x)
        #expect(lhs.y == rhs.y)
        #expect(lhs.yBase == rhs.yBase)
        #expect(lhs.yDisp == rhs.yDisp)
        #expect(lhs.scrollTop == rhs.scrollTop)
        #expect(lhs.scrollBottom == rhs.scrollBottom)
        #expect(lhs.marginLeft == rhs.marginLeft)
        #expect(lhs.marginRight == rhs.marginRight)
        #expect(Array(lhs.tabStops.prefix(lhs.cols)) == Array(rhs.tabStops.prefix(rhs.cols)))
        #expect(lhs.savedX == rhs.savedX)
        #expect(lhs.savedY == rhs.savedY)
        #expect(lhs.savedAttr == rhs.savedAttr)
        #expect(lhs.savedCharset == rhs.savedCharset)
        #expect(lhs.savedOriginMode == rhs.savedOriginMode)
        #expect(lhs.savedMarginMode == rhs.savedMarginMode)
        #expect(lhs.savedWraparound == rhs.savedWraparound)
        #expect(lhs.savedReverseWraparound == rhs.savedReverseWraparound)
        #expect(lhs.semanticContent == rhs.semanticContent)
        #expect(lhs.semanticInput == rhs.semanticInput)
        #expect(lhs.semanticClickMode == rhs.semanticClickMode)
        #expect(lhs.semanticUsesSpecialCursorKeys == rhs.semanticUsesSpecialCursorKeys)
        #expect(lhs.activeSemanticPromptOrigin == rhs.activeSemanticPromptOrigin)
        #expect(lhs.semanticPromptInvariantsHold())
        #expect(rhs.semanticPromptInvariantsHold())
        for row in 0..<min(lhs.lines.count, rhs.lines.count) {
            let lhsLine = lhs.lines[row]
            let rhsLine = rhs.lines[row]
            #expect(lhsLine.isWrapped == rhsLine.isWrapped)
            #expect(lhsLine.semanticMarks == rhsLine.semanticMarks)
            #expect(lhsLine.semanticHardContinuationGroup == rhsLine.semanticHardContinuationGroup)
            for column in 0..<min(lhsLine.count, rhsLine.count) {
                let lhsCell = lhsLine[column]
                let rhsCell = rhsLine[column]
                #expect(lhsCell.width == rhsCell.width)
                #expect(lhsCell.attribute == rhsCell.attribute)
                #expect(lhsCell.semanticContent == rhsCell.semanticContent)
                #expect(lhsTerminal.getCharacter(for: lhsCell) == rhsTerminal.getCharacter(for: rhsCell))
                #expect((lhsCell.getPayload() as? String) == (rhsCell.getPayload() as? String))
            }
        }
    }

    private func mouseModeName(_ mode: Terminal.MouseMode) -> String {
        switch mode {
        case .off: return "off"
        case .x10: return "x10"
        case .vt200: return "vt200"
        case .buttonEventTracking: return "buttonEventTracking"
        case .anyEvent: return "anyEvent"
        }
    }
}
