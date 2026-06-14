import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/backend_entry.dart';

export '../models/backend_entry.dart' show BackendEntry;

enum AuthState { loading, noPassword, loggedOut, loggedIn }

class AuthService extends ChangeNotifier {
  List<BackendEntry> _backends = [];
  AuthState _state = AuthState.loading;
  String _error = '';

  // ── Public getters ──────────────────────────────────────────────────────────

  AuthState get state => _state;
  String get error => _error;
  bool get isLoggedIn => _state == AuthState.loggedIn;

  /// All backends that have valid tokens (ready for MonitorService to use).
  List<BackendEntry> get allBackends =>
      _backends.where((b) => b.token.isNotEmpty).toList();

  /// Every configured backend including those without tokens yet.
  List<BackendEntry> get backends => List.unmodifiable(_backends);

  BackendEntry? get _primary => _backends.isNotEmpty ? _backends.first : null;

  String get primaryUrl => _primary?.url ?? 'http://localhost:12434';
  String get baseUrl => primaryUrl; // backward compat alias

  // Parsed from primaryUrl for backward compat
  String get host => Uri.parse(primaryUrl).host;
  int get port => Uri.parse(primaryUrl).port;
  String get token => _primary?.token ?? '';

  // ── Init ────────────────────────────────────────────────────────────────────

  Future<void> init() async {
    _backends = await BackendEntry.loadAll();
    await _checkStatus();
  }

  Future<void> _checkStatus() async {
    try {
      final resp = await http
          .get(Uri.parse('$primaryUrl/api/auth/status'))
          .timeout(const Duration(seconds: 5));

      if (resp.statusCode != 200) {
        _state = AuthState.loggedOut;
        notifyListeners();
        return;
      }

      final data = json.decode(resp.body) as Map<String, dynamic>;
      final passwordSet = data['password_set'] as bool? ?? false;

      if (!passwordSet) {
        _state = AuthState.noPassword;
        notifyListeners();
        return;
      }

      final tok = token;
      if (tok.isNotEmpty && await _validateToken(primaryUrl, tok)) {
        _state = AuthState.loggedIn;
      } else {
        _clearAllTokens();
        _state = AuthState.loggedOut;
      }
      notifyListeners();
    } catch (_) {
      _state = AuthState.loggedOut;
      notifyListeners();
    }
  }

  Future<bool> _validateToken(String url, String tok) async {
    try {
      final resp = await http
          .get(
            Uri.parse('$url/api/health'),
            headers: {'Authorization': 'Bearer $tok'},
          )
          .timeout(const Duration(seconds: 5));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  void _clearAllTokens() {
    _backends = _backends.map((b) => b.copyWith(token: '')).toList();
    BackendEntry.saveAll(_backends);
  }

  // ── Setup (first run) ───────────────────────────────────────────────────────

  Future<bool> setupPassword(String password) async {
    _error = '';
    try {
      final resp = await http
          .post(
            Uri.parse('$primaryUrl/api/auth/setup'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({'password': password}),
          )
          .timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        final data = json.decode(resp.body) as Map<String, dynamic>;
        final newTok = data['token'] as String;
        _backends = [
          if (_backends.isNotEmpty) _backends.first.copyWith(token: newTok),
          ..._backends.skip(1),
        ];
        await BackendEntry.saveAll(_backends);
        _state = AuthState.loggedIn;
        notifyListeners();
        return true;
      }
      _error = _extractError(resp);
      notifyListeners();
      return false;
    } catch (_) {
      _error = 'Cannot reach backend at $primaryUrl';
      notifyListeners();
      return false;
    }
  }

  // ── Login ───────────────────────────────────────────────────────────────────

  Future<bool> login(String password) async {
    _error = '';
    bool primaryOk = false;
    final updated = <BackendEntry>[];

    for (var i = 0; i < _backends.length; i++) {
      final backend = _backends[i];
      try {
        final resp = await http
            .post(
              Uri.parse('${backend.url}/api/auth/login'),
              headers: {'Content-Type': 'application/json'},
              body: json.encode({'password': password}),
            )
            .timeout(const Duration(seconds: 10));

        if (resp.statusCode == 200) {
          final data = json.decode(resp.body) as Map<String, dynamic>;
          updated.add(backend.copyWith(token: data['token'] as String));
          if (i == 0) primaryOk = true;
        } else {
          updated.add(backend);
          if (i == 0) _error = _extractError(resp);
        }
      } catch (_) {
        updated.add(backend);
        if (i == 0) _error = 'Cannot reach backend at ${backend.url}';
      }
    }

    if (primaryOk) {
      _backends = updated;
      await BackendEntry.saveAll(_backends);
      _state = AuthState.loggedIn;
      notifyListeners();
      return true;
    }
    notifyListeners();
    return false;
  }

  // ── Logout ──────────────────────────────────────────────────────────────────

  Future<void> logout() async {
    // Best-effort logout on all backends
    await Future.wait(
      _backends
          .where((b) => b.token.isNotEmpty)
          .map(
            (b) => http
                .post(
                  Uri.parse('${b.url}/api/auth/logout'),
                  headers: {'Authorization': 'Bearer ${b.token}'},
                )
                .timeout(const Duration(seconds: 3))
                .catchError((_) => http.Response('', 503)),
          ),
    );
    _clearAllTokens();
    _state = AuthState.loggedOut;
    notifyListeners();
  }

  // ── Change password ─────────────────────────────────────────────────────────

  Future<bool> changePassword(String current, String newPass) async {
    _error = '';
    try {
      final resp = await http
          .post(
            Uri.parse('$primaryUrl/api/auth/change-password'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: json.encode({
              'current_password': current,
              'new_password': newPass,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        final data = json.decode(resp.body) as Map<String, dynamic>;
        final newToken = data['token'] as String;
        _backends = [
          if (_backends.isNotEmpty) _backends.first.copyWith(token: newToken),
          ..._backends.skip(1),
        ];
        await BackendEntry.saveAll(_backends);
        notifyListeners();
        return true;
      }
      _error = _extractError(resp);
      notifyListeners();
      return false;
    } catch (e) {
      _error = 'Request failed: $e';
      notifyListeners();
      return false;
    }
  }

  // ── Backend management ──────────────────────────────────────────────────────

  /// Add and authenticate a new backend.  Returns true on success.
  Future<bool> addBackend(String name, String url, String password) async {
    _error = '';
    final cleanUrl = url.trimRight().replaceAll(RegExp(r'/$'), '');
    try {
      final resp = await http
          .post(
            Uri.parse('$cleanUrl/api/auth/login'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({'password': password}),
          )
          .timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        final data = json.decode(resp.body) as Map<String, dynamic>;
        final id = 'b${DateTime.now().millisecondsSinceEpoch}';
        _backends = [
          ..._backends,
          BackendEntry(
            id: id,
            name: name,
            url: cleanUrl,
            token: data['token'] as String,
          ),
        ];
        await BackendEntry.saveAll(_backends);
        notifyListeners();
        return true;
      }
      _error = _extractError(resp);
      notifyListeners();
      return false;
    } catch (_) {
      _error = 'Cannot reach $cleanUrl';
      notifyListeners();
      return false;
    }
  }

  /// Remove a backend by id.  The primary (first) backend cannot be removed.
  Future<void> removeBackend(String id) async {
    if (_backends.isEmpty || _backends.first.id == id) return;
    _backends = _backends.where((b) => b.id != id).toList();
    await BackendEntry.saveAll(_backends);
    notifyListeners();
  }

  /// Update the primary backend URL and re-check auth status.
  Future<void> configurePrimaryUrl(String url) async {
    final cleanUrl = url.trimRight().replaceAll(RegExp(r'/$'), '');
    if (_backends.isEmpty) {
      _backends = [BackendEntry(id: 'default', name: 'Default', url: cleanUrl)];
    } else {
      _backends = [
        BackendEntry(
          id: _backends.first.id,
          name: _backends.first.name,
          url: cleanUrl,
        ),
        ..._backends.skip(1),
      ];
    }
    await BackendEntry.saveAll(_backends);
    _clearAllTokens();
    _state = AuthState.loading;
    notifyListeners();
    await _checkStatus();
  }

  /// Backward-compat wrapper used by the old host:port config UI.
  Future<void> configureBackend(String host, int port) =>
      configurePrimaryUrl('http://$host:$port');

  // ── Helpers ─────────────────────────────────────────────────────────────────

  String _extractError(http.Response resp) {
    try {
      final data = json.decode(resp.body) as Map<String, dynamic>;
      return data['detail'] as String? ?? 'Error ${resp.statusCode}';
    } catch (_) {
      return 'Error ${resp.statusCode}';
    }
  }
}
