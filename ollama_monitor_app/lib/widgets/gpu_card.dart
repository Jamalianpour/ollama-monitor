import 'package:flutter/material.dart';

import '../models/monitor_state.dart';

class GpuCard extends StatelessWidget {
  final GpuMetric gpu;

  const GpuCard({super.key, required this.gpu});

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
                Icon(
                  Icons.developer_board,
                  color: gpu.vendor == 'nvidia'
                      ? Colors.greenAccent
                      : Colors.redAccent,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    gpu.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (gpu.temperatureC != null) _TempBadge(gpu.temperatureC!),
              ],
            ),
            const SizedBox(height: 12),
            _Bar(
              label: 'GPU',
              value: gpu.utilizationPct,
              color: Colors.purpleAccent,
            ),
            const SizedBox(height: 8),
            _Bar(
              label: 'VRAM',
              value: gpu.memoryPct,
              subtitle:
                  '${(gpu.memoryUsedMb / 1024).toStringAsFixed(1)} / ${(gpu.memoryTotalMb / 1024).toStringAsFixed(1)} GB',
              color: Colors.blueAccent,
            ),
          ],
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  final String label;
  final double value;
  final String? subtitle;
  final Color color;

  const _Bar({
    required this.label,
    required this.value,
    this.subtitle,
    required this.color,
  });

  Color get _barColor {
    if (value > 85) return Colors.red.shade400;
    if (value > 60) return Colors.orange.shade400;
    return color;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
            const Spacer(),
            Text(
              subtitle ?? '${value.toStringAsFixed(0)}%',
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: (value / 100).clamp(0, 1),
            minHeight: 6,
            backgroundColor: Colors.white12,
            valueColor: AlwaysStoppedAnimation(_barColor),
          ),
        ),
      ],
    );
  }
}

class _TempBadge extends StatelessWidget {
  final double temp;
  const _TempBadge(this.temp);

  @override
  Widget build(BuildContext context) {
    final color = temp > 85
        ? Colors.red.shade400
        : temp > 70
        ? Colors.orange.shade400
        : Colors.white54;
    return Row(
      children: [
        Icon(Icons.thermostat, color: color, size: 14),
        Text(
          '${temp.toStringAsFixed(0)}°C',
          style: TextStyle(color: color, fontSize: 11),
        ),
      ],
    );
  }
}
