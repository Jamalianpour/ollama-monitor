import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/backend_entry.dart';
import '../models/monitor_state.dart';

// ── Per-backend WebSocket connection ─────────────────────────────────────────

class _BackendConn {
  final BackendEntry entry;
  WebSocketChannel? channel;
  Timer? reconnectTimer;
  bool connected = false;
  String status = 'Connecting…';

  _BackendConn(this.entry);

  String get wsUrl {
    final base = entry.url
        .replaceFirst('https://', 'wss://')
        .replaceFirst('http://', 'ws://');
    return '$base/ws?token=${entry.token}';
  }
}

// ── MonitorService ────────────────────────────────────────────────────────────

class MonitorService extends ChangeNotifier {
  final Map<String, _BackendConn> _connections = {};
  String _selectedServerId = '';

  // ── Per-server snapshot + history maps ───────────────────────────────────────
  final Map<String, MonitorSnapshot?> _snapshots = {};
  final Map<String, List<double>> _cpuHistories = {};
  final Map<String, List<double>> _ramHistories = {};

  // ── Shared collections (all backends, tagged by serverId) ─────────────────
  final List<LogLine> _logs = [];
  final List<RequestRecord> _requests = [];
  final List<Map<String, dynamic>> _logFiles = [];

  bool _historyLoaded = false;

  // ── Public getters ──────────────────────────────────────────────────────────

  String get selectedServerId => _selectedServerId;

  List<ServerInfo> get servers => _connections.values
      .map((c) => ServerInfo(id: c.entry.id, name: c.entry.name))
      .toList();

  bool get connected => _connections.values.any((c) => c.connected);

  String get statusMessage {
    final conn = _connections[_selectedServerId];
    if (conn != null) return conn.status;
    if (_connections.isEmpty) return 'No servers configured';
    final ok = _connections.values.where((c) => c.connected).length;
    final tot = _connections.length;
    return '$ok/$tot connected';
  }

  bool get historyLoaded => _historyLoaded;

  MonitorSnapshot? get latest => _snapshots[_selectedServerId];

  List<double> get cpuHistory =>
      List.unmodifiable(_cpuHistories[_selectedServerId] ?? []);

  List<double> get ramHistory =>
      List.unmodifiable(_ramHistories[_selectedServerId] ?? []);

  String get ollamaVersion =>
      _snapshots[_selectedServerId]?.ollamaVersion ?? '–';

  List<LogLine> get logs {
    if (_selectedServerId.isEmpty) return List.unmodifiable(_logs);
    return _logs.where((l) => l.serverId == _selectedServerId).toList();
  }

  List<RequestRecord> get requests {
    if (_selectedServerId.isEmpty) return List.unmodifiable(_requests);
    return _requests.where((r) => r.serverId == _selectedServerId).toList();
  }

  List<Map<String, dynamic>> get logFiles {
    if (_selectedServerId.isEmpty) return List.unmodifiable(_logFiles);
    return _logFiles
        .where((lf) => lf['server_id'] == _selectedServerId)
        .toList();
  }

  // Backward-compat getters used by old code paths
  String get backendHost {
    final conn = _connections[_selectedServerId];
    if (conn != null) return Uri.parse(conn.entry.url).host;
    return _connections.isNotEmpty
        ? Uri.parse(_connections.values.first.entry.url).host
        : 'localhost';
  }

  int get backendPort {
    final conn = _connections[_selectedServerId];
    if (conn != null) return Uri.parse(conn.entry.url).port;
    return _connections.isNotEmpty
        ? Uri.parse(_connections.values.first.entry.url).port
        : 12434;
  }

  // ── Server selection ─────────────────────────────────────────────────────────

  void selectServer(String id) {
    if (_selectedServerId == id) return;
    _selectedServerId = id;
    notifyListeners();
  }

  // ── Aggregate stats ───────────────────────────────────────────────────────────

  AggregateStats statsFor(double hours) {
    final cutoff = DateTime.now().subtract(
      Duration(milliseconds: (hours * 3600 * 1000).round()),
    );
    final recent = _requests.where((r) {
      final ts = DateTime.tryParse(r.ts);
      if (ts == null || !ts.isAfter(cutoff)) return false;
      return _selectedServerId.isEmpty || r.serverId == _selectedServerId;
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
        avgTokens: tkns.isNotEmpty
            ? tkns.reduce((a, b) => a + b) / tkns.length
            : null,
      );
    }).toList()..sort((a, b) => b.calls.compareTo(a.calls));

    return AggregateStats(
      hours: hours,
      totalRequests: recent.length,
      errors: recent.where((r) => r.error).length,
      avgDurationMs: durations.isNotEmpty
          ? durations.reduce((a, b) => a + b) / durations.length
          : null,
      maxDurationMs: durations.isNotEmpty
          ? durations.reduce((a, b) => a > b ? a : b)
          : null,
      avgTps: tpsList.isNotEmpty
          ? tpsList.reduce((a, b) => a + b) / tpsList.length
          : null,
      byModel: byModel,
    );
  }

  // ── configure ────────────────────────────────────────────────────────────────

  void configure({List<BackendEntry>? backends}) {
    final list = backends ?? [];

    // Remove connections for backends no longer in the list
    final newIds = list.map((b) => b.id).toSet();
    for (final id in _connections.keys.toList()) {
      if (!newIds.contains(id)) {
        _connections[id]!.reconnectTimer?.cancel();
        _connections[id]!.channel?.sink.close();
        _connections.remove(id);
      }
    }

    // Add connections for new (not yet connected) backends
    for (final entry in list) {
      if (!_connections.containsKey(entry.id)) {
        final conn = _BackendConn(entry);
        _connections[entry.id] = conn;
        _connectBackend(conn);
      }
    }

    // Auto-select if selection is missing/invalid
    if ((_selectedServerId.isEmpty || !newIds.contains(_selectedServerId)) &&
        list.isNotEmpty) {
      _selectedServerId = list.first.id;
    }

    notifyListeners();
  }

  // ── WebSocket connection ──────────────────────────────────────────────────────

  void _connectBackend(_BackendConn conn) {
    try {
      conn.channel = WebSocketChannel.connect(Uri.parse(conn.wsUrl));
      conn.channel!.stream.listen(
        (raw) => _onMessage(raw, conn.entry.id),
        onError: (_) => _onBackendError(conn),
        onDone: () => _onBackendDone(conn),
      );
      conn.connected = true;
      conn.status = 'Connected';
      notifyListeners();
      _loadBackendHistory(conn.entry);
    } catch (_) {
      _onBackendError(conn);
    }
  }

  void _onBackendError(_BackendConn conn) {
    if (!_connections.containsKey(conn.entry.id)) return;
    conn.connected = false;
    conn.status = 'Disconnected – retrying in 3s…';
    notifyListeners();
    conn.reconnectTimer?.cancel();
    conn.reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (_connections.containsKey(conn.entry.id)) _connectBackend(conn);
    });
  }

  void _onBackendDone(_BackendConn conn) {
    if (!_connections.containsKey(conn.entry.id)) return;
    conn.connected = false;
    conn.status = 'Connection closed – retrying in 3s…';
    notifyListeners();
    conn.reconnectTimer?.cancel();
    conn.reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (_connections.containsKey(conn.entry.id)) _connectBackend(conn);
    });
  }

  void _onMessage(dynamic raw, String backendId) {
    try {
      final msg = json.decode(raw as String) as Map<String, dynamic>;
      final type = msg['type'] as String?;
      final data = msg['data'];

      switch (type) {
        case 'init':
          // Update log files for this backend
          _logFiles.removeWhere((lf) => lf['server_id'] == backendId);
          for (final lf in (data['log_files'] as List? ?? [])) {
            final m = Map<String, dynamic>.from(lf as Map<String, dynamic>);
            m['server_id'] = backendId;
            _logFiles.add(m);
          }

          // Seed logs (only if we have none yet for this backend)
          if (!_logs.any((l) => l.serverId == backendId)) {
            for (final l in (data['logs'] as List? ?? [])) {
              final m = Map<String, dynamic>.from(l as Map<String, dynamic>);
              m['server_id'] = backendId;
              _logs.add(LogLine.fromJson(m));
            }
          }

          // Seed requests
          for (final r in (data['requests'] as List? ?? [])) {
            final m = Map<String, dynamic>.from(r as Map<String, dynamic>);
            m['server_id'] = backendId;
            final rec = RequestRecord.fromJson(m);
            if (!_requests.any(
              (x) =>
                  x.ts == rec.ts &&
                  x.model == rec.model &&
                  x.serverId == backendId,
            )) {
              _requests.add(rec);
            }
          }

        case 'metrics':
          final snap = MonitorSnapshot.fromJson(data as Map<String, dynamic>);
          _snapshots[backendId] = snap;
          final cpu = _cpuHistories.putIfAbsent(backendId, () => []);
          final ram = _ramHistories.putIfAbsent(backendId, () => []);
          if (snap.system != null) {
            cpu.add(snap.system!.cpuPct);
            ram.add(snap.system!.ramPct);
            if (cpu.length > 120) cpu.removeAt(0);
            if (ram.length > 120) ram.removeAt(0);
          }

        case 'log':
          final m = Map<String, dynamic>.from(data as Map<String, dynamic>);
          m['server_id'] = backendId;
          _logs.add(LogLine.fromJson(m));
          if (_logs.length > 1000) _logs.removeAt(0);

        case 'request':
          final m = Map<String, dynamic>.from(data as Map<String, dynamic>);
          m['server_id'] = backendId;
          _requests.add(RequestRecord.fromJson(m));
          if (_requests.length > 1000) _requests.removeAt(0);
      }

      notifyListeners();
    } catch (e) {
      debugPrint('WS parse error [$backendId]: $e');
    }
  }

  // ── Historical data ────────────────────────────────────────────────────────

  Future<void> loadHistory({double hours = 24}) async {
    _historyLoaded = false;
    notifyListeners();
    await Future.wait(
      _connections.values.map(
        (c) => _loadBackendHistory(c.entry, hours: hours),
      ),
    );
    _historyLoaded = true;
    notifyListeners();
  }

  Future<void> _loadBackendHistory(
    BackendEntry entry, {
    double hours = 24,
  }) async {
    final base = entry.url;
    final headers = {'Authorization': 'Bearer ${entry.token}'};
    final sid = entry.id;

    try {
      final resp = await http
          .get(
            Uri.parse('$base/api/history/metrics?hours=$hours&limit=120'),
            headers: headers,
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final data = json.decode(resp.body) as Map<String, dynamic>;
        final rows = data['rows'] as List? ?? [];
        final cpu = <double>[];
        final ram = <double>[];
        for (final r in rows) {
          cpu.add((r['cpu_pct'] as num? ?? 0).toDouble());
          ram.add((r['ram_pct'] as num? ?? 0).toDouble());
        }
        _cpuHistories[sid] = cpu;
        _ramHistories[sid] = ram;
      }
    } catch (e) {
      debugPrint('Metrics history load failed [${entry.name}]: $e');
    }

    try {
      final resp = await http
          .get(
            Uri.parse('$base/api/history/requests?hours=$hours&limit=500'),
            headers: headers,
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final data = json.decode(resp.body) as Map<String, dynamic>;
        final rows = (data['requests'] as List? ?? []).map((r) {
          final m = Map<String, dynamic>.from(r as Map<String, dynamic>);
          m['server_id'] = sid;
          return RequestRecord.fromJson(m);
        }).toList();
        final existingKeys = _requests
            .where((r) => r.serverId == sid)
            .map((r) => '${r.ts}${r.model}')
            .toSet();
        for (final r in rows.reversed) {
          if (!existingKeys.contains('${r.ts}${r.model}')) {
            _requests.insert(0, r);
          }
        }
        if (_requests.length > 1000) {
          _requests.removeRange(0, _requests.length - 1000);
        }
      }
    } catch (e) {
      debugPrint('Requests history load failed [${entry.name}]: $e');
    }
  }

  @override
  void dispose() {
    for (final conn in _connections.values) {
      conn.reconnectTimer?.cancel();
      conn.channel?.sink.close();
    }
    super.dispose();
  }
}

// ── Aggregate stats models ────────────────────────────────────────────────────

class ModelStat {
  final String model;
  final int calls;
  final double? avgMs;
  final double? avgTokens;

  ModelStat({
    required this.model,
    required this.calls,
    this.avgMs,
    this.avgTokens,
  });

  factory ModelStat.fromJson(Map<String, dynamic> j) => ModelStat(
    model: j['model'] ?? '',
    calls: j['calls'] ?? 0,
    avgMs: j['avg_ms'] != null ? (j['avg_ms'] as num).toDouble() : null,
    avgTokens: j['avg_tokens'] != null
        ? (j['avg_tokens'] as num).toDouble()
        : null,
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
}
