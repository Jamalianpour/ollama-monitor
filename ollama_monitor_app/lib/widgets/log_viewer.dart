import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../models/monitor_state.dart';

class LogViewer extends StatefulWidget {
  final List<LogLine> logs;
  final List<Map<String, dynamic>> logFiles;

  const LogViewer({super.key, required this.logs, required this.logFiles});

  @override
  State<LogViewer> createState() => _LogViewerState();
}

class _LogViewerState extends State<LogViewer> {
  final ScrollController _scroll = ScrollController();
  bool _autoScroll = true;
  String _filter = '';
  String? _sourceFilter; // null = all, 'server', 'app'

  @override
  void didUpdateWidget(LogViewer old) {
    super.didUpdateWidget(old);
    if (_autoScroll) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  Set<String> get _availableSources => widget.logs.map((l) => l.source).toSet();

  List<LogLine> get _filtered {
    return widget.logs.where((l) {
      if (_sourceFilter != null && l.source != _sourceFilter) {
        return false;
      }
      if (_filter.isNotEmpty &&
          !l.text.toLowerCase().contains(_filter.toLowerCase())) {
        return false;
      }
      return true;
    }).toList();
  }

  Color _levelColor(LogLine line) {
    if (line.isError) return Colors.red.shade300;
    if (line.isWarn) return Colors.orange.shade300;
    if (line.isDebug) return Colors.white38;
    return Colors.white70;
  }

  Color _sourceColor(String source) =>
      source == 'app' ? Colors.tealAccent.shade200 : Colors.blueAccent.shade100;

  @override
  Widget build(BuildContext context) {
    final sources = _availableSources;
    final filtered = _filtered;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ───────────────────────────────────────────────────────
            Row(
              children: [
                const Icon(
                  Icons.article_outlined,
                  color: Colors.amber,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text(
                  'Logs',
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(color: Colors.white70),
                ),
                const SizedBox(width: 12),
                // Log file paths
                Expanded(
                  child: Text(
                    widget.logFiles.isEmpty
                        ? 'no log files found'
                        : widget.logFiles
                              .map((f) => f['path'] as String? ?? '')
                              .join('  •  '),
                    style: const TextStyle(color: Colors.white24, fontSize: 10),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // Auto-scroll toggle
                const Text(
                  'Auto-scroll',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
                Switch(
                  value: _autoScroll,
                  onChanged: (v) => setState(() => _autoScroll = v),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ],
            ),

            // ── Source filter chips (only when >1 source exists) ─────────────
            if (sources.length > 1) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  _SourceChip(
                    label: 'ALL',
                    selected: _sourceFilter == null,
                    onTap: () => setState(() => _sourceFilter = null),
                  ),
                  const SizedBox(width: 6),
                  for (final src in sources) ...[
                    _SourceChip(
                      label: src.toUpperCase(),
                      selected: _sourceFilter == src,
                      color: _sourceColor(src),
                      onTap: () => setState(() => _sourceFilter = src),
                    ),
                    const SizedBox(width: 6),
                  ],
                ],
              ),
            ],

            const SizedBox(height: 8),

            // ── Filter input ─────────────────────────────────────────────────
            TextField(
              onChanged: (v) => setState(() => _filter = v),
              style: const TextStyle(color: Colors.white, fontSize: 12),
              decoration: InputDecoration(
                hintText: 'Filter logs…',
                hintStyle: const TextStyle(color: Colors.white38, fontSize: 12),
                prefixIcon: const Icon(
                  Icons.search,
                  color: Colors.white38,
                  size: 16,
                ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  vertical: 8,
                  horizontal: 12,
                ),
                filled: true,
                fillColor: Colors.white10,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),

            const SizedBox(height: 8),

            // ── Log list ──────────────────────────────────────────────────────
            SizedBox(
              height: 300,
              child: filtered.isEmpty
                  ? const Center(
                      child: Text(
                        'No log lines',
                        style: TextStyle(color: Colors.white38),
                      ),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      itemCount: filtered.length,
                      itemBuilder: (context, i) {
                        final line = filtered[i];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Source badge (only when multiple sources)
                              if (sources.length > 1) ...[
                                Container(
                                  width: 30,
                                  margin: const EdgeInsets.only(
                                    right: 6,
                                    top: 1,
                                  ),
                                  child: SelectableText(
                                    line.source == 'app' ? 'app' : 'srv',
                                    style: TextStyle(
                                      fontSize: 9,
                                      color: _sourceColor(line.source),
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ),
                              ],
                              Expanded(
                                child: SelectableText(
                                  line.text,
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                    color: _levelColor(line),
                                    height: 1.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceChip extends StatelessWidget {
  final String label;
  final bool selected;
  final Color? color;
  final VoidCallback onTap;

  const _SourceChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final fg = color ?? Colors.white70;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: selected ? fg.withValues(alpha: 0.15) : Colors.transparent,
          border: Border.all(color: selected ? fg : Colors.white24),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: selected ? fg : Colors.white38,
          ),
        ),
      ),
    );
  }
}
