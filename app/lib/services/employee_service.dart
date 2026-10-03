import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/employee_model.dart';
import 'employee_data.dart';
import 'google_sheets_service.dart';

class EmployeeService {
  // Singleton pattern
  static final EmployeeService _instance = EmployeeService._internal();
  factory EmployeeService() => _instance;
  EmployeeService._internal();

  static const String _cacheKey = 'cached_funcionarios';

  // Lista em memória — carregada ao iniciar
  List<EmployeeModel> _employees = [];
  bool _loaded = false;

  /// Inicializa o serviço: tenta buscar do Sheets e faz fallback no estático.
  /// Chamar uma vez no login ou na abertura do app.
  Future<void> initialize() async {
    if (_loaded) return;
    // 1) Tenta carregar do cache local primeiro para resposta imediata
    await _loadFromCache();
    // 2) Atualiza em background com dados do Sheets
    _refreshFromSheets();
  }

  /// Retorna todos os funcionários (estático como fallback inicial)
  List<EmployeeModel> get all {
    if (_employees.isEmpty) return allEmployees; // fallback estático
    return _employees;
  }

  /// Busca funcionários pelo nome (case-insensitive, parcial, sem acento)
  List<EmployeeModel> searchByName(String query) {
    if (query.trim().isEmpty) return [];
    final q = _normalize(query);
    return all.where((e) => _normalize(e.name).contains(q)).toList();
  }

  /// Busca funcionário pela matrícula exata
  EmployeeModel? findByMatricula(String matricula) {
    try {
      return all.firstWhere((e) => e.matricula == matricula.trim());
    } catch (_) {
      return null;
    }
  }

  // --------------------------------------------------------------------------
  // Internos
  // --------------------------------------------------------------------------

  Future<void> _loadFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw != null && raw.isNotEmpty) {
        final List decoded = jsonDecode(raw);
        _employees = decoded
            .map((e) => EmployeeModel(
                  matricula: e['matricula'] ?? '',
                  name: e['nome'] ?? '',
                ))
            .toList();
        _loaded = _employees.isNotEmpty;
      }
    } catch (e) {
      debugPrint('Erro ao carregar cache de funcionários: $e');
    }
  }

  Future<void> _refreshFromSheets() async {
    try {
      final data = await GoogleSheetsService().fetchFuncionarios();
      if (data.isEmpty) return;
      _employees = data
          .map((e) => EmployeeModel(
                matricula: e['matricula'] ?? '',
                name: e['nome'] ?? '',
              ))
          .toList();
      _loaded = true;
      // Persiste no cache local
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _cacheKey,
        jsonEncode(data),
      );
    } catch (e) {
      debugPrint('Erro ao atualizar funcionários do Sheets: $e');
    }
  }

  /// Normaliza string removendo acentos e convertendo para minúsculas
  String _normalize(String s) {
    const from = 'àáâãäåæçèéêëìíîïðñòóôõöùúûüýÿÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖÙÚÛÜÝ';
    const to   = 'aaaaaaaceeeeiiiidnoooooouuuuyyAAAAAAAACEEEEIIIIDNOOOOOUUUUY';
    var result = s.toLowerCase();
    for (int i = 0; i < from.length; i++) {
      result = result.replaceAll(from[i], to[i]);
    }
    return result;
  }
}
