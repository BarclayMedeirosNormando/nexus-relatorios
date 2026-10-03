import 'dart:convert';

/// Utility class providing safe extraction and conversion of JSON values.
/// These methods mirror the previously inlined helpers and are used across
/// the codebase to avoid unsafe casts like `as String?` or `as List<String>`.
class JsonUtils {
  /// Returns a non‑null [String] from any value.
  /// Numbers and booleans are converted to their string representation.
  /// If the value is a list, its elements are joined by commas.
  static String asString(dynamic value) {
    if (value == null) return '';
    if (value is String) return value;
    if (value is num || value is bool) return value.toString();
    if (value is List) {
      return value.map((e) => asString(e)).join(',');
    }
    if (value is Map) {
      return jsonEncode(value);
    }
    return value.toString();
  }

  /// Returns a nullable [String] from any value. Returns null for empty strings.
  static String? asNullableString(dynamic value) {
    final str = asString(value).trim();
    return str.isEmpty ? null : str;
  }

  /// Returns a list of strings from various possible input formats.
  /// Handles `List<String>`, `List<dynamic>`, a comma/semicolon/line‑break separated
  /// string, a JSON‑encoded list, or a single scalar value.
  static List<String> asStringList(dynamic value) {
    if (value == null) return [];
    if (value is List) {
      return value.map((e) => asString(e).trim()).where((e) => e.isNotEmpty).toList();
    }
    final str = asString(value).trim();
    if (str.isEmpty) return [];
    // JSON list?
    if (str.startsWith('[') && str.endsWith(']')) {
      try {
        final decoded = jsonDecode(str);
        if (decoded is List) {
          return decoded.map((e) => asString(e).trim()).where((e) => e.isNotEmpty).toList();
        }
      } catch (_) {}
    }
    // Split by common delimiters
    return str.split(RegExp(r',|;|\n')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  }

  /// Returns a map with string keys and dynamic values from any input.
  /// If given a Map, it is cast to `Map<String, dynamic>`. If given a JSON string,
  /// it is decoded. Otherwise returns an empty map.
  static Map<String, dynamic> asStringDynamicMap(dynamic value) {
    if (value == null) return {};
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    final str = asString(value).trim();
    if (str.isEmpty) return {};
    try {
      final decoded = jsonDecode(str);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return {};
  }
}
