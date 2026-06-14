import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One configured backend server (name + URL + auth token).
class BackendEntry {
  final String id;
  final String name;
  final String url; // e.g. http://192.168.1.10:8765
  final String token; // session token from this backend's /api/auth/login

  const BackendEntry({
    required this.id,
    required this.name,
    required this.url,
    this.token = '',
  });

  BackendEntry copyWith({String? name, String? token}) => BackendEntry(
    id: id,
    name: name ?? this.name,
    url: url,
    token: token ?? this.token,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'token': token,
  };

  factory BackendEntry.fromJson(Map<String, dynamic> j) => BackendEntry(
    id: j['id'] as String? ?? '',
    name: j['name'] as String? ?? 'Server',
    url: j['url'] as String? ?? '',
    token: j['token'] as String? ?? '',
  );

  // ── SharedPreferences helpers ──────────────────────────────────────────────
  static const _key = 'backends_v2';

  static Future<List<BackendEntry>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      final list = json.decode(raw) as List;
      return list
          .map((j) => BackendEntry.fromJson(j as Map<String, dynamic>))
          .toList();
    }
    // Migrate from single-backend format (host + port + auth_token keys)
    final host = prefs.getString('backend_host') ?? 'localhost';
    final port = prefs.getInt('backend_port') ?? 12434;
    final token = prefs.getString('auth_token') ?? '';
    return [
      BackendEntry(
        id: 'default',
        name: 'Default',
        url: 'http://$host:$port',
        token: token,
      ),
    ];
  }

  static Future<void> saveAll(List<BackendEntry> backends) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      json.encode(backends.map((b) => b.toJson()).toList()),
    );
  }
}
