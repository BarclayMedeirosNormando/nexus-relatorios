# Migração Nexus Relatórios → PWA (mesma planilha, novo Apps Script)

Objetivo: levar o app para um PWA com backend novo **sem perder nada do que já existe**.
A planilha "App Secretaria" continua sendo a única fonte de dados; o app atual (Android/Windows)
segue funcionando em paralelo até o corte.

## Status atual (03/10/2026)

- **Backend:** Apps Script novo `AppWEB` (arquivo `CodigoWEB.gs` = `apps_script/Code.gs`) na versão **3.1.0**, implantado como
  App da Web. Mesma planilha e mesma pasta de fotos. O `Código.gs` padrão/antigo foi removido desse projeto (funções repetidas
  em dois arquivos misturavam código antigo e novo).
- **App:** PWA no ar em `https://barclaymedeirosnormando.github.io/nexus-relatorios/` (repositório `nexus-relatorios`,
  deploy automático a cada push em `main`, variável de Actions `APPS_SCRIPT_URL`).
- **Validado:** login pelo servidor, listas de escolas/relatórios, criar relatório com foto e assinatura, PDF com foto e assinatura.
- **Falta antes de divulgar aos técnicos:** teste offline completo (3 fotos), tornar privado o repositório antigo `AppSecretaria`,
  confirmar que a pasta de fotos é a mesma do app antigo, período de uso em paralelo. Fase 4 (segurança) só depois que todos
  estiverem no PWA.

## O que NÃO muda (garantia de não perder dados)

| Item | Como é preservado |
|---|---|
| Planilha | Mesmo ID (`1DjHVSCb…bF0w`). Nenhuma aba, coluna ou linha é alterada pela migração. |
| Abas | `RELATORIOS`, `Escolas`, `Técnicos`, `historico_relatorios`, `Auditoria_Relatorios`, `Configuracoes`, `Funcionarios` |
| Cabeçalhos | O script casa colunas por nome/alias (mesma lógica do v2.1.0); colunas novas só são acrescentadas ao final. |
| Fotos e assinaturas | Mesma pasta do Drive (`AppSecretaria_Fotos`, por ID). Links já gravados continuam válidos. |
| Histórico de versões | `historico_relatorios` continua recebendo `v1, v2, …` a cada edição/exclusão. |
| Auditoria | Continua gravando; agora localiza a aba sem diferenciar maiúsculas (`Auditoria_Relatorios`). |
| Ações da API | Todos os nomes de ação do v2.1.0 foram mantidos (`login`, `buscar_*`, `adicionar`, `syncReportsBatch`, …). |
| Deduplicação, municípios, sync em lote, cache | Código idêntico ao v2.1.0. |

> O arquivo `APPS_SCRIPT_COMPLETO.gs` do repositório antigo tinha **duas versões coladas** (v2.0.0 + v2.1.0
> por cima). O novo `Code.gs` usa só a v2.1.0, que era a que de fato valia (funções repetidas: a última vence).

## Fase 0 — Backup (5 min, obrigatório)

1. Na planilha: **Arquivo → Fazer uma cópia** (nome `App Secretaria – backup AAAA-MM-DD`).
2. No Drive, anote o **ID da pasta `AppSecretaria_Fotos`** (URL da pasta: `drive.google.com/drive/folders/<ID>`).
3. No Apps Script antigo: **Configurações do projeto → anote o ID de implantação atual** (para poder voltar).

## Fase 1 — Novo Apps Script (independente da planilha)

1. Acesse script.google.com → **Novo projeto** → nome `Nexus Relatorios API v3`.
   Use a **mesma conta Google dona da planilha e da pasta de fotos** (hoje: a conta que criou a planilha).
2. Cole o conteúdo de `apps_script/Code.gs` (substitui o `Code.gs` padrão). **Deixe só um arquivo `.gs` no projeto**
   (não cole junto o script antigo do app Flutter).
   Para atualizar depois: cole o novo código, **Implantar → Gerenciar implantações → lápis → Nova versão → Implantar** (a URL não muda).
3. **Antes de rodar qualquer coisa**: em **Configurações do projeto → Propriedades do script → Adicionar propriedade**,
   crie `DRIVE_FOLDER_ID` = ID da pasta de fotos anotado na Fase 0. (Sem isso, se o script não achar uma pasta
   `AppSecretaria_Fotos` no Drive da conta, ele **cria uma pasta vazia nova** em vez de usar a antiga.)
4. Execute **`setupInicial`** (autorize Planilhas e Drive). Ele só grava propriedades do script — `SPREADSHEET_ID`,
   um `TOKEN_SECRET` aleatório e `REQUIRE_TOKEN=false` (modo compatível) — e depois chama `testarConexao`,
   que apenas lê e escreve no log. **Não altera a planilha.**
5. Confira o log do `setupInicial` (ou execute **`testarConexao`**) e confira no log: nome da planilha, as 7 abas com contagem de linhas
   (RELATORIOS ≈ 21, Escolas ≈ 674, Técnicos ≈ 16, Funcionarios ≈ 28.546) e o nome da pasta de fotos.
6. **Implantar → Nova implantação → App da Web** — *Executar como:* **Eu** · *Quem tem acesso:* **Qualquer pessoa**.
   Copie a URL `https://script.google.com/macros/s/…/exec`.
7. Teste rápido (substitua a URL):
   ```bash
   curl -sL "<URL>"                                  # {"status":"success",...,"backend":"3.1.0"}
   # no PowerShell (Windows): sem -X POST, senão o redirect do Apps Script dá erro 411
   curl.exe -sL "<URL>" -H "Content-Type: text/plain;charset=utf-8" -d '{\"acao\":\"buscar_escolas\"}'
   ```

## Fase 2 — Projeto Flutter novo (PWA)

O projeto já está em `app/` (copiado de `AppSecretaria`, branch `ajuste-pdf-final`, com o patch aplicado):

- `lib/services/apps_script_client.dart` (novo): cliente HTTP único. Web = `text/plain` + redirect pelo navegador;
  Android/Windows = comportamento anterior. Injeta o `token` de sessão quando existir.
- `lib/services/google_sheets_service.dart`: as 6 cópias de "POST + seguir 302 na mão" e o `_postAppsScript`
  agora usam o cliente; a URL deixou de estar no código (vem de `--dart-define=APPS_SCRIPT_URL`);
  novo método `loginRemote` (ação `login` do servidor).
- `lib/screens/login_screen.dart`: no **web** o login é validado no servidor (a senha não vai para o navegador).
  Android/Windows seguem como antes (`--dart-define=SERVER_LOGIN=true` para forçar nos demais).
- `lib/screens/home_screen.dart`: o logout apaga o token.
- `web/manifest.json` e `web/index.html`: nome, descrição, cor e idioma.
- `lib/screens/unified_report_screen.dart`: filtros de Regional e Município funcionam em qualquer ordem (um filtra o outro);
  escolher a escola primeiro preenche Regional e Município; busca por nome/INEP com palavras em qualquer ordem; Regional em
  branco na planilha é inferida pelas outras escolas do mesmo município (se houver uma só); erros de validação só aparecem
  depois de tentar salvar; fotos saem com no máx. 1280 px / JPEG 70%.
- **Login offline** (`lib/services/offline_auth.dart`, `login_screen.dart`, `main.dart`): depois de um login online, o aparelho
  guarda só um hash com sal da senha; sem internet entra no "modo offline". No PWA a sessão é mantida entre aberturas e
  `onAuthExpired` volta ao login. O primeiro acesso em cada aparelho precisa de internet.
- **Armazenamento** (`lib/services/local_store*.dart`, dependência `idb_shim`): fila offline, relatórios locais e cache de
  funcionários ficam no **IndexedDB** na web (migração automática do localStorage); Android/Windows seguem em SharedPreferences.
- **Fotos e assinaturas do Drive no navegador:** o Drive bloqueia `fetch` por CORS (a tag `<img>` funciona). Prévias usam a
  miniatura do Drive em `Image.network(webHtmlElementStrategy: prefer)`; o PDF busca a imagem pela ação nova
  `buscar_arquivo` do Apps Script (base64; só entrega arquivos dentro da pasta de fotos).
- Não foram copiados: planilhas `.xlsx`, `.csv`, JSONs de teste, `.ps1`, `test_*.dart`, pastas `android/ ios/ windows/ …`.

**Validação (faça no seu computador, não consegui compilar na sandbox):**
```bash
cd app
flutter pub get
flutter analyze
flutter run -d chrome --dart-define=APPS_SCRIPT_URL=<URL_NOVA>
flutter build web --release --base-href /<nome-do-repo>/ --dart-define=APPS_SCRIPT_URL=<URL_NOVA>
```
Publicação: `.github/workflows/deploy-web.yml` (original em `ci/deploy-web.yml`; build com `--no-web-resources-cdn` para o app abrir offline) faz build e publica no GitHub Pages a cada push em `main`
(crie a variável `APPS_SCRIPT_URL` **antes do primeiro deploy**, em *Settings → Secrets and variables → Actions → Variables* e ative
*Settings → Pages → Source: GitHub Actions*).

## Fase 3 — Operação em paralelo (1–2 semanas)

Checklist de validação (marque com dados de teste, escola "TESTE"):

- [ ] Login no PWA com um usuário real.
- [ ] Criar relatório com 2 fotos + assinatura no PWA → aparece na aba `RELATORIOS`, fotos abrem pelo link.
- [ ] O app antigo (Android/Windows) **lista** esse relatório; editar nele e conferir no PWA.
- [ ] Editar no PWA → nova linha `v2` em `historico_relatorios` e linha em `Auditoria_Relatorios`.
- [ ] Excluir o relatório de teste → vai para `historico_relatorios`.
- [ ] Modo avião: criar relatório offline, reconectar, sincroniza sem duplicar (`ID do Relatório` único).
- [ ] Gerar PDF no PWA e comparar com o do app antigo.
- [ ] Contagem final: nº de linhas de `RELATORIOS` = antes + testes.

Enquanto os dois backends estiverem ativos: o `LockService` é **por projeto**, então duas gravações
simultâneas (uma pelo script antigo e outra pelo novo) não se bloqueiam. É raro; evite que as mesmas pessoas
editem o mesmo relatório pelos dois apps ao mesmo tempo.

## Fase 4 — Corte e endurecimento de segurança

Situação hoje (confirmada no código): o login do app é **local** — ele baixa a lista de técnicos **com as senhas**
(`buscar_tecnicos`), guarda no aparelho e compara na tela de login; técnico sem senha usa `123456`.
A URL do Web App é pública, a coluna `SENHA` está em texto puro (há senhas fracas/repetidas) e, no PWA, as senhas
de todos ficariam no `localStorage` do navegador. Por isso o PWA usa o login do servidor.

1. Publique o PWA (Fase 2) e valide com `REQUIRE_TOKEN=false` (modo compatível).
2. No editor do script novo, rode **`ativarSeguranca`**. A partir daí:
   - todas as ações (menos `login` e `checar_versao`) exigem o token devolvido no login;
   - `deletar_tecnico`, `deletar_escola` e as rotinas `corrigir*` exigem permissão ADM
     (o app já mostrava essas opções só para ADM). Editar escola e editar o **próprio** cadastro (inclusive trocar
     a própria senha) continuam liberados a qualquer usuário logado; ninguém altera o próprio nível de acesso;
   - `buscar_tecnicos` deixa de devolver senha (salvar técnico com senha vazia **mantém** a senha atual);
   - o usuário registrado na auditoria/histórico vem do token, não do que o cliente envia.
   > Isso quebra o app antigo (Android/Windows): ele não envia token e depende da senha na lista de técnicos.
   > Ative só quando todos estiverem usando o PWA (ou uma versão do app com o mesmo patch e `SERVER_LOGIN=true`).
3. Arquive a implantação do script antigo (**Implantar → Gerenciar implantações → Arquivar**).
4. Rode **`migrarSenhasParaHash`** (converte `SENHA` para `sha256$salt$hash`; só depois do passo 3, pois o script
   antigo compara texto puro). Opcional: `ALLOW_DEFAULT_PASSWORD=false` (Propriedades do script) para
   acabar com o "sem senha = 123456".
5. Mantenha a cópia de backup por 30 dias.

**Limitação conhecida:** o filtro "usuário comum só vê os relatórios dele" continua sendo feito no app; o servidor
ainda devolve todos os relatórios a qualquer usuário autenticado. Filtrar no servidor é uma evolução futura.

## Rollback

Qualquer problema nas fases 1–3: basta o app antigo continuar apontando para a URL antiga (não foi tocada).
Na Fase 4, `desativarSeguranca` volta ao modo compatível imediatamente; se necessário, reative a implantação antiga.

## Instalação nos aparelhos

- **Windows (Chrome/Edge):** abrir o link → ícone de instalar na barra de endereço (ou menu → Instalar página como app).
- **Android (Chrome):** abrir o link → menu ⋮ → Instalar app / Adicionar à tela inicial.
- **iPhone (Safari):** Compartilhar → Adicionar à Tela de Início.
- Atualizações são automáticas; depois de um deploy, fechar e abrir o app uma ou duas vezes (ou Ctrl+Shift+R no navegador).

## Pendências conhecidas

1. ~~Fila offline na web~~ **Resolvido:** IndexedDB + fotos reduzidas (ver Fase 2). Ainda vale sincronizar assim que houver
   sinal; o navegador pode apagar dados do site em aparelhos sem espaço (menos provável com o app instalado).
2. **Peso do bundle**: `employee_data.dart` (2 MB) e `school_data.dart` (170 KB) estão compilados dentro do app.
   Mover para `assets/*.json` ou buscar via `buscar_funcionarios` com `{q, limit}` (já suportado no backend novo).
3. **Cache de escolas**: a lista (673 escolas) passa de ~90 KB e o `CacheService` não guarda; cada leitura vai à planilha.
4. **O repositório antigo `AppSecretaria` é público** e contém `Funcionarios*.xlsx` (≈28 mil servidores), planilhas/CSVs e a
   URL do script antigo. Tornar **privado** (Settings → General → Danger Zone → Change visibility) e, depois do corte,
   arquivar/regerar a implantação do script antigo. O histórico do Git mantém os arquivos mesmo se forem apagados.
5. `EmployeeService` ainda baixa os ≈28 mil funcionários inteiros (agora guardados no IndexedDB); trocar por busca sob
   demanda com `buscar_funcionarios {q, limit}`.
6. A coluna GRE está em branco em algumas escolas da planilha (ex.: ECIT Durval Guedes); preencher para ficar definitivo.
7. O filtro "usuário comum só vê os relatórios dele" ainda é feito no app (ver Fase 4).
