import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/technician_model.dart';
import 'technician_data.dart';
import 'google_sheets_service.dart';

class TechnicianService {
  static const String _storageKey = 'technicians_data_v1';

  static final TechnicianService _instance = TechnicianService._internal();
  factory TechnicianService() => _instance;
  TechnicianService._internal();

  List<TechnicianModel> _technicians = [];

  List<TechnicianModel> get technicians => List.unmodifiable(_technicians);

  Future<void> loadTechnicians() async {
    final prefs = await SharedPreferences.getInstance();
    final String? dataJson = prefs.getString(_storageKey);
    
    if (dataJson != null) {
      final List<dynamic> decodedList = json.decode(dataJson);
      _technicians = decodedList.map((item) => TechnicianModel.fromJson(item)).toList();
    } else {
      _technicians = List.from(initialTechnicians);
      await _saveTechnicians();
    }
  }

  Future<void> _saveTechnicians() async {
    final prefs = await SharedPreferences.getInstance();
    final List<Map<String, dynamic>> mapList = _technicians.map((t) => t.toJson()).toList();
    await prefs.setString(_storageKey, json.encode(mapList));
  }

  Future<void> addTechnician(TechnicianModel technician) async {
    _technicians.add(technician);
    await _saveTechnicians();
    GoogleSheetsService().sendTechnician(technician, 'salvar_tecnico');
  }

  Future<void> updateTechnician(TechnicianModel updated) async {
    final index = _technicians.indexWhere((t) => t.id == updated.id);
    if (index != -1) {
      _technicians[index] = updated;
      await _saveTechnicians();
      GoogleSheetsService().sendTechnician(updated, 'salvar_tecnico');
    }
  }

  Future<void> deleteTechnician(String id) async {
    _technicians.removeWhere((t) => t.id == id);
    await _saveTechnicians();
    GoogleSheetsService().sendTechnician(
      TechnicianModel(id: id, name: '', registration: '', email: '', password: '', permissions: ''), 
      'deletar_tecnico'
    );
  }

  Future<void> syncTechniciansFromCloud() async {
    final cloudTechs = await GoogleSheetsService().fetchTechnicians();
    if (cloudTechs.isNotEmpty) {
      for (var cloud in cloudTechs) {
        final index = _technicians.indexWhere((t) => t.id == cloud.id || t.email == cloud.email);
        if (index != -1) {
          cloud.photoPath = _technicians[index].photoPath; // Preserva a foto local
          _technicians[index] = cloud;
        } else {
          _technicians.add(cloud);
        }
      }
      await _saveTechnicians();
    }
  }
}
