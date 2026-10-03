import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:signature/signature.dart';

class Tecnico {
  final String id;
  final String nome;

  Tecnico({required this.id, required this.nome});
}

class TesteAssinaturaScreen extends StatefulWidget {
  const TesteAssinaturaScreen({super.key});

  @override
  State<TesteAssinaturaScreen> createState() => _TesteAssinaturaScreenState();
}

class _TesteAssinaturaScreenState extends State<TesteAssinaturaScreen> {
  final List<Tecnico> _tecnicos = [];
  final List<SignatureController> _controllers = [];
  bool _isLoading = true;
  // Tipo de relatório local ao widget — evitar dependências externas/globais.
  String _tipoRelatorio = 'Análise Técnica';

  @override
  void initState() {
    super.initState();
    _loadTecnicos();
  }

  Future<void> _loadTecnicos() async {
    final lista = await _fetchTecnicos();
    // Atualiza o estado de forma consistente — primeiro dispose controllers antigos,
    // depois cria novos de acordo com a lista recebida.
    for (final controller in _controllers) {
      controller.dispose();
    }

    final novosControllers = List<SignatureController>.generate(
      lista.length,
      (_) => SignatureController(
        penStrokeWidth: 3,
        penColor: Colors.black,
        exportBackgroundColor: Colors.white,
      ),
    );

    setState(() {
      _tecnicos
        ..clear()
        ..addAll(lista);

      _controllers
        ..clear()
        ..addAll(novosControllers);

      _isLoading = false;
    });
  }

  Future<List<Tecnico>> _fetchTecnicos() async {
    await Future.delayed(const Duration(milliseconds: 250));
    return [
      Tecnico(id: '1', nome: 'Técnico A'),
      Tecnico(id: '2', nome: 'Técnico B'),
    ];
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _salvarTeste() async {
    if (_controllers.length != _tecnicos.length) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Erro interno: número de controladores não corresponde ao número de técnicos.')),
      );
      return;
    }

    final incompleteIndex = _controllers.indexWhere((controller) => controller.isEmpty);
    if (incompleteIndex != -1) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Assinatura pendente para ${_tecnicos[incompleteIndex].nome}. Por favor, assine todos os campos.'),
        ),
      );
      return;
    }

    for (var index = 0; index < _tecnicos.length; index++) {
      final controller = _controllers[index];
      final signatureBytes = await controller.toPngBytes();
      if (signatureBytes == null || signatureBytes.isEmpty) {
        continue;
      }
      final base64Signature = base64Encode(signatureBytes);
      debugPrint('Técnico ID=${_tecnicos[index].id} (${_tecnicos[index].nome}) assinatura base64: $base64Signature');
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Todas as assinaturas foram salvas com sucesso.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    print('Debug: Renderizando lista com ${_tecnicos.length} técnicos');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Teste de Assinaturas'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: ListView.builder(
                      key: ValueKey(_tecnicos.length),
                      itemCount: _tecnicos.length,
                      itemBuilder: (context, index) {
                        // Debug por item: confirma se o ListView está tentando renderizar todos os itens.
                        print('Debug: Renderizando ${_tecnicos.length} itens no ListView');

                        if (index < 0 || index >= _tecnicos.length) {
                          return const SizedBox.shrink();
                        }

                        final tecnico = _tecnicos[index];

                        // Debug visual solicitado: confirma nome do técnico e tipo de relatório.
                        final tipo = _tipoRelatorio;
                        print('Técnico: ${_tecnicos[index].nome} | Tipo de Relatório: [$tipo]');

                        // Validação de Análise Técnica: renderiza somente se for esse tipo.
                        if (tipo != 'Análise Técnica') {
                          // Não ocupar espaço caso não deva renderizar assinatura.
                          return const SizedBox.shrink();
                        }

                        // Garante que exista um controller correspondente; adiciona se necessário.
                        SignatureController controller;
                        if (index < _controllers.length) {
                          controller = _controllers[index];
                        } else {
                          controller = SignatureController(
                            penStrokeWidth: 3,
                            penColor: Colors.black,
                            exportBackgroundColor: Colors.white,
                          );
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) {
                              setState(() {
                                _controllers.add(controller);
                              });
                            }
                          });
                        }

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Card(
                              elevation: 2,
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      tecnico.nome,
                                      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                                    ),
                                    const SizedBox(height: 12),
                                    Signature(
                                      controller: controller,
                                      height: 180,
                                      backgroundColor: Colors.grey.shade200,
                                    ),
                                    const SizedBox(height: 12),
                                    ElevatedButton.icon(
                                      icon: const Icon(Icons.clear),
                                      label: const Text('Limpar'),
                                      onPressed: () {
                                        controller.clear();
                                        setState(() {});
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (index < _tecnicos.length - 1)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 8),
                                child: Divider(height: 1, thickness: 1),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.save),
                      label: const Text('Salvar Teste'),
                      onPressed: _salvarTeste,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
