# Migração Nexus Relatórios → PWA (mesma planilha, novo Apps Script)

Objetivo: levar o app para um PWA com backend novo **sem perder nada do que já existe**.
A planilha "App Secretaria" continua sendo a única fonte de dados; o app atual (Android/Windows)
segue funcionando em paralelo até o corte.

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
2. Cole o conteúdo de `apps_script/Code.gs` (substitui o `Code.gs` padrão).
3. Execute **`setupInicial`** (autorize Planilhas e Drive). Ele grava `SPREADSHEET_ID`, gera `TOKEN_SECRET`
   e deixa `REQUIRE_TOKEN=false` (modo compatível).
4. **Configurações do projeto → Propriedades do script → adicionar** `DRIVE_FOLDER_ID` = ID anotado na Fase 0.
5. Execute **`testarConexao`** e confira no log: nome da planilha, as 7 abas com contagem de linhas
   (RELATORIOS ≈ 21, Escolas ≈ 674, Técnicos ≈ 16, Funcionarios ≈ 28.546) e o nome da pasta de fotos.
6. **Implantar → Nova implantação → App da Web** — *Executar como:* **Eu** · *Quem tem acesso:* **Qualquer pessoa**.
   Copie a URL `https://script.google.com/macros/s/…/exec`.
7. Teste rápido (substitua a URL):
   ```bash
   curl -sL "<URL>"                                  # {"status":"success",...,"backend":"3.0.0"}
   curl -sL -X POST "<URL>" -H "Content-Type: text/plain" \
        -d '{"action":"buscar_escolas","payload":{}}' | head -c 300
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
- Não foram copiados: planilhas `.xlsx`, `.csv`, JSONs de teste, `.ps1`, `test_*.dart`, pastas `android/ ios/ windows/ …`.

**Validação (faça no seu computador, não consegui compilar na sandbox):**
```bash
cd app
flutter pub get
flutter analyze
flutter run -d chrome --dart-define=APPS_SCRIPT_URL=<URL_NOVA>
flutter build web --release --base-href /<nome-do-repo>/ --dart-define=APPS_SCRIPT_URL=<URL_NOVA>
```
Publicação: `ci/deploy-web.yml` (copie para `.github/workflows/`) faz build e publica no GitHub Pages a cada push em `main`
(crie a variável `APPS_SCRIPT_URL` em *Settings → Secrets and variables → Actions → Variables* e ative
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

## Pendências conhecidas (fase 2 do projeto, não bloqueiam o PWA)

1. **Fila offline na web**: `shared_preferences` vira `localStorage` (~5 MB) e a fila guarda fotos em base64 —
   estoura com poucos relatórios. Migrar a fila para IndexedDB (`sembast_web`/`idb_shim`) e reduzir fotos
   (≈1280 px, JPEG 70%) antes de enfileirar.
2. **Peso do bundle**: `employee_data.dart` (2 MB) e `school_data.dart` (170 KB) estão compilados dentro do app.
   Mover para `assets/*.json` ou buscar via `buscar_funcionarios` com `{q, limit}` (já suportado no backend novo).
3. **Cache de escolas**: a lista (673 escolas) passa de ~90 KB e o `CacheService` não guarda; cada leitura vai à planilha.
   Funciona, só não é cacheado. Possível otimização: cachear em partes.
4. **O repositório antigo `AppSecretaria` é público** (consegui clonar sem credencial). Ele contém `Funcionarios*.xlsx`
   (≈28 mil servidores: nome e matrícula), `Nexus Educacional.xlsx`, CSVs de técnicos/escolas e a URL do Web App
   antigo. Recomendo torná-lo **privado** agora (Settings → General → Danger Zone → Change visibility) e, depois do corte,
   gerar nova implantação/URL do script antigo ou arquivá-la. O histórico do Git mantém os arquivos mesmo se forem apagados.
5. `EmployeeService` baixa os ≈28 mil funcionários inteiros e guarda no `localStorage` (≈2 MB); o backend novo já aceita
   `buscar_funcionarios` com `{q, limit}` para trocar por busca sob demanda.
