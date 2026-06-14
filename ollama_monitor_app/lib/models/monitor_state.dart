// Data models for Ollama Monitor

class ServerInfo {
  final String id;
  final String name;

  const ServerInfo({required this.id, required this.name});

  factory ServerInfo.fromJson(Map<String, dynamic> j) => ServerInfo(
        id:   j['id']   as String? ?? 'default',
        name: j['name'] as String? ?? 'Server',
      );
}

class GpuMetric {
  final int index;
  final String name;
  final double utilizationPct;
  final double memoryUsedMb;
  final double memoryTotalMb;
  final double? temperatureC;
  final String vendor;

  GpuMetric({
    required this.index,
    required this.name,
    required this.utilizationPct,
    required this.memoryUsedMb,
    required this.memoryTotalMb,
    this.temperatureC,
    required this.vendor,
  });

  factory GpuMetric.fromJson(Map<String, dynamic> j) => GpuMetric(
        index: j['index'] ?? 0,
        name: j['name'] ?? 'GPU',
        utilizationPct: (j['utilization_pct'] ?? 0).toDouble(),
        memoryUsedMb: (j['memory_used_mb'] ?? 0).toDouble(),
        memoryTotalMb: (j['memory_total_mb'] ?? 0).toDouble(),
        temperatureC: j['temperature_c'] != null ? (j['temperature_c']).toDouble() : null,
        vendor: j['vendor'] ?? 'unknown',
      );

  double get memoryPct => memoryTotalMb > 0 ? memoryUsedMb / memoryTotalMb * 100 : 0;
}

class SystemMetrics {
  final double cpuPct;
  final double ramUsedGb;
  final double ramTotalGb;
  final double ramPct;
  final double diskUsedGb;
  final double diskTotalGb;
  final double diskPct;
  final List<GpuMetric> gpus;

  SystemMetrics({
    required this.cpuPct,
    required this.ramUsedGb,
    required this.ramTotalGb,
    required this.ramPct,
    required this.diskUsedGb,
    required this.diskTotalGb,
    required this.diskPct,
    required this.gpus,
  });

  factory SystemMetrics.fromJson(Map<String, dynamic> j) => SystemMetrics(
        cpuPct: (j['cpu_pct'] ?? 0).toDouble(),
        ramUsedGb: (j['ram_used_gb'] ?? 0).toDouble(),
        ramTotalGb: (j['ram_total_gb'] ?? 0).toDouble(),
        ramPct: (j['ram_pct'] ?? 0).toDouble(),
        diskUsedGb: (j['disk_used_gb'] ?? 0).toDouble(),
        diskTotalGb: (j['disk_total_gb'] ?? 0).toDouble(),
        diskPct: (j['disk_pct'] ?? 0).toDouble(),
        gpus: (j['gpus'] as List? ?? []).map((g) => GpuMetric.fromJson(g)).toList(),
      );
}

class RunningModel {
  final String name;
  final String digest;
  final int sizeBytes;
  final String expiresAt;
  final Map<String, dynamic> details;

  RunningModel({
    required this.name,
    required this.digest,
    required this.sizeBytes,
    required this.expiresAt,
    required this.details,
  });

  factory RunningModel.fromJson(Map<String, dynamic> j) => RunningModel(
        name: j['name'] ?? '',
        digest: j['digest'] ?? '',
        sizeBytes: j['size'] ?? 0,
        expiresAt: j['expires_at'] ?? '',
        details: j['details'] ?? {},
      );

  double get sizeGb => sizeBytes / 1e9;
  String get shortName => name.split(':').first;
  String get tag => name.contains(':') ? name.split(':').last : 'latest';
}

class RequestRecord {
  final String ts;
  final String model;
  final String serverId;
  final int? durationMs;
  final int? tokens;
  final bool error;
  final double? tgTps;
  final int? promptTokens;
  final int? evalTokens;
  final double? evalTps;

  RequestRecord({
    required this.ts,
    required this.model,
    this.serverId = 'default',
    this.durationMs,
    this.tokens,
    this.error = false,
    this.tgTps,
    this.promptTokens,
    this.evalTokens,
    this.evalTps,
  });

  factory RequestRecord.fromJson(Map<String, dynamic> j) => RequestRecord(
        ts:           j['ts']    ?? '',
        model:        j['model'] ?? 'unknown',
        serverId:     j['server_id'] as String? ?? 'default',
        durationMs:   j['duration_ms'],
        tokens:       j['tokens'],
        error:        j['error'] == true,
        tgTps:        j['tg_tps']   != null ? (j['tg_tps']   as num).toDouble() : null,
        promptTokens: j['prompt_tokens'],
        evalTokens:   j['eval_tokens'],
        evalTps:      j['eval_tps']  != null ? (j['eval_tps']  as num).toDouble() : null,
      );

  double? get tokensPerSecond =>
      tgTps ??
      evalTps ??
      ((tokens != null && durationMs != null && durationMs! > 0)
          ? tokens! / (durationMs! / 1000)
          : null);
}

class LogLine {
  final String ts;
  final String text;
  final String source;   // 'server' | 'app'
  final String level;    // 'info' | 'warn' | 'error' | 'debug'
  final String serverId;

  LogLine({
    required this.ts,
    required this.text,
    this.source   = 'server',
    this.level    = 'info',
    this.serverId = 'default',
  });

  factory LogLine.fromJson(Map<String, dynamic> j) => LogLine(
        ts:       j['ts']        ?? '',
        text:     j['text']      ?? '',
        source:   j['source']    ?? 'server',
        level:    j['level']     ?? 'info',
        serverId: j['server_id'] as String? ?? 'default',
      );

  bool get isError => level == 'error';
  bool get isWarn  => level == 'warn';
  bool get isDebug => level == 'debug';
}

class MonitorSnapshot {
  final DateTime ts;
  final SystemMetrics? system;
  final List<RunningModel> runningModels;
  final String ollamaVersion;
  final List<RequestRecord> recentRequests;

  MonitorSnapshot({
    required this.ts,
    this.system,
    required this.runningModels,
    required this.ollamaVersion,
    required this.recentRequests,
  });

  factory MonitorSnapshot.fromJson(Map<String, dynamic> j) => MonitorSnapshot(
        ts: DateTime.tryParse(j['ts'] ?? '') ?? DateTime.now(),
        system: j['system'] != null ? SystemMetrics.fromJson(j['system']) : null,
        runningModels: (j['running_models'] as List? ?? [])
            .map((m) => RunningModel.fromJson(m))
            .toList(),
        ollamaVersion: j['ollama_version'] ?? 'unknown',
        recentRequests: (j['recent_requests'] as List? ?? [])
            .map((r) => RequestRecord.fromJson(r))
            .toList(),
      );
}
