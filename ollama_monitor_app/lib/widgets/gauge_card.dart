import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

/// A card with a radial gauge showing a percentage value.
class GaugeCard extends StatelessWidget {
  final String label;
  final double value; // 0–100
  final String subtitle;
  final Color color;

  const GaugeCard({
    super.key,
    required this.label,
    required this.value,
    required this.subtitle,
    required this.color,
  });

  Color get _gaugeColor {
    if (value > 85) return Colors.red.shade400;
    if (value > 60) return Colors.orange.shade400;
    return color;
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 120,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  PieChart(
                    PieChartData(
                      startDegreeOffset: -90,
                      sectionsSpace: 0,
                      centerSpaceRadius: 40,
                      sections: [
                        PieChartSectionData(
                          value: value,
                          color: _gaugeColor,
                          radius: 18,
                          showTitle: false,
                        ),
                        PieChartSectionData(
                          value: 100 - value,
                          color: Colors.white12,
                          radius: 18,
                          showTitle: false,
                        ),
                      ],
                    ),
                  ),
                  Text(
                    '${value.toStringAsFixed(0)}%',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: _gaugeColor,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }
}
