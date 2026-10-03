import '../utils/text_encoding.dart';

class TechnicianModel {
  String id;
  String name;
  String registration;
  String email;
  String permissions;
  String? photoPath;
  String? password;

  TechnicianModel({
    required this.id,
    required this.name,
    required this.registration,
    required this.email,
    required this.permissions,
    this.photoPath,
    this.password,
  });

  factory TechnicianModel.fromJson(Map<String, dynamic> json) {
    return TechnicianModel(
      id: fixMojibake(json['id']?.toString() ?? ''),
      name: fixMojibake(json['name']?.toString() ?? ''),
      registration: fixMojibake(json['registration']?.toString() ?? ''),
      email: fixMojibake(json['email']?.toString() ?? ''),
      permissions: fixMojibake(json['permissions']?.toString() ?? 'USR'),
      photoPath: json['photoPath'] == null ? null : fixMojibake(json['photoPath'].toString()),
      password: json['password']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'registration': registration,
      'email': email,
      'permissions': permissions,
      'photoPath': photoPath,
      'password': password,
    };
  }
}
