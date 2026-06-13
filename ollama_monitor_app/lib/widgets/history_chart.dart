import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

/// Scrolling line chart for CPU / RAM history.
class HistoryChart extends StatelessWidget {
  final String label;
  final List<double> data; // values 0–100
  final Color color;

  const HistoryChart({
    super.key,
    required this.label,
    required this.data,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final spots = data.asMap().entries.map((e) => FlSpot(e.key.toDouble(), e.value)).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(color: Colors.white70)),
            const SizedBox(height: 12),
            SizedBox(
              height: 100,
              child: spots.isEmpty
                  ? const Center(
                      child: Text('No data yet', style: TextStyle(color: Colors.white38)))
                  : LineChart(
                      LineChartData(
                        minY: 0,
                        maxY: 100,
                        gridData: FlGridData(
                          show: true,
                          drawVerticalLine: false,
                          horizontalInterval: 25,
                          getDrawingHorizontalLine: (_) => FlLine(
                            color: Colors.white10,
                            strokeWidth: 1,
                          ),
                        ),
                        titlesData: FlTitlesData(
                          leftTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: 32,
                              interval: 25,
                              getTitlesWidget: (v, _) => Text(
                                '${v.toInt()}%',
                                style: const TextStyle(
                                    color: Colors.white38, fontSize: 10),
                              ),
                            ),
                          ),
                          rightTitles:
                              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                          topTitles:
                              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                          bottomTitles:
                              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        ),
                        borderData: FlBorderData(show: false),
                        lineBarsData: [
                          LineChartBarData(
                            spots: spots,
                            isCurved: true,
                            color: color,
                            barWidth: 2,
                            dotData: const FlDotData(show: false),
                            belowBarData: BarAreaData(
                              show: true,
                              color: color.withOpacity(0.15),
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
