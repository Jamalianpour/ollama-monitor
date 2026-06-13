import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/monitor_state.dart';

class MonitorService extends ChangeNotifier {
  // ── Config ────────────────────────────────────────────────────────────────
  String _backendHost = 'localhost';
  int _backendPort = 12434;
  String _token = '';

  String get backendHost => _backendHost;
  int get backendPort => _backendPort;
  String get backendBase => 'http://$_backendHost:$_backendPort';
  String get wsUrl => 'ws://$_backendHost:$_backendPort/ws?token=$_token';

  Map<String, String> get _authHeaders => {
    'Authorization': 'Bearer $_token',
  };

  // ── State ─────────────────────────────────────────────────────────────────
  MonitorSnapshot? _latest;
  final List<LogLine> _logs = [];
  final List<RequestRecord> _requests = [];
  final List<double> _cpuHistory = [];
  final List<double> _ramHistory = [];
  bool _connected = false;
  bool _historyLoaded = false;
  String _statusMessage = 'Connecting…';
  String _ollamaVersion = '–';
  List<Map<String, dynamic>> _logFiles = [];

  MonitorSnapshot? get latest => _latest;
  List<LogLine> get logs => List.unmodifiable(_logs);
  List<RequestRecord> get requests => List.unmodifiable(_requests);
  List<double> get cpuHistory => List.unmodifiable(_cpuHistory);
  List<double> get ramHistory => List.unmodifiable(_ramHistory);
  bool get connected => _connected;
  bool get historyLoaded => _historyLoaded;
  String get statusMessage => _statusMessage;
  String get ollamaVersion => _ollamaVersion;
  List<Map<String, dynamic>> get logFiles => List.unmodifiable(_logFiles);

  /// Computes aggregate stats live from the in-memory request list —
  /// always up-to-date without a separate network call.
  AggregateStats statsFor(double hours) {
    final cutoff = DateTime.now()
        .subtract(Duration(milliseconds: (hours * 3600 * 1000).round()));
    final recent = _requests.where((r) {
      final ts = DateTime.tryParse(r.ts);
      return ts != null && ts.isAfter(cutoff);
    }).toList();

    final durations = recent
        .where((r) => r.durationMs != null)
        .map((r) => r.durationMs!.toDouble())
        .toList();
    final tpsList = recent
        .where((r) => r.tokensPerSecond != null)
        .map((r) => r.tokensPerSecond!)
        .toList();

    final modelMap = <String, List<RequestRecord>>{};
    for (final r in recent) {
      modelMap.putIfAbsent(r.model, () => []).add(r);
    }
    final byModel = modelMap.entries.map((e) {
      final ms = e.value
          .where((r) => r.durationMs != null)
          .map((r) => r.durationMs!.toDouble())
          .toList();
      final tkns = e.value
          .where((r) => r.tokens != null)
          .map((r) => r.tokens!.toDouble())
          .toList();
      return ModelStat(
        model: e.key,
        calls: e.value.length,
        avgMs: ms.isNotEmpty ? ms.reduce((a, b) => a + b) / ms.length : null,
        avgTokens: tkns.isNotEmpty ? tkns.reduce((a, b) => a + b) / tkns.length : null,
      );
    }).toList()
      ..sort((a, b) => b.calls.compareTo(a.calls));

    return AggregateStats(
      hours: hours,
      totalRequests: recent.length,
      errors: recent.where((r) => r.error).length,
      avgDurationMs: durations.isNotEmpty
          ? durations.reduce((a, b) => a + b) / durations.length : null,
      maxDurationMs: durations.isNotEmpty
          ? durations.reduce((a, b) => a > b ? a : b) : null,
      avgTps: tpsList.isNotEmpty
          ? tpsList.reduce((a, b) => a + b) / tpsList.length : null,
      byModel: byModel,
    );
  }

  // ── WS ────────────────────────────────────────────────────────────────────
  WebSocketChannel? _channel;
  Timer? _reconnectTimer;

  MonitorService();

  void configure({String? host, int? port, String? token}) {
    final newHost  = host  ?? _backendHost;
    final newPort  = port  ?? _backendPort;
    final newToken = token ?? _token;

    // Skip reconnect when nothing actually changed
    if (newHost == _backendHost && newPort == _backendPort && newToken == _token) return;

    _backendHost = newHost;
    _backendPort = newPort;
    _token       = newToken;
    _channel?.sink.close();
    _reconnectTimer?.cancel();
    _historyLoaded = false;
    connect();
  }

  // ── Historical data from REST ─────────────────────────────────────────────

  Future<void> loadHistory({double hours = 24}) async {
    try {
      await Future.wait([
        _loadHistoryMetrics(hours),
        _loadHistoryRequests(hours),
      ]);
      _historyLoaded = true;
      notifyListeners();
    } catch (e) {
      debugPrint('History load failed: $e');
    }
  }

  Future<void> _loadHistoryMetrics(double hours) async {
    final uri = Uri.parse('$backendBase/api/history/metrics?hours=$hours&limit=120');
    final resp = await http.get(uri, headers: _authHeaders).timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) return;
    final data = json.decode(resp.body) as Map<String, dynamic>;
    final rows = data['rows'] as List? ?? [];
    _cpuHistory.clear();
    _ramHistory.clear();
    for (final r in rows) {
      _cpuHistory.add((r['cpu_pct'] as num? ?? 0).toDouble());
      _ramHistory.add((r['ram_pct'] as num? ?? 0).toDouble());
    }
    // Keep last 120 points
    if (_cpuHistory.length > 120) {
      _cpuHistory.removeRange(0, _cpuHistory.length - 120);
      _ramHistory.removeRange(0, _ramHistory.length - 120);
    }
  }

  Future<void> _loadHistoryRequests(double hours) async {
    final uri = Uri.parse('$backendBase/api/history/requests?hours=$hours&limit=500');
    final resp = await http.get(uri, headers: _authHeaders).timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) return;
    final data = json.decode(resp.body) as Map<String, dynamic>;
    final rows = (data['requests'] as List? ?? [])
        .map((r) => RequestRecord.fromJson(r as Map<String, dynamic>))
        .toList();
    // Merge: keep existing live entries, prepend history without duplicates
    final existingTs = _requests.map((r) => '${r.ts}${r.model}').toSet();
    for (final r in rows.reversed) {
      if (!existingTs.contains('${r.ts}${r.model}')) {
        _requests.insert(0, r);
      }
    }
    if (_requests.length > 500) {
      _requests.removeRange(0, _requests.length - 500);
    }
  }

  // ── WebSocket ─────────────────────────────────────────────────────────────

  void connect() {
    try {
      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));
      _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
      );
      _connected = true;
      _statusMessage = 'Connected';
      notifyListeners();
      // Load historical data after connecting
      loadHistory();
    } catch (e) {
      _onError(e);
    }
  }

  void _onMessage(dynamic raw) {
    try {
      final msg = json.decode(raw as String) as Map<String, dynamic>;
      final type = msg['type'] as String?;
      final data = msg['data'];

      switch (type) {
        case 'init':
          _logFiles = List<Map<String, dynamic>>.from(
              data['log_files'] as List? ?? []);
          final initLogs = data['logs'] as List? ?? [];
          // Only seed if we have no logs yet (history may have been loaded)
          if (_logs.isEmpty) {
            _logs.addAll(initLogs.map((l) => LogLine.fromJson(l)));
          }
          final initReqs = data['requests'] as List? ?? [];
          for (final r in initReqs) {
            final rec = RequestRecord.fromJson(r as Map<String, dynamic>);
            if (!_requests.any((x) => x.ts == rec.ts && x.model == rec.model)) {
              _requests.add(rec);
            }
          }
          break;

        case 'metrics':
          final snap = MonitorSnapshot.fromJson(data as Map<String, dynamic>);
          _latest = snap;
          _ollamaVersion = snap.ollamaVersion;

          if (snap.system != null) {
            _cpuHistory.add(snap.system!.cpuPct);
            _ramHistory.add(snap.system!.ramPct);
            if (_cpuHistory.length > 120) _cpuHistory.removeAt(0);
            if (_ramHistory.length > 120) _ramHistory.removeAt(0);
          }
          break;

        case 'log':
          _logs.add(LogLine.fromJson(data as Map<String, dynamic>));
          if (_logs.length > 500) _logs.removeAt(0);
          break;

        case 'request':
          final rec = RequestRecord.fromJson(data as Map<String, dynamic>);
          _requests.add(rec);
          if (_requests.length > 500) _requests.removeAt(0);
          break;
      }

      notifyListeners();
    } catch (e) {
      debugPrint('WS parse error: $e');
    }
  }

  void _onError(dynamic e) {
    _connected = false;
    _statusMessage = 'Disconnected – retrying in 3s…';
    notifyListeners();
    _scheduleReconnect();
  }

  void _onDone() {
    _connected = false;
    _statusMessage = 'Connection closed – retrying in 3s…';
    notifyListeners();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), connect);
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    super.dispose();
  }
}

// ── Aggregate stats model ─────────────────────────────────────────────────────

class ModelStat {
  final String model;
  final int calls;
  final double? avgMs;
  final double? avgTokens;

  ModelStat({required this.model, required this.calls, this.avgMs, this.avgTokens});

  factory ModelStat.fromJson(Map<String, dynamic> j) => ModelStat(
        model: j['model'] ?? '',
        calls: j['calls'] ?? 0,
        avgMs: j['avg_ms'] != null ? (j['avg_ms'] as num).toDouble() : null,
        avgTokens: j['avg_tokens'] != null ? (j['avg_tokens'] as num).toDouble() : null,
      );
}

class AggregateStats {
  final double hours;
  final int totalRequests;
  final int errors;
  final double? avgDurationMs;
  final double? maxDurationMs;
  final double? avgTps;
  final List<ModelStat> byModel;

  AggregateStats({
    required this.hours,
    required this.totalRequests,
    required this.errors,
    this.avgDurationMs,
    this.maxDurationMs,
    this.avgTps,
    required this.byModel,
  });

  factory AggregateStats.fromJson(Map<String, dynamic> j) {
    final r = j['requests'] as Map<String, dynamic>? ?? {};
    return AggregateStats(
      hours: (j['hours'] as num? ?? 24).toDouble(),
      totalRequests: (r['total'] as num? ?? 0).toInt(),
      errors: (r['errors'] as num? ?? 0).toInt(),
      avgDurationMs: r['avg_duration_ms'] != null ? (r['avg_duration_ms'] as num).toDouble() : null,
      maxDurationMs: r['max_duration_ms'] != null ? (r['max_duration_ms'] as num).toDouble() : null,
      avgTps: r['avg_tps'] != null ? (r['avg_tps'] as num).toDouble() : null,
      byModel: (r['by_model'] as List? ?? [])
          .map((m) => ModelStat.fromJson(m as Map<String, dynamic>))
          .toList(),
    );
  }
}
