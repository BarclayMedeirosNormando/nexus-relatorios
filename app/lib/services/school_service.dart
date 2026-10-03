import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/school_model.dart';

import 'google_sheets_service.dart';
// ignore: uri_does_not_exist
import 'school_data.dart';

class SchoolService {
  static const String _storageKey = 'schools_data_v2';

  // Sigleton pattern
  static final SchoolService _instance = SchoolService._internal();
  factory SchoolService() => _instance;
  SchoolService._internal();

  List<SchoolModel> _schools = [];

  List<SchoolModel> get schools => List.unmodifiable(_schools);

  Future<void> loadSchools({bool forceRefresh = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final String? schoolsJson = prefs.getString(_storageKey);

    if (!forceRefresh && schoolsJson != null) {
      final List<dynamic> decodedList = json.decode(schoolsJson);
      _schools = decodedList.map((item) => SchoolModel.fromJson(item)).toList();
    }

    if (forceRefresh || _schools.isEmpty) {
      try {
        final cloudSchools = await GoogleSheetsService().fetchSchools();
        if (cloudSchools.isNotEmpty) {
          _schools = cloudSchools;
          await _saveSchools();
        }
      } catch (_) {}
    }

    // Se não há dados no cache (primeira execução ou forceRefresh), usa a lista embutida
    if (_schools.isEmpty) {
      try {
        // ignore: undefined_identifier
        _schools = List<SchoolModel>.from(initialSchools);
        await _saveSchools();
      } catch (_) {
        // school_data.dart não disponível — lista permanece vazia
      }
    }
  }

  Future<void> _saveSchools() async {
    final prefs = await SharedPreferences.getInstance();
    final List<Map<String, dynamic>> mapList = _schools.map((s) => s.toJson()).toList();
    await prefs.setString(_storageKey, json.encode(mapList));
  }

  Future<void> addSchool(SchoolModel school) async {
    _schools.add(school);
    await _saveSchools();
    GoogleSheetsService().sendSchool(school, 'salvar_escola');
  }

  Future<void> updateSchool(SchoolModel updatedSchool) async {
    final index = _schools.indexWhere((s) => s.id == updatedSchool.id);
    if (index != -1) {
      _schools[index] = updatedSchool;
      await _saveSchools();
      GoogleSheetsService().sendSchool(updatedSchool, 'salvar_escola');
    }
  }

  Future<void> deleteSchool(String id) async {
    _schools.removeWhere((s) => s.id == id);
    await _saveSchools();
    GoogleSheetsService().sendSchool(
      SchoolModel(id: id, inep: '', name: '', address: '', city: '', uf: '', gre: ''), 
      'deletar_escola'
    );
  }

  Future<void> loadSchoolsIfNeeded() async {
    if (_schools.isEmpty) {
      await loadSchools();
    }
  }
}
