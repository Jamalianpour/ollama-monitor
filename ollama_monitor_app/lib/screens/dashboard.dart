import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/monitor_state.dart';
import '../services/auth_service.dart';
import '../services/monitor_service.dart';
import '../widgets/gauge_card.dart';
import '../widgets/gpu_card.dart';
import '../widgets/history_chart.dart';
import '../widgets/log_viewer.dart';
import '../widgets/request_table.dart';
import '../widgets/running_models_card.dart';
import '../widgets/stats_card.dart';
import 'auth_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  double _historyHours = 24;

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<MonitorService>();
    final snap = svc.latest;
    final sys = snap?.system;

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: _buildAppBar(context, svc),
      body: LayoutBuilder(
        builder: (ctx, constraints) {
          final isWide = constraints.maxWidth > 960;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: isWide
                ? _buildWide(context, svc, snap, sys)
                : _buildNarrow(context, svc, snap, sys),
          );
        },
      ),
    );
  }

  // ── App bar ────────────────────────────────────────────────────────────────

  PreferredSizeWidget _buildAppBar(BuildContext context, MonitorService svc) {
    return AppBar(
      backgroundColor: const Color(0xFF161B22),
      elevation: 0,
      title: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: Colors.deepPurple.shade700,
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Icon(Icons.smart_toy, color: Colors.white, size: 16),
          ),
          const SizedBox(width: 10),
          const Text('Ollama Monitor',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ],
      ),
      actions: [
        // Ollama version badge
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Chip(
            avatar: const Icon(Icons.info_outline, size: 14),
            label: Text('v${svc.ollamaVersion}',
                style: const TextStyle(fontSize: 11)),
            backgroundColor: Colors.white10,
            side: BorderSide.none,
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
          ),
        ),
        // History range selector
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: DropdownButton<double>(
            value: _historyHours,
            underline: const SizedBox(),
            dropdownColor: const Color(0xFF1C2128),
            style: const TextStyle(color: Colors.white70, fontSize: 12),
            items: const [
              DropdownMenuItem(value: 1, child: Text('Last 1h')),
              DropdownMenuItem(value: 6, child: Text('Last 6h')),
              DropdownMenuItem(value: 24, child: Text('Last 24h')),
              DropdownMenuItem(value: 72, child: Text('Last 3d')),
              DropdownMenuItem(value: 168, child: Text('Last 7d')),
            ],
            onChanged: (v) {
              if (v == null) return;
              setState(() => _historyHours = v);
              svc.loadHistory(hours: v);
            },
          ),
        ),
        // Refresh history button
        IconButton(
          icon: svc.historyLoaded
              ? const Icon(Icons.refresh, size: 18)
              : const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)),
          onPressed: () => svc.loadHistory(hours: _historyHours),
          tooltip: 'Refresh history',
        ),
        // Connection status
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: svc.connected ? Colors.greenAccent : Colors.redAccent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(svc.statusMessage,
                  style: const TextStyle(fontSize: 11, color: Colors.white54)),
            ],
          ),
        ),
        // Account menu
        PopupMenuButton<String>(
          icon: const Icon(Icons.account_circle_outlined, size: 22),
          tooltip: 'Account',
          color: const Color(0xFF1C2128),
          onSelected: (value) async {
            if (value == 'change_password') {
              showDialog(
                  context: context,
                  builder: (_) => const ChangePasswordDialog());
            } else if (value == 'settings') {
              _showSettings(context, svc);
            } else if (value == 'logout') {
              await context.read<AuthService>().logout();
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(
                value: 'change_password',
                child: Row(children: [
                  Icon(Icons.lock_reset_outlined, size: 16, color: Colors.white70),
                  SizedBox(width: 8),
                  Text('Change Password'),
                ])),
            PopupMenuItem(
                value: 'settings',
                child: Row(children: [
                  Icon(Icons.settings_outlined, size: 16, color: Colors.white70),
                  SizedBox(width: 8),
                  Text('Connection Settings'),
                ])),
            PopupMenuDivider(),
            PopupMenuItem(
                value: 'logout',
                child: Row(children: [
                  Icon(Icons.logout, size: 16, color: Colors.redAccent),
                  SizedBox(width: 8),
                  Text('Sign Out', style: TextStyle(color: Colors.redAccent)),
                ])),
          ],
        ),
      ],
    );
  }

  // ── Wide layout (desktop ≥960px) ───────────────────────────────────────────

  Widget _buildWide(BuildContext context, MonitorService svc,
      MonitorSnapshot? snap, SystemMetrics? sys) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Row 1: System gauges (left) + History charts (right) ───────────
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Left: gauges + GPU
            Expanded(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SectionHeader('System Resources'),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                          child: GaugeCard(
                              label: 'CPU',
                              value: sys?.cpuPct ?? 0,
                              subtitle: 'Utilization',
                              color: Colors.blueAccent)),
                      const SizedBox(width: 8),
                      Expanded(
                          child: GaugeCard(
                              label: 'RAM',
                              value: sys?.ramPct ?? 0,
                              subtitle: sys != null
                                  ? '${sys.ramUsedGb.toStringAsFixed(1)} / ${sys.ramTotalGb.toStringAsFixed(1)} GB'
                                  : '–',
                              color: Colors.cyanAccent)),
                      const SizedBox(width: 8),
                      Expanded(
                          child: GaugeCard(
                              label: 'Disk',
                              value: sys?.diskPct ?? 0,
                              subtitle: sys != null
                                  ? '${sys.diskUsedGb.toStringAsFixed(0)} / ${sys.diskTotalGb.toStringAsFixed(0)} GB'
                                  : '–',
                              color: Colors.tealAccent)),
                    ],
                  ),
                  if (sys != null && sys.gpus.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const _SectionHeader('GPU'),
                    const SizedBox(height: 8),
                    ...sys.gpus.map((g) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: GpuCard(gpu: g))),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 16),
            // Right: history charts
            Expanded(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SectionHeader(
                      'History  (${svc.cpuHistory.length} samples)'),
                  const SizedBox(height: 8),
                  HistoryChart(
                      label: 'CPU %',
                      data: svc.cpuHistory,
                      color: Colors.blueAccent),
                  const SizedBox(height: 8),
                  HistoryChart(
                      label: 'RAM %',
                      data: svc.ramHistory,
                      color: Colors.cyanAccent),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // ── Row 2: Running models (left) + Stats summary (right) ───────────
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
                flex: 4,
                child: RunningModelsCard(models: snap?.runningModels ?? [])),
            const SizedBox(width: 16),
            Expanded(
                flex: 6,
                child: StatsCard(stats: svc.statsFor(_historyHours))),
          ],
        ),
        const SizedBox(height: 16),

        // ── Row 3: Request table ────────────────────────────────────────────
        const _SectionHeader('Requests'),
        const SizedBox(height: 8),
        RequestTable(requests: svc.requests),
        const SizedBox(height: 16),

        // ── Row 4: Logs ─────────────────────────────────────────────────────
        const _SectionHeader('Logs'),
        const SizedBox(height: 8),
        LogViewer(logs: svc.logs, logFiles: svc.logFiles),
        const SizedBox(height: 24),
      ],
    );
  }

  // ── Narrow layout (mobile / small window) ─────────────────────────────────

  Widget _buildNarrow(BuildContext context, MonitorService svc,
      MonitorSnapshot? snap, SystemMetrics? sys) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeader('System Resources'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            SizedBox(
                width: 160,
                child: GaugeCard(
                    label: 'CPU',
                    value: sys?.cpuPct ?? 0,
                    subtitle: 'Utilization',
                    color: Colors.blueAccent)),
            SizedBox(
                width: 160,
                child: GaugeCard(
                    label: 'RAM',
                    value: sys?.ramPct ?? 0,
                    subtitle: sys != null
                        ? '${sys.ramUsedGb.toStringAsFixed(1)} / ${sys.ramTotalGb.toStringAsFixed(1)} GB'
                        : '–',
                    color: Colors.cyanAccent)),
            SizedBox(
                width: 160,
                child: GaugeCard(
                    label: 'Disk',
                    value: sys?.diskPct ?? 0,
                    subtitle: sys != null
                        ? '${sys.diskUsedGb.toStringAsFixed(0)} / ${sys.diskTotalGb.toStringAsFixed(0)} GB'
                        : '–',
                    color: Colors.tealAccent)),
          ],
        ),
        if (sys != null && sys.gpus.isNotEmpty) ...[
          const SizedBox(height: 20),
          const _SectionHeader('GPU'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: sys.gpus
                .map((g) => SizedBox(width: 280, child: GpuCard(gpu: g)))
                .toList(),
          ),
        ],
        const SizedBox(height: 20),
        const _SectionHeader('History'),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
                child: HistoryChart(
                    label: 'CPU %',
                    data: svc.cpuHistory,
                    color: Colors.blueAccent)),
            const SizedBox(width: 12),
            Expanded(
                child: HistoryChart(
                    label: 'RAM %',
                    data: svc.ramHistory,
                    color: Colors.cyanAccent)),
          ],
        ),
        const SizedBox(height: 20),
        const _SectionHeader('Ollama'),
        const SizedBox(height: 8),
        RunningModelsCard(models: snap?.runningModels ?? []),
        const SizedBox(height: 12),
        StatsCard(stats: svc.statsFor(_historyHours)),
        const SizedBox(height: 20),
        const _SectionHeader('Requests'),
        const SizedBox(height: 8),
        RequestTable(requests: svc.requests),
        const SizedBox(height: 20),
        const _SectionHeader('Logs'),
        const SizedBox(height: 8),
        LogViewer(logs: svc.logs, logFiles: svc.logFiles),
        const SizedBox(height: 24),
      ],
    );
  }

  // ── Settings dialog ────────────────────────────────────────────────────────

  void _showSettings(BuildContext context, MonitorService svc) {
    final hostCtrl = TextEditingController(text: svc.backendHost);
    final portCtrl = TextEditingController(text: svc.backendPort.toString());
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1C2128),
        title: const Text('Backend Connection'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: hostCtrl,
              decoration: const InputDecoration(
                  labelText: 'Host', hintText: 'localhost'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: portCtrl,
              decoration:
                  const InputDecoration(labelText: 'Port', hintText: '12434'),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              svc.configure(
                host: hostCtrl.text.trim(),
                port: int.tryParse(portCtrl.text.trim()) ?? 12434,
              );
              Navigator.pop(context);
            },
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }
}

// ── Section header widget ──────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          title.toUpperCase(),
          style: const TextStyle(
            color: Colors.white38,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(width: 8),
        const Expanded(child: Divider(color: Colors.white12)),
      ],
    );
  }
}
