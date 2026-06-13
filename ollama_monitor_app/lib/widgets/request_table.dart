import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/monitor_state.dart';

class RequestTable extends StatelessWidget {
  final List<RequestRecord> requests;

  const RequestTable({super.key, required this.requests});

  @override
  Widget build(BuildContext context) {
    final rows = requests.reversed.take(100).toList();

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Card header ────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Row(
              children: [
                const Icon(Icons.swap_horiz, color: Colors.blueAccent, size: 18),
                const SizedBox(width: 8),
                Text('Recent Requests',
                    style: Theme.of(context)
                        .textTheme
                        .labelLarge
                        ?.copyWith(color: Colors.white70)),
                const Spacer(),
                if (rows.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.white10,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text('${rows.length}',
                        style: const TextStyle(fontSize: 11, color: Colors.white54)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // ── Column headers ──────────────────────────────────────────────
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                SizedBox(width: 16), // status dot column
                SizedBox(
                  width: 72,
                  child: Text('TIME', style: _kHeaderStyle),
                ),
                Expanded(
                  flex: 3,
                  child: Text('MODEL', style: _kHeaderStyle),
                ),
                SizedBox(
                  width: 82,
                  child: Text('DURATION', style: _kHeaderStyle, textAlign: TextAlign.right),
                ),
                SizedBox(
                  width: 110,
                  child: Text('TOKENS', style: _kHeaderStyle, textAlign: TextAlign.right),
                ),
                SizedBox(
                  width: 68,
                  child: Text('TG/s', style: _kHeaderStyle, textAlign: TextAlign.right),
                ),
                SizedBox(
                  width: 48,
                  child: Text('STATUS', style: _kHeaderStyle, textAlign: TextAlign.right),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          const Divider(height: 1, color: Colors.white12),

          // ── Rows ────────────────────────────────────────────────────────
          SizedBox(
            height: rows.isEmpty ? 90 : 320,
            child: rows.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        'Requests are detected automatically from the Ollama server log.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (ctx, i) =>
                        _RequestRow(record: rows[i], isEven: i.isEven),
                  ),
          ),
        ],
      ),
    );
  }
}

const _kHeaderStyle = TextStyle(
  color: Colors.white38,
  fontSize: 10,
  fontWeight: FontWeight.w700,
  letterSpacing: 0.8,
);

// ── Single row ──────────────────────────────────────────────────────────────

class _RequestRow extends StatelessWidget {
  final RequestRecord record;
  final bool isEven;

  const _RequestRow({required this.record, required this.isEven});

  // Duration → color: green ≤500ms, blue ≤2s, orange ≤10s, red >10s
  Color _durColor(int? ms) {
    if (ms == null) return Colors.white38;
    if (ms <= 500) return Colors.greenAccent.shade200;
    if (ms <= 2000) return Colors.lightBlueAccent;
    if (ms <= 10000) return Colors.orangeAccent;
    return Colors.redAccent;
  }

  // TG/s → color: green ≥30, lime ≥15, orange ≥5, red <5
  Color _tpsColor(double? tps) {
    if (tps == null) return Colors.white38;
    if (tps >= 30) return Colors.greenAccent;
    if (tps >= 15) return Colors.lightGreenAccent;
    if (tps >= 5) return Colors.orangeAccent;
    return Colors.redAccent;
  }

  String _fmtDuration(int? ms) {
    if (ms == null) return '–';
    if (ms < 1000) return '$ms ms';
    if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)} s';
    return '${(ms / 60000).toStringAsFixed(1)} min';
  }

  String _fmtTokens() {
    final r = record;
    if (r.promptTokens != null && r.evalTokens != null) {
      return 'p${r.promptTokens} → ${r.evalTokens}';
    }
    if (r.evalTokens != null) return '${r.evalTokens} tok';
    if (r.tokens != null) return '${r.tokens} tok';
    return '–';
  }

  @override
  Widget build(BuildContext context) {
    final ts = DateTime.tryParse(record.ts);
    final timeStr =
        ts != null ? DateFormat('HH:mm:ss').format(ts.toLocal()) : '–';
    final tps = record.tokensPerSecond;

    return Container(
      color: isEven
          ? Colors.white.withValues(alpha: 0.025)
          : Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // Status dot
          Container(
            width: 6,
            height: 6,
            margin: const EdgeInsets.only(right: 10),
            decoration: BoxDecoration(
              color: record.error
                  ? Colors.redAccent
                  : Colors.greenAccent.shade400,
              shape: BoxShape.circle,
            ),
          ),
          // Time
          SizedBox(
            width: 66,
            child: Text(
              timeStr,
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ),
          // Model
          Expanded(
            flex: 3,
            child: Text(
              record.model,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Duration
          SizedBox(
            width: 82,
            child: Text(
              _fmtDuration(record.durationMs),
              textAlign: TextAlign.right,
              style: TextStyle(
                color: _durColor(record.durationMs),
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
          // Tokens
          SizedBox(
            width: 110,
            child: Text(
              _fmtTokens(),
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ),
          // TG/s
          SizedBox(
            width: 68,
            child: Text(
              tps != null ? tps.toStringAsFixed(1) : '–',
              textAlign: TextAlign.right,
              style: TextStyle(
                color: _tpsColor(tps),
                fontSize: 12,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          // Status badge
          SizedBox(
            width: 48,
            child: Align(
              alignment: Alignment.centerRight,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: record.error
                      ? Colors.redAccent.withValues(alpha: 0.15)
                      : Colors.greenAccent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  record.error ? 'ERR' : 'OK',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: record.error ? Colors.redAccent : Colors.greenAccent,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
