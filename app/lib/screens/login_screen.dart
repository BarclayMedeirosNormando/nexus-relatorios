import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../widgets/custom_text_field.dart';
import '../services/technician_service.dart';
import '../services/google_sheets_service.dart';
import '../services/employee_service.dart';
import '../services/offline_auth.dart';
import '../services/apps_script_client.dart';
import '../models/technician_model.dart';
import '../widgets/app_ui.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  // Versão lida em tempo de execução a partir do pubspec.yaml (via
  // package_info_plus), eliminando a duplicação manual que existia antes.
  String appVersion = '';

  // No PWA o login é validado no servidor (a senha não fica no navegador).
  // Android/Windows mantêm o comportamento atual. Para forçar:
  //   --dart-define=SERVER_LOGIN=true
  static const bool _serverLogin =
      bool.fromEnvironment('SERVER_LOGIN', defaultValue: kIsWeb);

  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _loadAppVersionAndCheckUpdate();
  }

  Future<void> _loadAppVersionAndCheckUpdate() async {
    try {
      final info = await PackageInfo.fromPlatform();
      appVersion = info.version;
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Erro ao obter a versão do app via PackageInfo: $e');
    }
    _checkUpdate();
  }

  String _currentPlatformKey() {
    if (kIsWeb) return 'web';
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    if (Platform.isIOS) return 'ios';
    return 'unknown';
  }

  String _platformDisplayName() {
    final key = _currentPlatformKey();
    switch (key) {
      case 'android':
        return 'Android';
      case 'windows':
        return 'Windows';
      case 'web':
        return 'Web';
      case 'macos':
        return 'macOS';
      case 'linux':
        return 'Linux';
      case 'ios':
        return 'iOS';
      default:
        return 'Plataforma desconhecida';
    }
  }

  String normalizeDriveDownloadLink(String link) {
    String trimmed = link.trim();
    if (trimmed.isEmpty) return '';

    if (trimmed.contains('drive.google.com')) {
      String fileId = '';

      // Caso 1: /file/d/FILE_ID/view... ou /file/d/FILE_ID/...
      if (trimmed.contains('/file/d/')) {
        final parts = trimmed.split('/file/d/');
        if (parts.length > 1) {
          final subParts = parts[1].split('/');
          if (subParts.isNotEmpty) {
            fileId = subParts[0].split('?')[0];
          }
        }
      }
      // Caso 2: open?id=FILE_ID ou uc?id=FILE_ID ou uc?export=download&id=FILE_ID
      else if (trimmed.contains('id=')) {
        try {
          final uri = Uri.parse(trimmed);
          fileId = uri.queryParameters['id'] ?? '';
        } catch (_) {
          final parts = trimmed.split('id=');
          if (parts.length > 1) {
            fileId = parts[1].split('&')[0];
          }
        }
      }

      if (fileId.isNotEmpty) {
        return 'https://drive.google.com/uc?export=download&id=$fileId';
      }
    }

    return trimmed;
  }

  Map<String, String> _resolveUpdateInfo(Map<String, dynamic> decoded) {
    final platformKey = _currentPlatformKey();
    String requiredVersion = '';
    String downloadLink = '';

    // 1. Tentar primeiro formato por objeto: decoded[platformKey]['versao'], decoded[platformKey]['link']
    if (decoded[platformKey] is Map) {
      final platformObj = decoded[platformKey] as Map;
      requiredVersion = platformObj['versao']?.toString().trim() ?? '';
      downloadLink = platformObj['link']?.toString().trim() ?? '';
    }

    // 2. Se não existir, tentar formato simples: decoded['versao_$platformKey'], decoded['link_$platformKey']
    if (requiredVersion.isEmpty) {
      requiredVersion = decoded['versao_$platformKey']?.toString().trim() ?? '';
    }
    if (downloadLink.isEmpty) {
      downloadLink = decoded['link_$platformKey']?.toString().trim() ?? '';
    }

    // 3. Se não existir, usar fallback antigo: decoded['versao'], decoded['link']
    if (requiredVersion.isEmpty) {
      requiredVersion = decoded['versao']?.toString().trim() ?? '';
    }
    if (downloadLink.isEmpty) {
      final fallbackLink = decoded['link']?.toString().trim() ?? '';
      if (platformKey == 'windows') {
        final lowerLink = fallbackLink.toLowerCase();
        if (lowerLink.endsWith('.apk') || lowerLink.contains('apk')) {
          downloadLink = '';
        } else {
          downloadLink = fallbackLink;
        }
      } else {
        downloadLink = fallbackLink;
      }
    }

    // 4. Se houver 'versao' global e link específico
    if (requiredVersion.isEmpty) {
      requiredVersion = decoded['versao']?.toString().trim() ?? '';
    }

    // Normalizar link do Google Drive se aplicável
    downloadLink = normalizeDriveDownloadLink(downloadLink);

    return {
      'requiredVersion': requiredVersion,
      'downloadLink': downloadLink,
    };
  }

  bool _isVersionLower(String currentVersion, String requiredVersion) {
    try {
      final currentParts = currentVersion.split('.').map(int.parse).toList();
      final requiredParts = requiredVersion.split('.').map(int.parse).toList();
      
      for (int i = 0; i < requiredParts.length; i++) {
        final currentPart = i < currentParts.length ? currentParts[i] : 0;
        if (currentPart < requiredParts[i]) return true;
        if (currentPart > requiredParts[i]) return false;
      }
      return false;
    } catch (e) {
      // Se não conseguir parsear, fallback para simples string comparison
      return currentVersion != requiredVersion;
    }
  }

  void _checkUpdate() async {
    try {
      final url = Uri.parse('https://drive.google.com/uc?export=download&id=1dSD8u8qTXyf6L89AU67k2BkwLjbIojUU');
      final response = await http.get(url).timeout(const Duration(seconds: 15));
      if (response.statusCode == 200 && mounted) {
        final decoded = jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
        if (decoded is Map<String, dynamic>) {
          final updateInfo = _resolveUpdateInfo(decoded);
          final requiredVersion = updateInfo['requiredVersion'] ?? '';
          final link = updateInfo['downloadLink'] ?? '';

          if (appVersion.isNotEmpty &&
              requiredVersion.isNotEmpty &&
              _isVersionLower(appVersion, requiredVersion)) {
            if (link.isEmpty) {
              _showMissingPlatformLinkDialog(requiredVersion);
            } else {
              _showUpdateDialog(requiredVersion, link);
            }
          }
        }
      } else {
        debugPrint('Falha ao checar versão via Google Drive. Status: ${response.statusCode}');
        _fallbackCheckUpdate();
      }
    } catch (e) {
      debugPrint('Erro no _checkUpdate via Drive: $e');
      _fallbackCheckUpdate();
    }
  }

  void _fallbackCheckUpdate() async {
    try {
      final result = await GoogleSheetsService().checkVersion();
      if (result.isNotEmpty && mounted) {
        final updateInfo = _resolveUpdateInfo(result);
        final requiredVersion = updateInfo['requiredVersion'] ?? '';
        final link = updateInfo['downloadLink'] ?? '';

        if (appVersion.isNotEmpty &&
            requiredVersion.isNotEmpty &&
            _isVersionLower(appVersion, requiredVersion)) {
          if (link.isEmpty) {
            _showMissingPlatformLinkDialog(requiredVersion);
          } else {
            _showUpdateDialog(requiredVersion, link);
          }
        }
      }
    } catch (e2) {
      debugPrint('Erro no _checkUpdate via Planilha: $e2');
    }
  }

  void _showMissingPlatformLinkDialog(String newVersion) {
    final platformName = _platformDisplayName();
    showDialog(
      context: context,
      barrierDismissible: false, // O usuário não pode fechar sem atualizar!
      builder: (ctx) => AlertDialog(
        title: const Text('Atualização Necessária'),
        content: Text(
          'A versão $newVersion do aplicativo está disponível e é obrigatória.\n\n'
          'Infelizmente, o link de atualização para a plataforma $platformName não está configurado no momento.\n\n'
          'Entre em contato com o suporte ou o administrador do sistema.'
        ),
      ),
    );
  }

  void _showUpdateDialog(String newVersion, String link) {
    final platformName = _platformDisplayName();
    final platformKey = _currentPlatformKey();
    
    String description = 'A versão $newVersion do aplicativo está disponível e é obrigatória para continuar o uso.\n\n';
    String buttonText = 'Baixar Nova Versão';

    if (platformKey == 'android') {
      description += 'Baixe o APK atualizado para continuar.';
      buttonText = 'Baixar APK';
    } else if (platformKey == 'windows') {
      description += 'Baixe o pacote do Windows atualizado para continuar.\n\nApós baixar, extraia o arquivo ZIP e abra o executável dentro da pasta.';
      buttonText = 'Baixar versão Windows';
    } else if (platformKey == 'web') {
      description += 'Atualize a página para usar a versão mais recente.';
      buttonText = 'Atualizar Página';
    } else {
      description += 'Baixe a nova versão para a plataforma $platformName para continuar.';
    }

    showDialog(
      context: context,
      barrierDismissible: false, // O usuário não pode fechar sem atualizar!
      builder: (ctx) => AlertDialog(
        title: const Text('Atualização Obrigatória'),
        content: Text(description),
        actions: [
          ElevatedButton(
            onPressed: () async {
              if (link.isEmpty) return;

              String validLink = link;
              if (!validLink.startsWith('http://') && !validLink.startsWith('https://')) {
                validLink = 'https://$validLink';
              }
              final url = Uri.parse(validLink);
              try {
                try {
                  await canLaunchUrl(url);
                } catch (_) {}

                final success = await launchUrl(url, mode: LaunchMode.externalApplication);
                if (!success && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Não foi possível abrir o link de download: $validLink'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              } catch (e) {
                debugPrint('Erro ao abrir link: $e');
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Erro ao tentar abrir o navegador: $e'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            child: Text(buttonText),
          ),
        ],
      ),
    );
  }

  void _login() async {
    if (_isLoading) return;

    if (_formKey.currentState!.validate()) {
      setState(() {
        _isLoading = true;
      });

      if (_serverLogin) {
        await _loginViaServer();
        return;
      }

      // Baixa as senhas atualizadas da nuvem ANTES de verificar
      var syncFailed = false;
      try {
        await TechnicianService().syncTechniciansFromCloud();
      } catch (e) {
        syncFailed = true;
        debugPrint('Erro ao sincronizar técnicos no login: $e');
      }

      final emailDigitado = _emailController.text.trim();
      final senhaDigitada = _passwordController.text;

      // Busca na lista de técnicos se existe alguém com este e-mail e senha
      // Se a pessoa foi pré-cadastrada no código e não tem senha, a senha padrão será '123456'
      final tecnicos = TechnicianService().technicians;
      final match = tecnicos.where((t) {
        final senhaDoTecnico = (t.password == null || t.password!.isEmpty) ? '123456' : t.password;
        return t.email.toLowerCase() == emailDigitado.toLowerCase() && senhaDoTecnico == senhaDigitada;
      }).toList();

      if (match.isNotEmpty) {
        final usuarioLogado = match.first;

        // Salva o NOME do usuário logado no SharedPreferences
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('logged_user_id', usuarioLogado.id);
        await prefs.setString('logged_user', usuarioLogado.name);
        await prefs.setString('logged_user_permission', usuarioLogado.permissions);

        if (mounted) {
          setState(() {
            _isLoading = false;
          });
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (context) => const HomeScreen()),
          );
        }
      } else {
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
          final message = syncFailed && tecnicos.isEmpty
              ? 'Não foi possível conectar ao servidor.'
              : 'E-mail ou senha incorretos.';
          _showLoginError(message);
        }
      }
    }
  }

  Future<void> _loginViaServer() async {
    final email = _emailController.text.trim();
    final senha = _passwordController.text;
    try {
      final tecnico = await GoogleSheetsService().loginRemote(email, senha);
      if (tecnico == null) {
        if (mounted) {
          setState(() => _isLoading = false);
          _showLoginError('E-mail ou senha incorretos.');
        }
        return;
      }

      await OfflineAuth.remember(email, senha, tecnico);
      await _openSession(tecnico);

      // Com a sessão aberta, carrega listas que exigem token.
      try {
        await TechnicianService().syncTechniciansFromCloud();
      } catch (e) {
        debugPrint('Erro ao sincronizar técnicos após login: $e');
      }
      EmployeeService().initialize();

      _goHome();
    } catch (e) {
      debugPrint('Erro no login pelo servidor: $e');
      // Sem conexão: aceita quem já entrou online neste aparelho.
      final offline = await OfflineAuth.verify(email, senha);
      if (offline.tecnico != null) {
        await _openSession(offline.tecnico!, keepToken: false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Sem conexão: entrou no modo offline.'),
            ),
          );
        }
        _goHome();
        return;
      }
      if (mounted) {
        setState(() => _isLoading = false);
        _showLoginError(
          offline.known
              ? 'E-mail ou senha incorretos.'
              : 'Sem conexão com o servidor. O primeiro acesso neste '
                  'aparelho precisa de internet.',
        );
      }
    }
  }

  Future<void> _openSession(TechnicianModel tecnico,
      {bool keepToken = true}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('logged_user_id', tecnico.id);
    await prefs.setString('logged_user', tecnico.name);
    await prefs.setString('logged_user_permission', tecnico.permissions);
    if (keepToken) {
      await prefs.setString(
          'session_token', AppsScriptClient.sessionToken ?? '');
    }
  }

  void _goHome() {
    if (!mounted) return;
    setState(() => _isLoading = false);
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (context) => const HomeScreen()),
    );
  }

  void _showLoginError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Theme.of(context).colorScheme.error,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final size = MediaQuery.of(context).size;
    final isWide = size.width >= 700;

    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(color: colorScheme.surface),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return Center(
                child: SingleChildScrollView(
                  padding: EdgeInsets.symmetric(
                    horizontal: isWide ? 32 : 20,
                    vertical: 24,
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Card(
                            elevation: 6,
                            shadowColor: colorScheme.shadow.withValues(alpha: 0.18),
                            color: colorScheme.surfaceContainerLowest,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(24),
                              side: BorderSide(
                                color: colorScheme.outlineVariant.withValues(alpha: 0.45),
                              ),
                            ),
                            child: Padding(
                              padding: EdgeInsets.all(isWide ? 36.0 : 24.0),
                              child: Form(
                                key: _formKey,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    Align(
                                      alignment: Alignment.center,
                                      child: Container(
                                        width: 74,
                                        height: 74,
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          color: colorScheme.primaryContainer.withValues(alpha: 0.7),
                                          borderRadius: BorderRadius.circular(20),
                                          border: Border.all(
                                            color: colorScheme.primary.withValues(alpha: 0.16),
                                          ),
                                        ),
                                        child: Icon(
                                          Icons.account_balance_outlined,
                                          size: 38,
                                          color: colorScheme.primary,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 24),
                                    Text(
                                      'Nexus Relatórios',
                                      textAlign: TextAlign.center,
                                      style: textTheme.headlineMedium?.copyWith(
                                        fontWeight: FontWeight.w900,
                                        color: colorScheme.onSurface,
                                        letterSpacing: 0,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      'Gestão de Relatórios Escolares',
                                      textAlign: TextAlign.center,
                                      style: textTheme.titleSmall?.copyWith(
                                        color: colorScheme.onSurfaceVariant,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'Acesse sua conta para continuar',
                                      textAlign: TextAlign.center,
                                      style: textTheme.bodySmall?.copyWith(
                                        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.82),
                                      ),
                                    ),
                                    const SizedBox(height: 30),
                                    CustomTextField(
                                      label: 'E-mail',
                                      controller: _emailController,
                                      prefixIcon: Icons.email_outlined,
                                      keyboardType: TextInputType.emailAddress,
                                      textInputAction: TextInputAction.next,
                                      validator: (value) {
                                        if (value == null || value.trim().isEmpty) {
                                          return 'Informe o e-mail.';
                                        }
                                        final emailRegex = RegExp(r'^[^@]+@[^@]+\.[^@]+');
                                        if (!emailRegex.hasMatch(value.trim())) {
                                          return 'Informe um e-mail válido.';
                                        }
                                        return null;
                                      },
                                    ),
                                    CustomTextField(
                                      label: 'Senha',
                                      controller: _passwordController,
                                      prefixIcon: Icons.lock_outline_rounded,
                                      obscureText: _obscurePassword,
                                      textInputAction: TextInputAction.done,
                                      onFieldSubmitted: (_) {
                                        if (!_isLoading) _login();
                                      },
                                      suffixIcon: Tooltip(
                                        message: _obscurePassword ? 'Mostrar senha' : 'Ocultar senha',
                                        child: IconButton(
                                          icon: Icon(
                                            _obscurePassword
                                                ? Icons.visibility_outlined
                                                : Icons.visibility_off_outlined,
                                          ),
                                          onPressed: _isLoading
                                              ? null
                                              : () {
                                                  setState(() {
                                                    _obscurePassword = !_obscurePassword;
                                                  });
                                                },
                                        ),
                                      ),
                                      validator: (value) {
                                        if (value == null || value.isEmpty) {
                                          return 'Informe a senha.';
                                        }
                                        return null;
                                      },
                                    ),
                                    const SizedBox(height: 28),
                                    PrimaryActionButton(
                                      label: 'Entrar',
                                      icon: Icons.login_rounded,
                                      isLoading: _isLoading,
                                      onPressed: _login,
                                      height: 54,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 18),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.verified_outlined,
                                size: 16,
                                color: colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                appVersion.isEmpty ? 'Versão...' : 'Versão $appVersion',
                                style: textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                );
            },
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }
}
