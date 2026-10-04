import 'local_store.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import '../models/employee_model.dart';
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

  /// Inicializa o serviço: carrega o cache local e atualiza pelo servidor.
  /// A lista de funcionários NÃO vem mais embutida no app: ela é baixada da
  /// planilha (aba Funcionarios) e guardada no aparelho para uso offline.
  /// Chamar uma vez no login ou na abertura do app.
  Future<void> initialize() async {
    if (_loaded) return;
    // 1) Tenta carregar do cache local primeiro para resposta imediata
    await _loadFromCache();
    // 2) Atualiza em background com dados do Sheets
    _refreshFromSheets();
  }

  /// Retorna a lista guardada no aparelho (vazia até o primeiro download).
  List<EmployeeModel> get all => _employees;

  /// Busca para os campos de "Responsável": usa a lista do aparelho (funciona
  /// offline) e, se ela ainda não existir, pergunta ao servidor (limite 15).
  Future<List<EmployeeModel>> search(String query) async {
    final q = query.trim();
    if (q.length < 2) return [];

    if (_employees.isNotEmpty) {
      if (RegExp(r'^\d+$').hasMatch(q)) {
        final res = _employees.where((e) => e.matricula.startsWith(q)).take(15).toList();
        res.sort((a, b) {
          if (a.matricula == q) return -1;
          if (b.matricula == q) return 1;
          return a.matricula.compareTo(b.matricula);
        });
        return res;
      }
      return searchByName(q).take(15).toList();
    }

    // Lista ainda não baixada: busca sob demanda no servidor.
    try {
      final rows = await GoogleSheetsService().fetchFuncionarios(q: q, limit: 15);
      return rows
          .map((e) => EmployeeModel(matricula: e['matricula'] ?? '', name: e['nome'] ?? ''))
          .toList();
    } catch (e) {
      debugPrint('Erro na busca remota de funcionários: $e');
      return [];
    }
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
      final raw = await LocalStore.getString(_cacheKey);
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
      await LocalStore.setString(
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
