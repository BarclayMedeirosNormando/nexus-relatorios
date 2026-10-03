# Patch em `lib/services/google_sheets_service.dart`

> **Já aplicado em `app/`.** Este arquivo fica como referência do que foi alterado.
> (O login do app é local, então o PWA usa `loginRemote`; ver `docs/MIGRACAO.md`, Fase 4.)

Base analisada: `ajuste-pdf-final` (arquivo de ~2.2 mil linhas). Não compilei com o SDK do Flutter;
os trechos abaixo foram escritos a partir da leitura do código e devem ser validados com `flutter analyze`.

## 1. URL do script e import

```dart
import 'apps_script_client.dart';
```

Remova a constante `_scriptUrl` (linha ~40) — a URL passa a vir de `--dart-define=APPS_SCRIPT_URL=...`.
Todos os `Uri.parse(_scriptUrl)` deixam de ser necessários.

## 2. `_postAppsScript` vira um atalho (linha ~1295)

```dart
Future<http.Response> _postAppsScript(
  Uri uri, {
  required Map<String, dynamic> payload,
  Duration timeout = const Duration(seconds: 45),
}) =>
    AppsScriptClient.post(payload, timeout: timeout);
```

Os chamadores existentes (`_postAppsScript(Uri.parse(_scriptUrl), payload: data)`) continuam compilando se você
mantiver o parâmetro `uri` ignorado; depois pode limpar.

## 3. As outras 6 cópias manuais (linhas ~273, 1783, 1860, 2044, 2096, 2206)

Todas seguem o mesmo molde:

```dart
var request = http.Request('POST', Uri.parse(_scriptUrl));
request.headers.addAll(_jsonHeaders);
request.body = jsonEncode(data);
request.followRedirects = false;
var client = http.Client();
var streamed = await client.send(request).timeout(const Duration(seconds: 40));
var response = await http.Response.fromStream(streamed);
http.Response finalResponse = response;
if (response.statusCode == 302 || response.statusCode == 303) { ... http.get(location) ... }
```

Substitua o bloco inteiro (do `http.Request` até o fim do `if` do redirect) por:

```dart
final finalResponse = await AppsScriptClient.post(
  data,
  timeout: const Duration(seconds: 40),
);
```

O resto de cada método (`finalResponse.statusCode == 200`, `_parseAndValidateResponse(...)`) fica igual.
Métodos afetados: `fetchHistory`, `checkVersion` e os demais que montam `http.Request` à mão
(procure por `followRedirects = false`).

## 4. Login e token (necessário só na Fase 4 — segurança ligada)

No método de login, depois de validar `decoded['success']`:

```dart
final token = decoded['token']?.toString();
AppsScriptClient.sessionToken = (token != null && token.isNotEmpty) ? token : null;
// persistir: prefs.setString('session_token', token ?? '');
```

Ao iniciar o app: `AppsScriptClient.sessionToken = prefs.getString('session_token');`
No logout: limpar as duas coisas. Em `main()`:

```dart
AppsScriptClient.onAuthExpired = () { /* limpar sessão e ir para a tela de login */ };
```

Com a segurança ligada, `login` e `buscar_tecnicos` deixam de devolver a senha; se alguma tela de gestão
mostrava/pré-preenchia a senha do técnico, ela passa a vir vazia — ao salvar com senha vazia o backend **mantém**
a senha atual.

## 5. Web: pontos para verificar

- `import 'dart:io';` compila na web, mas qualquer `File(...)`/`Platform` **executado** quebra. O código já usa `kIsWeb`
  para fotos (blob via HTTP); confirme também geração/compartilhamento de PDF (`printing` funciona na web).
- `package_info_plus` e a checagem de versão/links de APK: esconder na web (o PWA se atualiza sozinho).
- `web/manifest.json`: `name`, `short_name`, `description`, `start_url: "."`, `scope: "."`.
