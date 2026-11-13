import Foundation
import IMMLedger
import IMMSyncCore

/// Turns ledger ops into sealed batches: the ops of one device with consecutive sequence numbers, JSON-encoded as `[SyncOp]`,
/// sealed under the group key with the header `{format, group, device, seqFrom, seqTo}` as AAD. A batch never exceeds
/// `SealedEnvelope.maxEncodedSize` (1 MiB).
public struct BatchPublisher: Sendable {
    public let ledger: LedgerStore
    /// Ops fetched from the log per read.
    let pageSize: Int
    /// Payload budget per envelope (tests lower it to force splitting).
    let payloadBudget: Int

    public init(ledger: LedgerStore, pageSize: Int = 500, payloadBudget: Int = SealedEnvelope.maxPayloadSize) {
        self.ledger = ledger
        self.pageSize = pageSize
        self.payloadBudget = min(payloadBudget, SealedEnvelope.maxPayloadSize)
    }

    /// Sealed batches for everything a peer lacks.
    /// - Parameters:
    ///   - known: highest sequence of a device the peer already holds (0 when unknown).
    ///   - peer: the peer's own node id; its ops are never sent back.
    ///   - device: send only this device's ops (a joined device sends its own; the hub relays everything).
    /// A device's ops are sent only up to this ledger's contiguous cursor for it, so a batch never has holes: the receiver may
    /// acknowledge `seqTo` and mean it.
    public func envelopes(
        group: SyncGroup, known: (DeviceNodeID) -> Int64, excluding peer: DeviceNodeID?, only device: DeviceNodeID? = nil
    ) throws -> [SealedEnvelope] {
        var result: [SealedEnvelope] = []
        for cursor in try ledger.writer.cursors() where cursor.device != peer && (device == nil || cursor.device == device) {
            var after = max(0, known(cursor.device))
            while after < cursor.appliedSeq {
                let ops = try ledger.writer.ops(from: cursor.device, after: after, limit: pageSize).filter { $0.seq <= cursor.appliedSeq }
                guard let last = ops.last else { break }
                result += try seal(ops, group: group, device: cursor.device)
                after = last.seq
            }
        }
        return result
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// Seals `ops` (one device, ascending) into as many envelopes as the size budget needs.
    func seal(_ ops: [SyncOp], group: SyncGroup, device: DeviceNodeID) throws -> [SealedEnvelope] {
        var envelopes: [SealedEnvelope] = []
        var encoded: [Data] = []
        var size = 2
        var from = ops.first?.seq ?? 0
        var lastSeq = from

        func flush() throws {
            guard !encoded.isEmpty else { return }
            var payload = Data("[".utf8)
            for (index, op) in encoded.enumerated() {
                if index > 0 { payload.append(UInt8(ascii: ",")) }
                payload.append(op)
            }
            payload.append(UInt8(ascii: "]"))
            let header = SealedEnvelope.Header(group: group.id, device: device, seqFrom: from, seqTo: lastSeq)
            envelopes.append(try SealedEnvelope.seal(payload: payload, header: header, key: group.key))
            encoded.removeAll(keepingCapacity: true)
            size = 2
        }

        for op in ops {
            let data = try Self.encoder.encode(op)
            if size + data.count + 1 > payloadBudget {
                try flush()
                from = op.seq
            }
            guard data.count + 2 <= payloadBudget else { throw SealedEnvelopeError.tooLarge(data.count) }
            encoded.append(data)
            size += data.count + 1
            lastSeq = op.seq
        }
        try flush()
        return envelopes
    }
}

public enum BatchApplyOutcome: Error, Sendable, Equatable {
    /// New ops stored and applied; `cursor` is the contiguous prefix now.
    case applied(device: DeviceNodeID, cursor: Int64, result: ApplyResult)
    /// Everything in the batch was already applied (a replay).
    case duplicate(device: DeviceNodeID, cursor: Int64)
    /// The batch starts after the cursor: an earlier batch is missing. The ops were applied anyway (they commute) but the
    /// cursor did not move; the caller re-requests the range with `hello`.
    case gap(device: DeviceNodeID, cursor: Int64, batchFrom: Int64, result: ApplyResult)
    /// A group key rotation notice.
    case rekey(group: Data, key: Data)
    /// Sealed for another group (before or after a rotation).
    case staleGroup(Data)
    /// Authentication failed or the content contradicts its header.
    case rejected(String)
}

/// Opens sealed batches, checks sequence continuity per sender and hands the ops to `LedgerWriter.applyRemote`.
public struct BatchApplier: Sendable {
    public let ledger: LedgerStore

    public init(ledger: LedgerStore) {
        self.ledger = ledger
    }

    /// The ops of a verified batch (nil for a rekey envelope), or the reason the envelope is not applicable.
    func open(_ envelope: SealedEnvelope, group: SyncGroup) -> Result<(ops: [SyncOp], rekey: PairingWire?), BatchApplyOutcome> {
        let header = envelope.header
        guard header.group == group.id else { return .failure(.staleGroup(header.group)) }
        let payload: Data
        do { payload = try envelope.open(key: group.key) } catch { return .failure(.rejected("batch does not authenticate: \(error)")) }
        if payload.first == UInt8(ascii: "{") {
            guard let wire = try? PairingWire(decoding: payload), case .rekey = wire else { return .failure(.rejected("unknown control payload")) }
            return .success(([], wire))
        }
        guard let ops = try? JSONDecoder().decode([SyncOp].self, from: payload) else { return .failure(.rejected("batch is not a list of ops")) }
        guard !ops.isEmpty, ops.allSatisfy({ $0.device == header.device && $0.seq >= header.seqFrom && $0.seq <= header.seqTo && $0.seq >= 1 }) else {
            return .failure(.rejected("ops do not match the batch header"))
        }
        return .success((ops, nil))
    }

    public func apply(_ envelope: SealedEnvelope, group: SyncGroup) throws -> (outcome: BatchApplyOutcome, ops: [SyncOp]) {
        switch open(envelope, group: group) {
        case .failure(let outcome):
            return (outcome, [])
        case .success(let opened):
            if case .rekey(let newGroup, let key)? = opened.rekey { return (.rekey(group: newGroup, key: key), []) }
            let header = envelope.header
            let before = try cursor(of: header.device)
            if header.seqTo <= before { return (.duplicate(device: header.device, cursor: before), []) }
            let result = try ledger.writer.applyRemote(opened.ops)
            let after = try cursor(of: header.device)
            if header.seqFrom > before + 1 {
                return (.gap(device: header.device, cursor: after, batchFrom: header.seqFrom, result: result), opened.ops)
            }
            return (.applied(device: header.device, cursor: after, result: result), opened.ops)
        }
    }

    func cursor(of device: DeviceNodeID) throws -> Int64 {
        try ledger.writer.cursors().first { $0.device == device }?.appliedSeq ?? 0
    }
}
