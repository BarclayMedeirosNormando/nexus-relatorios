class EmployeeModel {
  final String matricula;
  final String name;

  EmployeeModel({
    required this.matricula,
    required this.name,
  });

  Map<String, dynamic> toJson() {
    return {
      'matricula': matricula,
      'name': name,
    };
  }

  factory EmployeeModel.fromJson(Map<String, dynamic> json) {
    return EmployeeModel(
      matricula: json['matricula']?.toString() ?? '',
      name: json['name']?.toString() ?? json['nome']?.toString() ?? '',
    );
  }
}
