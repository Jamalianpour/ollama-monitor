import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

enum AuthState { loading, noPassword, loggedOut, loggedIn }

class AuthService extends ChangeNotifier {
  static const _tokenKey = 'auth_token';
  static const _hostKey  = 'backend_host';
  static const _portKey  = 'backend_port';

  String _host = 'localhost';
  int    _port = 12434;
  String _token = '';
  AuthState _state = AuthState.loading;
  String _error = '';

  String get host  => _host;
  int    get port  => _port;
  String get token => _token;
  AuthState get state => _state;
  String get error => _error;
  bool get isLoggedIn => _state == AuthState.loggedIn;

  String get baseUrl => 'http://$_host:$_port';

  // ── Initialise ────────────────────────────────────────────────────────────

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _host  = prefs.getString(_hostKey) ?? 'localhost';
    _port  = prefs.getInt(_portKey)    ?? 12434;
    _token = prefs.getString(_tokenKey) ?? '';

    await _checkStatus();
  }

  Future<void> _checkStatus() async {
    try {
      final resp = await http
          .get(Uri.parse('$baseUrl/api/auth/status'))
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

      // Password is set — validate stored token
      if (_token.isNotEmpty && await _validateToken()) {
        _state = AuthState.loggedIn;
      } else {
        _token = '';
        _state = AuthState.loggedOut;
      }
      notifyListeners();
    } catch (_) {
      // Backend unreachable — treat as logged out so user can configure host
      _state = AuthState.loggedOut;
      notifyListeners();
    }
  }

  Future<bool> _validateToken() async {
    try {
      final resp = await http.get(
        Uri.parse('$baseUrl/api/health'),
        headers: {'Authorization': 'Bearer $_token'},
      ).timeout(const Duration(seconds: 5));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ── Setup (first run) ────────────────────────────────────────────────────

  Future<bool> setupPassword(String password) async {
    _error = '';
    try {
      final resp = await http.post(
        Uri.parse('$baseUrl/api/auth/setup'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'password': password}),
      ).timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        final data = json.decode(resp.body) as Map<String, dynamic>;
        await _saveToken(data['token'] as String);
        _state = AuthState.loggedIn;
        notifyListeners();
        return true;
      }
      _error = _extractError(resp);
      notifyListeners();
      return false;
    } catch (e) {
      _error = 'Cannot reach backend at $baseUrl';
      notifyListeners();
      return false;
    }
  }

  // ── Login ────────────────────────────────────────────────────────────────

  Future<bool> login(String password) async {
    _error = '';
    try {
      final resp = await http.post(
        Uri.parse('$baseUrl/api/auth/login'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'password': password}),
      ).timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        final data = json.decode(resp.body) as Map<String, dynamic>;
        await _saveToken(data['token'] as String);
        _state = AuthState.loggedIn;
        notifyListeners();
        return true;
      }
      _error = _extractError(resp);
      notifyListeners();
      return false;
    } catch (e) {
      _error = 'Cannot reach backend at $baseUrl';
      notifyListeners();
      return false;
    }
  }

  // ── Logout ───────────────────────────────────────────────────────────────

  Future<void> logout() async {
    try {
      await http.post(
        Uri.parse('$baseUrl/api/auth/logout'),
        headers: {'Authorization': 'Bearer $_token'},
      ).timeout(const Duration(seconds: 5));
    } catch (_) {}
    await _clearToken();
    _state = AuthState.loggedOut;
    notifyListeners();
  }

  // ── Change password ──────────────────────────────────────────────────────

  Future<bool> changePassword(String current, String newPass) async {
    _error = '';
    try {
      final resp = await http.post(
        Uri.parse('$baseUrl/api/auth/change-password'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_token',
        },
        body: json.encode({'current_password': current, 'new_password': newPass}),
      ).timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        final data = json.decode(resp.body) as Map<String, dynamic>;
        await _saveToken(data['token'] as String);
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

  // ── Backend config ───────────────────────────────────────────────────────

  Future<void> configureBackend(String host, int port) async {
    _host = host;
    _port = port;
    _token = '';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_hostKey, host);
    await prefs.setInt(_portKey, port);
    await prefs.remove(_tokenKey);
    _state = AuthState.loading;
    notifyListeners();
    await _checkStatus();
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  Future<void> _saveToken(String token) async {
    _token = token;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
  }

  Future<void> _clearToken() async {
    _token = '';
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
  }

  String _extractError(http.Response resp) {
    try {
      final data = json.decode(resp.body) as Map<String, dynamic>;
      return data['detail'] as String? ?? 'Error ${resp.statusCode}';
    } catch (_) {
      return 'Error ${resp.statusCode}';
    }
  }
}
