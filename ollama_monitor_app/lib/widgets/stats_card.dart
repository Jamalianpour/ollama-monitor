import 'package:flutter/material.dart';

import '../services/monitor_service.dart';

class StatsCard extends StatelessWidget {
  final AggregateStats stats;

  const StatsCard({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.bar_chart,
                  color: Colors.deepPurpleAccent,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text(
                  'Last ${stats.hours.toInt()}h Summary',
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(color: Colors.white70),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 24,
              runSpacing: 12,
              children: [
                _Stat('Requests', '${stats.totalRequests}'),
                _Stat(
                  'Errors',
                  '${stats.errors}',
                  color: stats.errors > 0 ? Colors.red.shade300 : null,
                ),
                if (stats.avgDurationMs != null)
                  _Stat(
                    'Avg Latency',
                    '${stats.avgDurationMs!.toStringAsFixed(0)} ms',
                  ),
                if (stats.maxDurationMs != null)
                  _Stat(
                    'Max Latency',
                    '${stats.maxDurationMs!.toStringAsFixed(0)} ms',
                  ),
                if (stats.avgTps != null)
                  _Stat('Avg TPS', stats.avgTps!.toStringAsFixed(1)),
              ],
            ),
            if (stats.byModel.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Divider(color: Colors.white10),
              const SizedBox(height: 8),
              Text(
                'By model',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Colors.white38,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 6),
              ...stats.byModel
                  .take(5)
                  .map(
                    (m) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              m.model,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            '${m.calls} calls',
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 11,
                            ),
                          ),
                          if (m.avgMs != null) ...[
                            const SizedBox(width: 12),
                            Text(
                              '${m.avgMs!.toStringAsFixed(0)} ms avg',
                              style: const TextStyle(
                                color: Colors.white38,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _Stat(this.label, this.value, {this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.white38,
            fontSize: 10,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            color: color ?? Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}
