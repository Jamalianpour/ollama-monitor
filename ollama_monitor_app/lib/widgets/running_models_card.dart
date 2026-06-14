import 'package:flutter/material.dart';

import '../models/monitor_state.dart';

class RunningModelsCard extends StatelessWidget {
  final List<RunningModel> models;

  const RunningModelsCard({super.key, required this.models});

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
                const Icon(Icons.memory, color: Colors.greenAccent, size: 18),
                const SizedBox(width: 8),
                Text('Running Models',
                    style: Theme.of(context)
                        .textTheme
                        .labelLarge
                        ?.copyWith(color: Colors.white70)),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: models.isEmpty ? Colors.white12 : Colors.greenAccent.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${models.length} active',
                    style: TextStyle(
                      fontSize: 11,
                      color: models.isEmpty ? Colors.white38 : Colors.greenAccent,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (models.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: Text('No models currently loaded',
                      style: TextStyle(color: Colors.white38)),
                ),
              )
            else
              ...models.map((m) => _ModelRow(model: m)),
          ],
        ),
      ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  final RunningModel model;
  const _ModelRow({required this.model});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          // Active indicator dot
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: Colors.greenAccent,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  model.shortName,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600),
                ),
                Text(
                  'tag: ${model.tag}  •  ${model.sizeGb.toStringAsFixed(1)} GB',
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ],
            ),
          ),
          // Chip for family/quantization
          if (model.details['quantization_level'] != null)
            _Chip(model.details['quantization_level'] as String),
          if (model.details['family'] != null)
            _Chip(model.details['family'] as String),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  const _Chip(this.label);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label,
          style: const TextStyle(fontSize: 10, color: Colors.white54)),
    );
  }
}
