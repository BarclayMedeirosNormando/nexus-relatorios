import '../utils/text_encoding.dart';

class SchoolModel {
  final String id;
  final String inep;
  final String name;
  final String address;
  final String city;
  final String uf;
  final String gre;

  SchoolModel({
    required this.id,
    required this.inep,
    required this.name,
    required this.address,
    required this.city,
    required this.uf,
    required this.gre,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'inep': inep,
      'name': name,
      'address': address,
      'city': city,
      'uf': uf,
      'gre': gre,
    };
  }

  factory SchoolModel.fromJson(Map<String, dynamic> json) {
    return SchoolModel(
      id: fixMojibake(json['id']?.toString() ?? ''),
      inep: fixMojibake(json['inep']?.toString() ?? ''),
      name: fixMojibake((json['name'] ?? json['nome'])?.toString() ?? ''),
      address: fixMojibake((json['address'] ?? json['endereco'])?.toString() ?? ''),
      city: fixMojibake((json['city'] ?? json['municipio'])?.toString() ?? ''),
      uf: fixMojibake(json['uf']?.toString() ?? ''),
      gre: fixMojibake(json['gre']?.toString() ?? ''),
    );
  }
}
