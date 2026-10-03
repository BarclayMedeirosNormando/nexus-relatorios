// ============================================================
// NEXUS RELATORIOS - Backend v3.0.0 (PWA / projeto independente)
// ------------------------------------------------------------
// Origem: APPS_SCRIPT_COMPLETO.gs (v2.1.0) do repositorio AppSecretaria.
// Mantidos SEM alteracao de comportamento: abas, cabecalhos, aliases,
// historico de versoes, auditoria, deduplicacao, sync em lote, cache,
// fotos/assinaturas no Drive e todos os nomes de acao.
//
// Mudancas em relacao a v2.1.0:
//  1. Projeto independente: abre a planilha por ID (nao depende de estar
//     "dentro" da planilha). ID em Propriedades do script (SPREADSHEET_ID).
//  2. Pasta de fotos por ID (DRIVE_FOLDER_ID), com fallback pelo nome antigo.
//  3. Seguranca opcional (desligada por padrao = 100% compativel):
//     token de sessao assinado (HMAC), acoes de ADM restritas, senha nao
//     trafega na listagem de tecnicos, senha com hash opcional.
//  4. buscar_funcionarios aceita {q, limit} (a aba tem ~28 mil linhas).
//  5. Aba de auditoria localizada sem diferenciar maiusculas/minusculas
//     (a planilha real tem "Auditoria_Relatorios").
//  6. Removida a metade duplicada/antiga do arquivo original.
//
// CORS (PWA): o cliente web deve enviar POST com
// Content-Type: text/plain;charset=utf-8 (evita preflight). O corpo
// continua sendo JSON e e lido de e.postData.contents.
// ============================================================

var APP_VERSION_BACKEND = '3.0.0';
var DEFAULT_SPREADSHEET_ID = '1DjHVSCbakaZwXgcY1kb0x_JXFqrM5HFFaXC8SVgbF0w';

function getProp_(key, fallback) {
  var v = PropertiesService.getScriptProperties().getProperty(key);
  return v === null || v === undefined || v === '' ? fallback : v;
}

function getSpreadsheet_() {
  return SpreadsheetApp.openById(getProp_('SPREADSHEET_ID', DEFAULT_SPREADSHEET_ID));
}

function findSheetCI_(ss, name) {
  var exact = ss.getSheetByName(name);
  if (exact) return exact;
  var wanted = String(name).toLowerCase();
  var sheets = ss.getSheets();
  for (var i = 0; i < sheets.length; i++) {
    if (sheets[i].getName().toLowerCase() === wanted) return sheets[i];
  }
  return null;
}

// Constantes de Abas
var SHEET_RELATORIOS = 'RELATORIOS';
var SHEET_ESCOLAS    = 'Escolas';
var SHEET_TECNICOS   = 'T\u00e9cnicos';
var SHEET_HISTORICO  = 'historico_relatorios';
var SHEET_CONFIG     = 'Configuracoes';
var SHEET_AUDITORIA  = 'auditoria_relatorios';

function doGet(e) {
  return resposta({
    status: 'success',
    success: true,
    message: 'API Nexus Relatorios online',
    backend: APP_VERSION_BACKEND
  });
}


function buscarFuncionariosAction(ss, payload) {
  var sheet = ss.getSheetByName('Funcionarios');
  if (!sheet) return resposta({status: 'error', success: false, message: 'Aba Funcionarios nao encontrada'});

  var q = payload && payload.q ? normalizeText(payload.q) : '';
  var limit = payload && payload.limit ? parseInt(payload.limit, 10) : (q ? 50 : 0);
  var rows = sheet.getDataRange().getValues();
  var result = [];
  for (var i = 1; i < rows.length; i++) {
    var matricula = rows[i][0] ? rows[i][0].toString().trim() : '';
    var nome = rows[i][1] ? rows[i][1].toString().trim() : '';
    if (!matricula && !nome) continue;
    if (q && normalizeText(nome).indexOf(q) === -1 && matricula.indexOf(q) === -1) continue;
    result.push({matricula: matricula, nome: nome});
    if (limit && result.length >= limit) break;
  }
  return resposta({status: 'success', success: true, data: result});
}


// ============================================================
// SEGURANCA (opcional) - ativar com ativarSeguranca() no editor
// ============================================================
var PUBLIC_ACTIONS = ['login', 'checar_versao', 'checkVersion'];
// Somente ADM. (Editar escola e editar o proprio cadastro continuam liberados
// para qualquer usuario logado, como no app atual; ver authorize_.)
var ADMIN_ACTIONS = [
  'deletar_tecnico', 'deletar_escola',
  'corrigirMunicipiosRelatorios', 'corrigirRelatoriosDuplicados'
];

function isAdminPerm_(perm) {
  var p = normalizeText(perm);
  return p === 'adm' || p === 'admin' || p === 'administrador' || p === 'administrator';
}
var TOKEN_TTL_MS = 14 * 24 * 60 * 60 * 1000;

function securityEnabled_() {
  return getProp_('REQUIRE_TOKEN', 'false') === 'true';
}

function hmac_(text) {
  var secret = getProp_('TOKEN_SECRET', '');
  if (!secret) return '';
  return Utilities.base64EncodeWebSafe(Utilities.computeHmacSha256Signature(text, secret));
}

function signToken_(tecnico) {
  var secret = getProp_('TOKEN_SECRET', '');
  if (!secret) return '';
  var claims = {
    id: tecnico.id || '',
    nome: tecnico.nome || '',
    email: tecnico.email || '',
    perm: String(tecnico.permissao || '').toUpperCase(),
    exp: new Date().getTime() + TOKEN_TTL_MS
  };
  var body = Utilities.base64EncodeWebSafe(JSON.stringify(claims), Utilities.Charset.UTF_8);
  return body + '.' + hmac_(body);
}

function verifyToken_(token) {
  if (!token || String(token).indexOf('.') === -1) return null;
  var parts = String(token).split('.');
  var expected = hmac_(parts[0]);
  if (!expected || expected.length !== parts[1].length) return null;
  var diff = 0;
  for (var i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ parts[1].charCodeAt(i);
  if (diff !== 0) return null;
  try {
    var claims = JSON.parse(Utilities.newBlob(Utilities.base64DecodeWebSafe(parts[0])).getDataAsString());
    if (!claims.exp || claims.exp < new Date().getTime()) return null;
    return claims;
  } catch (err) {
    return null;
  }
}

function authorize_(action, data, payload) {
  if (!securityEnabled_()) return {ok: true};
  if (PUBLIC_ACTIONS.indexOf(action) !== -1) return {ok: true};
  var token = (data && data.token) || (payload && payload.token) || '';
  var claims = verifyToken_(token);
  if (!claims) return {ok: false, error: 'Sessao invalida ou expirada. Faca login novamente.', code: 'AUTH'};
  var admin = isAdminPerm_(claims.perm);
  if (ADMIN_ACTIONS.indexOf(action) !== -1 && !admin) {
    return {ok: false, error: 'Sem permissao para esta acao.', code: 'FORBIDDEN'};
  }
  if (action === 'salvar_tecnico' && !admin) {
    // Nao-admin so altera o proprio cadastro e nunca o proprio nivel de acesso.
    if (!payload || String(payload.id || '') !== String(claims.id)) {
      return {ok: false, error: 'Sem permissao para alterar outro tecnico.', code: 'FORBIDDEN'};
    }
    payload.permissao = claims.perm;
  }
  return {ok: true, claims: claims};
}

// Senhas: texto puro (legado) ou "sha256$<salt>$<hex>".
function toHex_(bytes) {
  return bytes.map(function(b) { return ((b < 0 ? b + 256 : b)).toString(16).padStart(2, '0'); }).join('');
}

function hashPassword_(plain) {
  var salt = Utilities.getUuid().replace(/-/g, '').slice(0, 16);
  var digest = Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, salt + plain, Utilities.Charset.UTF_8);
  return 'sha256$' + salt + '$' + toHex_(digest);
}

function checkPassword_(stored, given) {
  stored = String(stored || '');
  given = String(given || '');
  // Compatibilidade com o app atual: tecnico sem senha cadastrada usa '123456'.
  // Desligue com a propriedade ALLOW_DEFAULT_PASSWORD=false.
  if (!stored && getProp_('ALLOW_DEFAULT_PASSWORD', 'true') === 'true') stored = '123456';
  if (stored.indexOf('sha256$') === 0) {
    var p = stored.split('$');
    var digest = Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, p[1] + given, Utilities.Charset.UTF_8);
    return toHex_(digest) === p[2];
  }
  return stored === given;
}

// ---- Rotinas para rodar manualmente no editor do Apps Script ----
function setupInicial() {
  var props = PropertiesService.getScriptProperties();
  if (!props.getProperty('SPREADSHEET_ID')) props.setProperty('SPREADSHEET_ID', DEFAULT_SPREADSHEET_ID);
  if (!props.getProperty('TOKEN_SECRET')) props.setProperty('TOKEN_SECRET', Utilities.getUuid() + Utilities.getUuid());
  if (!props.getProperty('REQUIRE_TOKEN')) props.setProperty('REQUIRE_TOKEN', 'false');
  Logger.log('Propriedades definidas. REQUIRE_TOKEN=' + props.getProperty('REQUIRE_TOKEN'));
  testarConexao();
}

function testarConexao() {
  var ss = getSpreadsheet_();
  Logger.log('Planilha: ' + ss.getName());
  ss.getSheets().forEach(function(s) {
    Logger.log(' - ' + s.getName() + ': ' + s.getLastRow() + ' linhas x ' + s.getLastColumn() + ' colunas');
  });
  var folder = getDriveFolder();
  Logger.log('Pasta de fotos: ' + folder.getName() + ' (' + folder.getId() + ')');
  Logger.log('Seguranca (REQUIRE_TOKEN): ' + securityEnabled_());
}

function ativarSeguranca() {
  PropertiesService.getScriptProperties().setProperty('REQUIRE_TOKEN', 'true');
  Logger.log('Seguranca ATIVADA: o app precisa enviar o token recebido no login.');
}

function desativarSeguranca() {
  PropertiesService.getScriptProperties().setProperty('REQUIRE_TOKEN', 'false');
  Logger.log('Seguranca DESATIVADA (modo compativel).');
}

// ATENCAO: so rode depois de desligar o script antigo - ele compara senha em texto puro.
function migrarSenhasParaHash() {
  var sheet = getTecnicosSheet(getSpreadsheet_());
  var values = sheet.getDataRange().getValues();
  var changed = 0;
  for (var i = 1; i < values.length; i++) {
    var senha = String(values[i][5] || '');
    if (senha && senha.indexOf('sha256$') !== 0) {
      sheet.getRange(i + 1, 6).setValue(hashPassword_(senha));
      changed++;
    }
  }
  PropertiesService.getScriptProperties().setProperty('HASH_PASSWORDS', 'true');
  clearCache(CACHE_TECNICOS);
  Logger.log('Senhas convertidas para hash: ' + changed);
}

// ============================================================
// NEXUS RELATORIOS - Backend otimizado v2.1.0
// Overrides seguros: lote, cache, lock e syncReportsBatch.
// ============================================================

var CACHE_TTL_SECONDS = 600;
var CACHE_ESCOLAS = 'nexus_escolas_v2';
var CACHE_TECNICOS = 'nexus_tecnicos_v2';
var CACHE_CONFIG = 'nexus_config_v2';
var DRIVE_FOLDER_FOTOS = 'AppSecretaria_Fotos';

var RELATORIOS_HEADERS = [
  'Data do Envio',
  'ID do Relat\u00f3rio',
  'Usu\u00e1rio Logado',
  'Nome da Escola',
  'Data da Visita',
  'Tipo de Relat\u00f3rio',
  'Motivos / Assuntos',
  'T\u00e9cnicos Presentes',
  'Respons\u00e1vel da Escola',
  'Observa\u00e7\u00f5es',
  'Link Assinatura',
  'Link Foto',
  'N\u00famero do Relat\u00f3rio',
  'Regional (GRE)',
  'municipio',
  'Endere\u00e7o da Escola',
  'inep',
  'fotos_json',
  'materiais_ti_json'
];
var RELATORIO_HEADERS_OFICIAIS = RELATORIOS_HEADERS;

var HISTORICO_HEADERS_OFICIAIS = [
  'DATA_SNAPSHOT',
  'VERSAO',
  'EDITADO_POR',
  'DATA_REGISTRO',
  'ID',
  'USUARIO',
  'ESCOLA',
  'DATA_VISITA',
  'TIPO',
  'MOTIVOS',
  'TECNICOS',
  'RESPONSAVEL',
  'OBSERVACOES',
  'URL_ASSINATURA',
  'URL_FOTOS',
  'NUMERO_RELATORIO',
  'GRE',
  'ENDERECO',
  'FOTOS_JSON',
  'MUNICIPIO',
  'INEP',
  'MATERIAIS_TI_JSON'
];

var AUDITORIA_HEADERS_OFICIAIS = ['DATA/HORA', 'USUARIO', 'ACAO', 'ESCOLA', 'ID_RELATORIO'];

var RELATORIO_FIELD_ALIASES = {
  dataEnvio: ['Data do Envio', 'DATA_REGISTRO', 'data_registro', 'dataEnvio', 'dataenvio', 'updatedAt'],
  id: ['ID do Relat\u00f3rio', 'ID do Relatorio', 'ID', 'id'],
  usuario: ['Usu\u00e1rio Logado', 'Usuario Logado', 'USUARIO', 'usuario', 'usuario_logado', 'creator'],
  escola: ['Nome da Escola', 'Nome da escola', 'ESCOLA', 'escola', 'schoolName'],
  dataVisita: ['Data da Visita', 'Data da visita', 'DATA_VISITA', 'data_visita', 'visitDate'],
  tipo: ['Tipo de Relat\u00f3rio', 'Tipo de Relatorio', 'TIPO', 'tipo', 'tipo_relatorio', 'isTechnicalAnalysis'],
  motivos: ['Motivos / Assuntos', 'Motivos', 'MOTIVOS', 'motivos', 'subjects'],
  tecnicos: ['T\u00e9cnicos Presentes', 'Tecnicos Presentes', 'TECNICOS', 'tecnicos', 'technicians'],
  responsavel: ['Respons\u00e1vel da Escola', 'Responsavel da Escola', 'RESPONSAVEL', 'responsavel', 'responsiblePerson'],
  observacoes: ['Observa\u00e7\u00f5es', 'Observacoes', 'OBSERVACOES', 'observacoes', 'observations'],
  urlAssinatura: ['Link Assinatura', 'URL_ASSINATURA', 'url_assinatura', 'urlAssinatura', 'signatureUrl'],
  urlFotos: ['Link Foto', 'Link Fotos', 'URL_FOTOS', 'url_fotos', 'urlFotos'],
  fotosJson: ['Fotos JSON', 'FOTOS_JSON', 'fotosJson', 'fotos_json'],
  materiaisTiJson: ['materiais_ti_json', 'MATERIAIS_TI_JSON', 'materiaisTiJson', 'tiMaterials', 'Materiais TI JSON'],
  numeroRelatorio: ['N\u00famero do Relat\u00f3rio', 'Numero do Relatorio', 'NUMERO_RELATORIO', 'numero_relatorio', 'reportNumber'],
  gre: ['Regional (GRE)', 'GRE', 'gre'],
  municipio: ['municipio', 'Munic\u00edpio', 'Municipio', 'schoolCity', 'cidade', 'city'],
  endereco: ['Endere\u00e7o da Escola', 'Endereco da Escola', 'ENDERECO', 'endereco', 'endereco_escola', 'schoolAddress'],
  inep: ['inep', 'INEP', 'schoolInep', 'codigoInep', 'codInep']
};

function doPost(e) {
  try {
    var raw = e && e.postData && e.postData.contents ? e.postData.contents : '{}';
    var data = JSON.parse(raw);
    var action = data.action || data.acao || '';
    var payload = data.payload || data;
    var ss = getSpreadsheet_();

    var auth = authorize_(action, data, payload);
    if (!auth.ok) return resposta({status: 'error', success: false, code: auth.code, message: auth.error});
    if (auth.claims && payload && typeof payload === 'object' && auth.claims.nome) {
      payload.usuario_logado = auth.claims.nome;
      ['creates', 'updates', 'deletes'].forEach(function(k) {
        if (Array.isArray(payload[k])) payload[k].forEach(function(item) { if (item && typeof item === 'object') item.usuario_logado = auth.claims.nome; });
      });
    }

    if (action === 'login') return loginAction(ss, payload);
    if (action === 'checar_versao' || action === 'checkVersion') return checkVersionAction(ss, payload);
    if (action === 'buscar_relatorios' || action === 'fetchReports') return fetchReportsAction(ss, payload);
    if (action === 'buscar_escolas' || action === 'fetchSchools') return fetchSchoolsAction(ss, payload);
    if (action === 'buscar_tecnicos' || action === 'fetchTechnicians') return fetchTechniciansAction(ss, payload);
    if (action === 'buscar_historico' || action === 'fetchHistory' || action === 'buscarHistorico') return fetchHistoryAction(ss, payload);
    if (action === 'buscar_funcionarios') return buscarFuncionariosAction(ss, payload);

    if (action === 'adicionar' || action === 'sendReport' || action === 'updateReport') {
      return saveReportAction(ss, payload, action);
    }
    if (action === 'deletar_relatorio' || action === 'deleteReport') {
      return deleteReportAction(ss, payload);
    }
    if (action === 'syncReportsBatch') {
      return syncReportsBatchAction(ss, payload);
    }
    if (action === 'salvar_escola') return salvarEscolaAction(ss, payload);
    if (action === 'deletar_escola') return deletarEscolaAction(ss, payload);
    if (action === 'salvar_tecnico') return salvarTecnicoAction(ss, payload);
    if (action === 'deletar_tecnico') return deletarTecnicoAction(ss, payload);
    if (action === 'corrigirMunicipiosRelatorios') return corrigirMunicipiosRelatoriosAction(ss, payload);
    if (action === 'corrigirRelatoriosDuplicados') return corrigirRelatoriosDuplicadosAction(ss, payload);

    return resposta({status: 'error', success: false, message: 'Acao nao reconhecida: ' + action});
  } catch (error) {
    return resposta({status: 'error', success: false, message: error.toString()});
  }
}

function withScriptLock(callback) {
  var lock = LockService.getScriptLock();
  lock.waitLock(30000);
  try {
    return callback();
  } finally {
    lock.releaseLock();
  }
}

function getRelatoriosSheet(ss) {
  return ss.getSheetByName('RELATORIOS') ||
         ss.getSheetByName('Relatorios') ||
         ss.getSheetByName('Relat\u00f3rios') ||
         ss.getSheetByName('RELAT\u00d3RIOS');
}

function getOrCreateRelatoriosSheet(ss) {
  var sheet = getRelatoriosSheet(ss);
  if (!sheet) sheet = ss.insertSheet(SHEET_RELATORIOS);
  if (sheet.getLastRow() === 0 || sheet.getLastColumn() === 0) {
    sheet.getRange(1, 1, 1, RELATORIO_HEADERS_OFICIAIS.length).setValues([RELATORIO_HEADERS_OFICIAIS]);
  }
  ensureRelatoriosColumns(sheet);
  return sheet;
}

function getEscolasSheet(ss) {
  return ss.getSheetByName(SHEET_ESCOLAS);
}

function getOrCreateEscolasSheet(ss) {
  var sheet = getEscolasSheet(ss) || ss.insertSheet(SHEET_ESCOLAS);
  if (sheet.getLastRow() === 0 || sheet.getLastColumn() === 0) {
    sheet.getRange(1, 1, 1, 7).setValues([['ID', 'INEP', 'NOME', 'ENDERECO', 'MUNICIPIO', 'UF', 'GRE']]);
  }
  return sheet;
}

function getTecnicosSheet(ss) {
  return ss.getSheetByName(SHEET_TECNICOS);
}

function getOrCreateTecnicosSheet(ss) {
  var sheet = getTecnicosSheet(ss) || ss.insertSheet(SHEET_TECNICOS);
  if (sheet.getLastRow() === 0 || sheet.getLastColumn() === 0) {
    sheet.getRange(1, 1, 1, 6).setValues([['ID', 'NOME', 'MATRICULA', 'EMAIL', 'PERMISSAO', 'SENHA']]);
  }
  return sheet;
}

function normalizeHeader(value) {
  return String(value || '')
    .trim()
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[^\w\s]/g, '')
    .replace(/\s+/g, ' ');
}

function normalizeText(value) {
  return String(value || '')
    .trim()
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/\s+/g, ' ');
}

function normalizeInep(value) {
  return String(value || '').replace(/[^0-9]/g, '').trim();
}

function getHeaderMap(sheet) {
  var lastCol = sheet.getLastColumn();
  if (!lastCol) return {};
  var headers = sheet.getRange(1, 1, 1, lastCol).getValues()[0];
  var map = {};
  for (var i = 0; i < headers.length; i++) {
    var key = normalizeHeader(headers[i]);
    if (key) map[key] = i + 1;
  }
  return map;
}

function getHeaderIndexByAliases(headerMap, aliases) {
  for (var i = 0; i < aliases.length; i++) {
    var key = normalizeHeader(aliases[i]);
    if (headerMap[key]) return headerMap[key];
  }
  return null;
}

function ensureColumnExists(sheet, columnName, headerMap) {
  var map = headerMap || getHeaderMap(sheet);
  var aliases = RELATORIO_FIELD_ALIASES[columnName] || [columnName];
  var found = getHeaderIndexByAliases(map, aliases);
  if (found) return found;
  var nextCol = sheet.getLastColumn() + 1;
  var fieldKey = RELATORIO_FIELD_ALIASES[columnName] ? columnName : getRelatorioFieldKeyForHeader(columnName);
  var officialName = fieldKey ? getOfficialRelatorioHeader(fieldKey) : columnName;
  sheet.getRange(1, nextCol).setValue(officialName);
  map[normalizeHeader(officialName)] = nextCol;
  return nextCol;
}

function getOfficialRelatorioHeader(fieldKey) {
  var aliases = RELATORIO_FIELD_ALIASES[fieldKey] || [];
  for (var i = 0; i < RELATORIOS_HEADERS.length; i++) {
    var header = RELATORIOS_HEADERS[i];
    for (var a = 0; a < aliases.length; a++) {
      if (normalizeHeader(header) === normalizeHeader(aliases[a])) return header;
    }
  }
  return aliases.length ? aliases[0] : fieldKey;
}

function ensureRelatoriosColumns(sheet) {
  var map = getHeaderMap(sheet);
  var missing = [];
  for (var i = 0; i < RELATORIO_HEADERS_OFICIAIS.length; i++) {
    var header = RELATORIO_HEADERS_OFICIAIS[i];
    var fieldKey = getRelatorioFieldKeyForHeader(header);
    var aliases = fieldKey ? RELATORIO_FIELD_ALIASES[fieldKey] : [header];
    if (!getHeaderIndexByAliases(map, aliases)) missing.push(header);
  }
  if (missing.length) {
    sheet.getRange(1, sheet.getLastColumn() + 1, 1, missing.length).setValues([missing]);
  }
}

function getRelatorioFieldKeyForHeader(header) {
  var wanted = normalizeHeader(header);
  for (var key in RELATORIO_FIELD_ALIASES) {
    var aliases = RELATORIO_FIELD_ALIASES[key];
    for (var i = 0; i < aliases.length; i++) {
      if (normalizeHeader(aliases[i]) === wanted) return key;
    }
  }
  return null;
}

function getRelatorioValue(row, headerMap, fieldKey, fallback) {
  var col = getHeaderIndexByAliases(headerMap, RELATORIO_FIELD_ALIASES[fieldKey] || []);
  if (!col) return fallback;
  var value = row[col - 1];
  return value !== undefined && value !== null && value !== '' ? value : fallback;
}

function setRelatorioValueInRow(row, headerMap, fieldKey, value) {
  var col = getHeaderIndexByAliases(headerMap, RELATORIO_FIELD_ALIASES[fieldKey] || []);
  if (col) row[col - 1] = value;
}

function setRelatorioValue(sheet, headerMap, rowNumber, fieldKey, value) {
  var col = getHeaderIndexByAliases(headerMap, RELATORIO_FIELD_ALIASES[fieldKey] || []);
  if (col) sheet.getRange(rowNumber, col).setValue(value);
}

function getValFromObj(obj, keys) {
  if (!obj) return null;
  for (var i = 0; i < keys.length; i++) {
    var k = keys[i];
    if (obj[k] !== undefined && obj[k] !== null && String(obj[k]).trim() !== '') return obj[k];
    var lower = String(k).toLowerCase();
    if (obj[lower] !== undefined && obj[lower] !== null && String(obj[lower]).trim() !== '') return obj[lower];
  }
  return null;
}

function clearCache(key) {
  try {
    CacheService.getScriptCache().remove(key);
  } catch (err) {
    Logger.log('Erro ao limpar cache ' + key + ': ' + err.toString());
  }
}

function putCacheJson(key, value, seconds) {
  try {
    var text = JSON.stringify(value);
    if (text.length < 90000) CacheService.getScriptCache().put(key, text, seconds || CACHE_TTL_SECONDS);
  } catch (err) {
    Logger.log('Erro ao gravar cache ' + key + ': ' + err.toString());
  }
}

function getCacheJson(key) {
  try {
    var text = CacheService.getScriptCache().get(key);
    return text ? JSON.parse(text) : null;
  } catch (err) {
    return null;
  }
}

function getSchoolsCached(ss) {
  var cached = getCacheJson(CACHE_ESCOLAS);
  if (cached) return cached;

  var sheet = getEscolasSheet(ss);
  if (!sheet) return [];

  var values = sheet.getDataRange().getValues();
  var map = getHeaderMap(sheet);
  var idCol = map.id || 1;
  var inepCol = map.inep || 2;
  var nomeCol = map.nome || 3;
  var enderecoCol = map.endereco || 4;
  var municipioCol = map.municipio || 5;
  var ufCol = map.uf || 6;
  var greCol = map.gre || 7;
  var rows = [];

  for (var i = 1; i < values.length; i++) {
    var row = values[i];
    if (!row[idCol - 1] && !row[nomeCol - 1]) continue;
    rows.push({
      id: row[idCol - 1] ? String(row[idCol - 1]) : '',
      inep: row[inepCol - 1] ? String(row[inepCol - 1]) : '',
      nome: row[nomeCol - 1] ? String(row[nomeCol - 1]) : '',
      endereco: row[enderecoCol - 1] ? String(row[enderecoCol - 1]) : '',
      municipio: row[municipioCol - 1] ? String(row[municipioCol - 1]) : '',
      uf: row[ufCol - 1] ? String(row[ufCol - 1]) : '',
      gre: row[greCol - 1] ? String(row[greCol - 1]) : ''
    });
  }

  putCacheJson(CACHE_ESCOLAS, rows);
  return rows;
}

function buildSchoolIndex(ss) {
  var schools = getSchoolsCached(ss);
  var index = {byInep: {}, byName: {}};
  for (var i = 0; i < schools.length; i++) {
    var school = schools[i];
    var inep = normalizeInep(school.inep);
    var name = normalizeText(school.nome);
    if (inep) index.byInep[inep] = school;
    if (name) index.byName[name] = school;
  }
  return index;
}

function getTechniciansCached(ss) {
  var cached = getCacheJson(CACHE_TECNICOS);
  if (cached) return cached;

  var sheet = getTecnicosSheet(ss);
  if (!sheet) return [];
  var values = sheet.getDataRange().getValues();
  var rows = [];
  for (var i = 1; i < values.length; i++) {
    var row = values[i];
    if (!row[0]) continue;
    rows.push({
      id: row[0] ? String(row[0]) : '',
      nome: row[1] ? String(row[1]) : '',
      matricula: row[2] ? String(row[2]) : '',
      email: row[3] ? String(row[3]) : '',
      permissao: row[4] ? String(row[4]) : '',
      senha: row[5] ? String(row[5]) : ''
    });
  }
  putCacheJson(CACHE_TECNICOS, rows);
  return rows;
}

function checkVersionAction(ss, payload) {
  var cached = getCacheJson(CACHE_CONFIG);
  if (cached) return resposta(cached);

  var sheet = ss.getSheetByName(SHEET_CONFIG) || ss.insertSheet(SHEET_CONFIG);
  if (sheet.getLastRow() === 0 || sheet.getLastColumn() === 0) {
    sheet.getRange(1, 1, 2, 6).setValues([
      ['VERSAO_ATUAL', 'LINK_DOWNLOAD', 'VERSAO_ANDROID', 'LINK_ANDROID', 'VERSAO_WINDOWS', 'LINK_WINDOWS'],
      ['2.0.3', '', '2.0.3', 'COLOQUE_LINK_APK_AQUI', '2.0.3', 'COLOQUE_LINK_WINDOWS_ZIP_AQUI']
    ]);
  }

  var values = sheet.getDataRange().getValues();
  var headers = values[0] || [];
  var row = values[1] || [];
  function cfg(name, fallbackIndex) {
    var wanted = normalizeHeader(name);
    for (var i = 0; i < headers.length; i++) {
      if (normalizeHeader(headers[i]) === wanted) return row[i] ? String(row[i]) : '';
    }
    return row[fallbackIndex] ? String(row[fallbackIndex]) : '';
  }

  var versao = cfg('VERSAO_ATUAL', 0);
  var result = {
    status: 'success',
    success: true,
    versao: versao,
    link: cfg('LINK_DOWNLOAD', 1),
    versao_android: cfg('VERSAO_ANDROID', 2) || versao,
    link_android: cfg('LINK_ANDROID', 3),
    versao_windows: cfg('VERSAO_WINDOWS', 4) || versao,
    link_windows: cfg('LINK_WINDOWS', 5)
  };
  result.android = {versao: result.versao_android, link: result.link_android};
  result.windows = {versao: result.versao_windows, link: result.link_windows};
  putCacheJson(CACHE_CONFIG, result, 300);
  return resposta(result);
}

function fetchSchoolsAction(ss, payload) {
  return resposta({status: 'success', success: true, data: getSchoolsCached(ss)});
}

function fetchTechniciansAction(ss, payload) {
  var rows = getTechniciansCached(ss);
  if (securityEnabled_()) {
    // Com seguranca ligada a senha nunca sai do servidor.
    rows = rows.map(function(t) {
      return {id: t.id, nome: t.nome, matricula: t.matricula, email: t.email, permissao: t.permissao, senha: ''};
    });
  }
  return resposta({status: 'success', success: true, data: rows});
}

function loginAction(ss, payload) {
  var email = getValFromObj(payload, ['email', 'emailTecnico']);
  var senha = getValFromObj(payload, ['senha', 'password']);
  if (!email || !senha) {
    return resposta({status: 'error', success: false, message: 'Preencha o e-mail e a senha'});
  }
  var targetEmail = String(email).trim().toLowerCase();
  var tecnicos = getTechniciansCached(ss);
  for (var i = 0; i < tecnicos.length; i++) {
    var tecnico = tecnicos[i];
    if (String(tecnico.email || '').trim().toLowerCase() === targetEmail && checkPassword_(tecnico.senha, senha)) {
      var safe = {
        id: tecnico.id, nome: tecnico.nome, matricula: tecnico.matricula,
        email: tecnico.email, permissao: tecnico.permissao,
        senha: securityEnabled_() ? '' : tecnico.senha
      };
      return resposta({status: 'success', success: true, tecnico: safe, token: signToken_(tecnico)});
    }
  }
  return resposta({status: 'error', success: false, message: 'E-mail ou senha incorretos'});
}

function fetchReportsAction(ss, payload) {
  var sheet = getOrCreateRelatoriosSheet(ss);

  var values = sheet.getDataRange().getValues();
  if (values.length <= 1) return resposta({status: 'success', success: true, data: []});

  var map = getHeaderMap(sheet);
  var schoolIndex = buildSchoolIndex(ss);
  var result = [];
  for (var i = 1; i < values.length; i++) {
    var row = values[i];
    var id = getRelatorioValue(row, map, 'id', '');
    if (!id) continue;

    var dataVisita = getRelatorioValue(row, map, 'dataVisita', '');
    var dataEnvio = getRelatorioValue(row, map, 'dataEnvio', '');
    var tipo = getRelatorioValue(row, map, 'tipo', '');
    var motivos = getRelatorioValue(row, map, 'motivos', '');
    var tecnicos = getRelatorioValue(row, map, 'tecnicos', '');
    var urlAssinatura = String(getRelatorioValue(row, map, 'urlAssinatura', '') || '');
    var urlFotos = String(getRelatorioValue(row, map, 'urlFotos', '') || '');
    var fotosJson = String(getRelatorioValue(row, map, 'fotosJson', '') || '');
    var materiaisTiJson = String(getRelatorioValue(row, map, 'materiaisTiJson', '[]') || '[]');
    var rowObj = {
      id: String(id),
      creator: String(getRelatorioValue(row, map, 'usuario', 'Desconhecido') || 'Desconhecido'),
      schoolName: String(getRelatorioValue(row, map, 'escola', '') || ''),
      visitDate: toIsoStringOrNow(dataVisita),
      isTechnicalAnalysis: isTipoTecnico(tipo),
      subjects: splitList(motivos),
      technicians: splitList(tecnicos),
      responsiblePerson: String(getRelatorioValue(row, map, 'responsavel', '') || ''),
      observations: String(getRelatorioValue(row, map, 'observacoes', '') || ''),
      reportNumber: String(getRelatorioValue(row, map, 'numeroRelatorio', '') || ''),
      gre: String(getRelatorioValue(row, map, 'gre', '') || ''),
      schoolAddress: String(getRelatorioValue(row, map, 'endereco', '') || ''),
      schoolInep: String(getRelatorioValue(row, map, 'inep', '') || ''),
      municipio: String(getRelatorioValue(row, map, 'municipio', '') || '')
    };
    var city = resolveMunicipioFromReport(ss, rowObj, schoolIndex);
    result.push({
      id: rowObj.id,
      creator: rowObj.creator,
      schoolName: rowObj.schoolName,
      visitDate: rowObj.visitDate,
      isTechnicalAnalysis: rowObj.isTechnicalAnalysis,
      subjects: rowObj.subjects,
      technicians: rowObj.technicians,
      responsiblePerson: rowObj.responsiblePerson,
      observations: rowObj.observations,
      reportNumber: rowObj.reportNumber,
      gre: rowObj.gre,
      schoolAddress: rowObj.schoolAddress,
      schoolCity: city,
      municipio: city,
      schoolInep: rowObj.schoolInep,
      inep: rowObj.schoolInep,
      signatureUrl: urlAssinatura,
      urlAssinatura: urlAssinatura,
      urlFotos: urlFotos,
      fotosJson: fotosJson,
      materiais_ti_json: materiaisTiJson,
      materiaisTiJson: materiaisTiJson,
      tiMaterials: parseMateriaisTiJson(materiaisTiJson),
      photos: parseFotosJsonForClient(fotosJson, urlFotos),
      updatedAt: dataEnvio ? toIsoStringOrNow(dataEnvio) : ''
    });
  }
  return resposta({status: 'success', success: true, data: result});
}

function saveReportAction(ss, payload, action) {
  return withScriptLock(function() {
    var result = saveReportInternal(ss, payload, action, null);
    registrarAuditoriaRows(ss, [[
      new Date(),
      payload.usuario_logado || payload.creator || 'Sistema',
      result.operation === 'updated' ? 'Editar Relatorio' : 'Criar Relatorio',
      payload.escola || payload.schoolName || '',
      payload.numero_relatorio || payload.reportNumber || result.id
    ]]);
    return resposta(result.response);
  });
}

function syncReportsBatchAction(ss, payload) {
  return withScriptLock(function() {
    var creates = payload.creates || [];
    var updates = payload.updates || [];
    var deletes = payload.deletes || [];
    var results = [];
    var auditRows = [];

    for (var i = 0; i < creates.length; i++) {
      var created = saveReportInternal(ss, creates[i], 'syncReportsBatch', null);
      results.push(created.itemResult);
      auditRows.push([new Date(), creates[i].usuario_logado || creates[i].creator || 'Sistema', 'Criar Relatorio', creates[i].escola || creates[i].schoolName || '', creates[i].numero_relatorio || creates[i].reportNumber || created.id]);
    }

    for (var u = 0; u < updates.length; u++) {
      updates[u].acao_tipo = updates[u].acao_tipo || 'Editar';
      var updated = saveReportInternal(ss, updates[u], 'syncReportsBatch', null);
      results.push(updated.itemResult);
      auditRows.push([new Date(), updates[u].usuario_logado || updates[u].creator || 'Sistema', 'Editar Relatorio', updates[u].escola || updates[u].schoolName || '', updates[u].numero_relatorio || updates[u].reportNumber || updated.id]);
    }

    if (deletes.length) {
      var deleted = deleteReportsInternal(ss, deletes);
      results = results.concat(deleted.results);
      auditRows = auditRows.concat(deleted.auditRows);
    }

    registrarAuditoriaRows(ss, auditRows);
    return resposta({status: 'success', success: true, results: results});
  });
}

function saveReportInternal(ss, payload, action, context) {
  var sheet = getOrCreateRelatoriosSheet(ss);
  var map = getHeaderMap(sheet);
  var values = sheet.getDataRange().getValues();
  var lastCol = sheet.getLastColumn();
  var id = getValFromObj(payload, ['id']);
  if (!id) throw new Error('ID do Relatorio e obrigatorio');
  id = String(id).trim();

  var idCol = getHeaderIndexByAliases(map, RELATORIO_FIELD_ALIASES.id);
  if (!idCol) throw new Error('Coluna ID do Relatorio nao encontrada');

  var rowNumber = null;
  for (var i = 1; i < values.length; i++) {
    var currentId = values[i][idCol - 1] ? String(values[i][idCol - 1]).trim() : '';
    if (currentId === id) {
      rowNumber = i + 1;
      break;
    }
  }

  var oldRow = rowNumber ? normalizeRowLength(values[rowNumber - 1], lastCol) : null;
  var row = oldRow ? oldRow.slice() : blankRow(lastCol);
  var assets = saveReportAssets(payload, oldRow, map);
  var schoolIndex = buildSchoolIndex(ss);
  var municipio = resolveMunicipioFromReport(ss, payload, schoolIndex);

  fillRelatorioRow(row, map, payload, id, municipio, assets);

  if (oldRow) {
    salvarHistoricoRows(ss, [{row: oldRow, map: map}], payload.usuario_logado || payload.creator || 'Sistema', payload.acao_tipo === 'Editar' ? 'Edicao' : 'Sincronizacao');
    sheet.getRange(rowNumber, 1, 1, lastCol).setValues([row]);
  } else {
    sheet.getRange(sheet.getLastRow() + 1, 1, 1, lastCol).setValues([row]);
  }

  var response = {
    status: 'success',
    success: true,
    id: id,
    urlAssinatura: assets.urlAssinatura || '',
    signatureUrl: assets.urlAssinatura || '',
    urlFotos: assets.urlFotos || '',
    fotosJson: assets.fotosJson || '',
    photos: assets.photos || []
  };

  return {
    id: id,
    operation: oldRow ? 'updated' : 'created',
    response: response,
    itemResult: {
      id: id,
      status: 'success',
      success: true,
      message: oldRow ? 'Relatorio atualizado' : 'Relatorio criado',
      urlAssinatura: response.urlAssinatura,
      signatureUrl: response.signatureUrl,
      urlFotos: response.urlFotos,
      fotosJson: response.fotosJson,
      photos: response.photos
    }
  };
}

function saveReportAssets(payload, oldRow, map) {
  var folder = getDriveFolder();
  var urlAssinatura = String(getValFromObj(payload, ['urlAssinaturaExistente', 'urlAssinatura', 'signatureUrl']) || '');
  if (!urlAssinatura && oldRow) urlAssinatura = String(getRelatorioValue(oldRow, map, 'urlAssinatura', '') || '');

  var assinaturaBase64 = getValFromObj(payload, ['assinaturaBase64', 'signatureBase64']);
  if (assinaturaBase64) {
    var cleanSignature = String(assinaturaBase64).indexOf(',') !== -1 ? String(assinaturaBase64).split(',').pop() : String(assinaturaBase64);
    var sigBlob = Utilities.newBlob(Utilities.base64Decode(cleanSignature), 'image/png', payload.assinaturaNome || ('assinatura_' + new Date().getTime() + '.png'));
    var sigFile = folder.createFile(sigBlob);
    sigFile.setSharing(DriveApp.Access.ANYONE_WITH_LINK, DriveApp.Permission.VIEW);
    urlAssinatura = directDriveUrl(sigFile.getId());
  }

  var photos = [];
  var urls = [];
  addExistingPhotos(payload.fotosJsonExistente || payload.photos || [], photos, urls);

  var fotosJsonText = getValFromObj(payload, ['fotosJson', 'fotos_json']);
  if (fotosJsonText && photos.length === 0) {
    try {
      addExistingPhotos(JSON.parse(String(fotosJsonText)), photos, urls);
    } catch (err) {
      Logger.log('fotosJson payload invalido: ' + err.toString());
    }
  }

  var fotosArray = payload.fotosArray || [];
  for (var i = 0; i < fotosArray.length; i++) {
    var fd = fotosArray[i];
    if (!fd || !fd.base64) continue;
    var cleanPhoto = String(fd.base64).indexOf(',') !== -1 ? String(fd.base64).split(',').pop() : String(fd.base64);
    var blob = Utilities.newBlob(Utilities.base64Decode(cleanPhoto), 'image/jpeg', fd.nome || ('foto_' + new Date().getTime() + '_' + i + '.jpg'));
    var file = folder.createFile(blob);
    file.setSharing(DriveApp.Access.ANYONE_WITH_LINK, DriveApp.Permission.VIEW);
    var url = directDriveUrl(file.getId());
    urls.push(url);
    photos.push({url: url, path: url, comment: fd.comentario || fd.comment || ''});
  }

  if (photos.length === 0 && oldRow) {
    var oldFotosJson = String(getRelatorioValue(oldRow, map, 'fotosJson', '') || '');
    var oldUrlFotos = String(getRelatorioValue(oldRow, map, 'urlFotos', '') || '');
    photos = parseFotosJsonForClient(oldFotosJson, oldUrlFotos);
    urls = photos.map(function(p) { return p.url || p.path; });
  }

  return {
    urlAssinatura: urlAssinatura,
    urlFotos: urls.join(', '),
    fotosJson: JSON.stringify(photos.map(function(p) {
      return {url: p.url || p.path, path: p.path || p.url, comment: p.comment || ''};
    })),
    photos: photos.map(function(p) {
      return {path: p.path || p.url, url: p.url || p.path, comment: p.comment || ''};
    })
  };
}

function addExistingPhotos(source, photos, urls) {
  if (!source) return;
  if (!Array.isArray(source)) source = [source];
  for (var i = 0; i < source.length; i++) {
    var item = source[i];
    var url = '';
    var comment = '';
    if (typeof item === 'string') {
      url = item;
    } else if (item) {
      url = getValFromObj(item, ['url', 'path', 'link', 'downloadUrl']) || '';
      comment = getValFromObj(item, ['comment', 'comentario', 'description', 'legenda']) || '';
    }
    url = String(url || '').trim();
    if (!url || url.indexOf('drive.google.com/drive/folders') !== -1) continue;
    urls.push(url);
    photos.push({url: url, path: url, comment: comment});
  }
}

function getDriveFolder() {
  var folderId = getProp_('DRIVE_FOLDER_ID', '');
  if (folderId) return DriveApp.getFolderById(folderId);
  var folders = DriveApp.getFoldersByName(DRIVE_FOLDER_FOTOS);
  return folders.hasNext() ? folders.next() : DriveApp.createFolder(DRIVE_FOLDER_FOTOS);
}

function fillRelatorioRow(row, map, payload, id, municipio, assets) {
  setRelatorioValueInRow(row, map, 'dataEnvio', new Date());
  setRelatorioValueInRow(row, map, 'id', id);
  setRelatorioValueInRow(row, map, 'usuario', getValFromObj(payload, ['usuario_logado', 'creator', 'usuario']) || '');
  setRelatorioValueInRow(row, map, 'escola', getValFromObj(payload, ['escola', 'schoolName']) || '');
  setRelatorioValueInRow(row, map, 'dataVisita', getValFromObj(payload, ['data_visita', 'visitDate', 'dataVisita']) || '');
  setRelatorioValueInRow(row, map, 'tipo', resolveTipoRelatorio(payload));
  setRelatorioValueInRow(row, map, 'motivos', normalizeListField(getValFromObj(payload, ['motivos', 'subjects'])));
  setRelatorioValueInRow(row, map, 'tecnicos', normalizeListField(getValFromObj(payload, ['tecnicos', 'technicians'])));
  setRelatorioValueInRow(row, map, 'responsavel', getValFromObj(payload, ['responsavel', 'responsiblePerson']) || '');
  setRelatorioValueInRow(row, map, 'observacoes', getValFromObj(payload, ['observacoes', 'observations']) || '');
  var materiaisTiJson = getValFromObj(payload, ['materiais_ti_json', 'materiaisTiJson', 'tiMaterials']);
  if (materiaisTiJson !== null && materiaisTiJson !== undefined) {
    setRelatorioValueInRow(row, map, 'materiaisTiJson', normalizeMateriaisTiJson(materiaisTiJson));
  }
  setRelatorioValueInRow(row, map, 'urlAssinatura', assets.urlAssinatura || '');
  setRelatorioValueInRow(row, map, 'urlFotos', assets.urlFotos || '');
  setRelatorioValueInRow(row, map, 'fotosJson', assets.fotosJson || '[]');
  setRelatorioValueInRow(row, map, 'numeroRelatorio', getValFromObj(payload, ['numero_relatorio', 'reportNumber', 'numeroRelatorio']) || '');
  setRelatorioValueInRow(row, map, 'gre', getValFromObj(payload, ['gre', 'GRE']) || '');
  setRelatorioValueInRow(row, map, 'municipio', municipio || '');
  setRelatorioValueInRow(row, map, 'endereco', getValFromObj(payload, ['endereco_escola', 'schoolAddress', 'endereco']) || '');
  setRelatorioValueInRow(row, map, 'inep', getValFromObj(payload, ['inep', 'schoolInep']) || '');
}

function resolveTipoRelatorio(payload) {
  var tipo = getValFromObj(payload, ['tipo_relatorio', 'tipo']);
  if (tipo) return tipo;
  var tech = getValFromObj(payload, ['isTechnicalAnalysis']);
  if (tech === true || tech === 'true') return 'T\u00e9cnico';
  if (tech === false || tech === 'false') return 'N\u00e3o-T\u00e9cnico';
  return '';
}

function normalizeListField(value) {
  if (!value) return '';
  if (Array.isArray(value)) {
    return value.map(function(item) { return String(item).trim(); }).filter(Boolean).join(', ');
  }
  return String(value);
}

function resolveMunicipioFromReport(ss, report, schoolIndex) {
  var currentCity = getValFromObj(report, ['municipio', 'schoolCity', 'cidade', 'city', 'Municipio', 'Munic\u00edpio', 'Cidade']);
  currentCity = currentCity ? String(currentCity).trim() : '';
  if (currentCity && currentCity !== 'Munic\u00edpio n\u00e3o informado') return currentCity;

  var index = schoolIndex || buildSchoolIndex(ss);
  var reportInep = normalizeInep(getValFromObj(report, ['inep', 'schoolInep', 'codigoInep', 'codInep']));
  if (reportInep && index.byInep[reportInep] && index.byInep[reportInep].municipio) {
    return String(index.byInep[reportInep].municipio).trim();
  }

  var schoolName = normalizeText(getValFromObj(report, ['escola', 'schoolName', 'nomeEscola', 'Nome da Escola']));
  if (schoolName && index.byName[schoolName] && index.byName[schoolName].municipio) {
    return String(index.byName[schoolName].municipio).trim();
  }
  return '';
}

function deleteReportAction(ss, payload) {
  return withScriptLock(function() {
    var result = deleteReportsInternal(ss, [payload]);
    registrarAuditoriaRows(ss, result.auditRows);
    if (!result.deletedCount) {
      return resposta({status: 'error', success: false, message: 'Relatorio nao encontrado na planilha'});
    }
    return resposta({status: 'success', success: true});
  });
}

function deleteReportsInternal(ss, deletes) {
  var sheet = getRelatoriosSheet(ss);
  if (!sheet) return {deletedCount: 0, results: [], auditRows: []};

  var values = sheet.getDataRange().getValues();
  if (values.length <= 1) return {deletedCount: 0, results: [], auditRows: []};

  var map = getHeaderMap(sheet);
  var idCol = getHeaderIndexByAliases(map, RELATORIO_FIELD_ALIASES.id);
  if (!idCol) throw new Error('Coluna ID do Relatorio nao encontrada');

  var deleteMap = {};
  for (var d = 0; d < deletes.length; d++) {
    var delId = getValFromObj(deletes[d], ['id']);
    if (delId) deleteMap[String(delId).trim()] = deletes[d];
  }

  var finalRows = [values[0]];
  var historyItems = [];
  var results = [];
  var auditRows = [];
  var deletedCount = 0;

  for (var i = 1; i < values.length; i++) {
    var rowId = values[i][idCol - 1] ? String(values[i][idCol - 1]).trim() : '';
    if (rowId && deleteMap[rowId]) {
      var payload = deleteMap[rowId];
      historyItems.push({row: values[i], map: map, editadoPor: payload.usuario_logado || payload.creator || 'Sistema'});
      deletedCount++;
      results.push({id: rowId, status: 'success', success: true, message: 'Relatorio excluido'});
      auditRows.push([
        new Date(),
        payload.usuario_logado || payload.creator || 'Sistema',
        'Excluir Relatorio',
        getRelatorioValue(values[i], map, 'escola', payload.escola || ''),
        getRelatorioValue(values[i], map, 'numeroRelatorio', payload.numero_relatorio || rowId)
      ]);
    } else {
      finalRows.push(normalizeRowLength(values[i], values[0].length));
    }
  }

  for (var missingId in deleteMap) {
    var already = false;
    for (var r = 0; r < results.length; r++) if (results[r].id === missingId) already = true;
    if (!already) results.push({id: missingId, status: 'error', success: false, message: 'Relatorio nao encontrado'});
  }

  if (deletedCount) {
    salvarHistoricoRows(ss, historyItems, 'Sistema', 'Exclusao');
    sheet.getRange(1, 1, finalRows.length, finalRows[0].length).setValues(finalRows);
    var oldRows = values.length;
    if (oldRows > finalRows.length) sheet.deleteRows(finalRows.length + 1, oldRows - finalRows.length);
  }

  return {deletedCount: deletedCount, results: results, auditRows: auditRows};
}

function salvarEscolaAction(ss, payload) {
  return withScriptLock(function() {
    var sheet = getOrCreateEscolasSheet(ss);
    var values = sheet.getDataRange().getValues();
    var id = String(getValFromObj(payload, ['id']) || '').trim();
    var row = [
      id,
      getValFromObj(payload, ['inep']) || '',
      getValFromObj(payload, ['nome', 'name']) || '',
      getValFromObj(payload, ['endereco', 'address']) || '',
      getValFromObj(payload, ['municipio', 'schoolCity', 'city']) || '',
      getValFromObj(payload, ['uf']) || '',
      getValFromObj(payload, ['gre']) || ''
    ];
    var rowNumber = null;
    for (var i = 1; i < values.length; i++) {
      if (String(values[i][0] || '').trim() === id) rowNumber = i + 1;
    }
    if (rowNumber) {
      sheet.getRange(rowNumber, 1, 1, 7).setValues([row]);
    } else {
      sheet.getRange(sheet.getLastRow() + 1, 1, 1, 7).setValues([row]);
    }
    clearCache(CACHE_ESCOLAS);
    registrarAuditoriaRows(ss, [[new Date(), payload.usuario_logado || 'Sistema', rowNumber ? 'Editar Escola' : 'Criar Escola', row[2], row[1] || id]]);
    return resposta({status: 'success', success: true});
  });
}

function deletarEscolaAction(ss, payload) {
  return withScriptLock(function() {
    var sheet = getEscolasSheet(ss);
    if (!sheet) return resposta({status: 'success', success: true});
    var values = sheet.getDataRange().getValues();
    var id = String(getValFromObj(payload, ['id']) || '').trim();
    var finalRows = [values[0]];
    var deleted = null;
    for (var i = 1; i < values.length; i++) {
      if (String(values[i][0] || '').trim() === id) {
        deleted = values[i];
      } else {
        finalRows.push(values[i]);
      }
    }
    if (deleted) {
      sheet.getRange(1, 1, finalRows.length, values[0].length).setValues(finalRows);
      if (values.length > finalRows.length) sheet.deleteRows(finalRows.length + 1, values.length - finalRows.length);
      registrarAuditoriaRows(ss, [[new Date(), payload.usuario_logado || 'Sistema', 'Excluir Escola', deleted[2] || '', deleted[1] || id]]);
    }
    clearCache(CACHE_ESCOLAS);
    return resposta({status: 'success', success: true});
  });
}

function salvarTecnicoAction(ss, payload) {
  return withScriptLock(function() {
    migrarTecnicosSeNecessario(ss);
    var sheet = getOrCreateTecnicosSheet(ss);
    var values = sheet.getDataRange().getValues();
    var id = String(getValFromObj(payload, ['id']) || '').trim();
    var rowNumber = null;
    for (var i = 1; i < values.length; i++) {
      if (String(values[i][0] || '').trim() === id) rowNumber = i + 1;
    }
    var senha = getValFromObj(payload, ['senha', 'password']) || '';
    if (senha) {
      if (getProp_('HASH_PASSWORDS', 'false') === 'true' && String(senha).indexOf('sha256$') !== 0) senha = hashPassword_(String(senha));
    } else if (rowNumber) {
      senha = values[rowNumber - 1][5] || '';   // nao apaga a senha existente
    }
    var row = [
      id,
      getValFromObj(payload, ['nome', 'name']) || '',
      getValFromObj(payload, ['matricula', 'registration']) || '',
      getValFromObj(payload, ['email']) || '',
      getValFromObj(payload, ['permissao', 'permissions']) || '',
      senha
    ];
    if (rowNumber) {
      sheet.getRange(rowNumber, 1, 1, 6).setValues([row]);
    } else {
      sheet.getRange(sheet.getLastRow() + 1, 1, 1, 6).setValues([row]);
    }
    clearCache(CACHE_TECNICOS);
    registrarAuditoriaRows(ss, [[new Date(), payload.usuario_logado || 'Sistema', rowNumber ? 'Editar Tecnico' : 'Criar Tecnico', row[1], row[2] || id]]);
    return resposta({status: 'success', success: true});
  });
}

function deletarTecnicoAction(ss, payload) {
  return withScriptLock(function() {
    var sheet = getTecnicosSheet(ss);
    if (!sheet) return resposta({status: 'success', success: true});
    var values = sheet.getDataRange().getValues();
    var id = String(getValFromObj(payload, ['id']) || '').trim();
    var finalRows = [values[0]];
    var deleted = null;
    for (var i = 1; i < values.length; i++) {
      if (String(values[i][0] || '').trim() === id) {
        deleted = values[i];
      } else {
        finalRows.push(values[i]);
      }
    }
    if (deleted) {
      sheet.getRange(1, 1, finalRows.length, values[0].length).setValues(finalRows);
      if (values.length > finalRows.length) sheet.deleteRows(finalRows.length + 1, values.length - finalRows.length);
      registrarAuditoriaRows(ss, [[new Date(), payload.usuario_logado || 'Sistema', 'Excluir Tecnico', deleted[1] || '', deleted[2] || id]]);
    }
    clearCache(CACHE_TECNICOS);
    return resposta({status: 'success', success: true});
  });
}

function corrigirMunicipiosRelatoriosAction(ss, payload) {
  return withScriptLock(function() {
    var sheet = getOrCreateRelatoriosSheet(ss);
    var map = getHeaderMap(sheet);
    var values = sheet.getDataRange().getValues();
    if (values.length <= 1) {
      return resposta({status: 'success', success: true, message: 'Nenhum relatorio para corrigir', corrigidos: 0, naoEncontrados: 0});
    }

    var cityCol = getHeaderIndexByAliases(map, RELATORIO_FIELD_ALIASES.municipio);
    var schoolIndex = buildSchoolIndex(ss);
    var corrigidos = 0;
    var naoEncontrados = 0;
    var cityValues = [];

    for (var i = 1; i < values.length; i++) {
      var currentCity = values[i][cityCol - 1] ? String(values[i][cityCol - 1]).trim() : '';
      if (!currentCity || currentCity === 'Munic\u00edpio n\u00e3o informado') {
        var rowObj = {
          escola: getRelatorioValue(values[i], map, 'escola', ''),
          schoolName: getRelatorioValue(values[i], map, 'escola', ''),
          inep: getRelatorioValue(values[i], map, 'inep', '')
        };
        var resolved = resolveMunicipioFromReport(ss, rowObj, schoolIndex);
        if (resolved) {
          currentCity = resolved;
          corrigidos++;
        } else {
          naoEncontrados++;
        }
      }
      cityValues.push([currentCity]);
    }

    sheet.getRange(2, cityCol, cityValues.length, 1).setValues(cityValues);
    return resposta({status: 'success', success: true, message: 'Municipios corrigidos com sucesso', corrigidos: corrigidos, naoEncontrados: naoEncontrados});
  });
}

function corrigirRelatoriosDuplicadosAction(ss, payload) {
  return withScriptLock(function() {
    var dryRun = payload && (payload.dryRun === true || payload.dryRun === 'true');
    var sheet = getRelatoriosSheet(ss);
    if (!sheet) return resposta({status: 'error', success: false, message: 'Aba RELATORIOS nao encontrada'});

    var values = sheet.getDataRange().getValues();
    var map = getHeaderMap(sheet);
    var idCol = getHeaderIndexByAliases(map, RELATORIO_FIELD_ALIASES.id);
    if (!idCol) return resposta({status: 'error', success: false, message: 'Coluna ID do Relatorio nao encontrada na planilha'});

    var bestById = {};
    var duplicates = {};
    for (var i = 1; i < values.length; i++) {
      var id = values[i][idCol - 1] ? String(values[i][idCol - 1]).trim() : '';
      if (!id) continue;
      var score = getRowRecencyScore(values[i], map, i);
      if (!bestById[id]) {
        bestById[id] = {index: i, score: score};
      } else {
        if (!duplicates[id]) duplicates[id] = [];
        duplicates[id].push(bestById[id].index + 1);
        if (score >= bestById[id].score) {
          bestById[id] = {index: i, score: score};
        }
      }
    }

    var idsDuplicados = [];
    var duplicateLinesById = {};
    for (var dupId in duplicates) {
      idsDuplicados.push(dupId);
      duplicateLinesById[dupId] = [];
    }

    var removeIndexes = {};
    for (var j = 1; j < values.length; j++) {
      var rid = values[j][idCol - 1] ? String(values[j][idCol - 1]).trim() : '';
      if (rid && bestById[rid] && bestById[rid].index !== j) {
        removeIndexes[j] = true;
        if (!duplicateLinesById[rid]) duplicateLinesById[rid] = [];
        duplicateLinesById[rid].push(j + 1);
        if (idsDuplicados.indexOf(rid) === -1) idsDuplicados.push(rid);
      }
    }

    var duplicateReport = idsDuplicados.map(function(id) {
      return {id: id, manterLinha: bestById[id].index + 1, duplicadas: duplicateLinesById[id] || []};
    });

    if (dryRun) {
      return resposta({
        status: 'success',
        success: true,
        dryRun: true,
        duplicadosEncontrados: duplicateReport.length,
        linhasRemovidas: 0,
        idsDuplicados: idsDuplicados,
        duplicados: duplicateReport
      });
    }

    var finalRows = [values[0]];
    var historyItems = [];
    var removed = 0;
    for (var r = 1; r < values.length; r++) {
      if (removeIndexes[r]) {
        historyItems.push({row: values[r], map: map});
        removed++;
      } else {
        finalRows.push(normalizeRowLength(values[r], values[0].length));
      }
    }

    if (removed) {
      salvarHistoricoRows(ss, historyItems, 'Sistema (Limpeza)', 'Duplicata antiga removida');
      sheet.getRange(1, 1, finalRows.length, values[0].length).setValues(finalRows);
      if (values.length > finalRows.length) sheet.deleteRows(finalRows.length + 1, values.length - finalRows.length);
    }

    registrarAuditoriaRows(ss, [[new Date(), 'Sistema (Limpeza)', 'Limpar Relatorios Duplicados', 'Todas', 'Total removidos: ' + removed]]);
    return resposta({
      status: 'success',
      success: true,
      dryRun: false,
      message: 'Deduplicacao concluida com sucesso',
      duplicadosEncontrados: duplicateReport.length,
      linhasRemovidas: removed,
      idsDuplicados: idsDuplicados,
      duplicados: duplicateReport
    });
  });
}

function salvarHistorico(ss, linhaAntiga, editadoPor, motivo) {
  salvarHistoricoRows(ss, [{row: linhaAntiga, map: null}], editadoPor, motivo);
}

function salvarHistoricoRows(ss, items, editadoPor, motivo) {
  if (!items || !items.length) return;
  try {
    var sheet = ss.getSheetByName(SHEET_HISTORICO) || ss.insertSheet(SHEET_HISTORICO);
    if (sheet.getLastRow() === 0 || sheet.getLastColumn() === 0) {
      sheet.getRange(1, 1, 1, HISTORICO_HEADERS_OFICIAIS.length).setValues([HISTORICO_HEADERS_OFICIAIS]);
      sheet.setFrozenRows(1);
    }

    var existing = sheet.getDataRange().getValues();
    var versionById = {};
    for (var i = 1; i < existing.length; i++) {
      var histId = existing[i][4] ? String(existing[i][4]) : '';
      if (histId) versionById[histId] = (versionById[histId] || 0) + 1;
    }

    var rows = [];
    for (var j = 0; j < items.length; j++) {
      var item = items[j];
      var row = item.row || [];
      var map = item.map;
      var id = map ? String(getRelatorioValue(row, map, 'id', '') || '') : String(row[1] || '');
      versionById[id] = (versionById[id] || 0) + 1;
      rows.push([
        new Date(),
        'v' + versionById[id],
        item.editadoPor || editadoPor || 'Sistema',
        map ? getRelatorioValue(row, map, 'dataEnvio', '') : (row[0] || ''),
        id,
        map ? getRelatorioValue(row, map, 'usuario', '') : (row[2] || ''),
        map ? getRelatorioValue(row, map, 'escola', '') : (row[3] || ''),
        map ? getRelatorioValue(row, map, 'dataVisita', '') : (row[4] || ''),
        map ? getRelatorioValue(row, map, 'tipo', '') : (row[5] || ''),
        map ? getRelatorioValue(row, map, 'motivos', '') : (row[6] || ''),
        map ? getRelatorioValue(row, map, 'tecnicos', '') : (row[7] || ''),
        map ? getRelatorioValue(row, map, 'responsavel', '') : (row[8] || ''),
        map ? getRelatorioValue(row, map, 'observacoes', '') : (row[9] || ''),
        map ? getRelatorioValue(row, map, 'urlAssinatura', '') : (row[10] || ''),
        map ? getRelatorioValue(row, map, 'urlFotos', '') : (row[11] || ''),
        map ? getRelatorioValue(row, map, 'numeroRelatorio', '') : (row[12] || ''),
        map ? getRelatorioValue(row, map, 'gre', '') : (row[13] || ''),
        map ? getRelatorioValue(row, map, 'endereco', '') : (row[15] || ''),
        map ? getRelatorioValue(row, map, 'fotosJson', '') : (row[17] || ''),
        map ? getRelatorioValue(row, map, 'municipio', '') : (row[14] || ''),
        map ? getRelatorioValue(row, map, 'inep', '') : (row[16] || ''),
        map ? getRelatorioValue(row, map, 'materiaisTiJson', '') : (row[18] || '')
      ]);
    }
    sheet.getRange(sheet.getLastRow() + 1, 1, rows.length, HISTORICO_HEADERS_OFICIAIS.length).setValues(rows);
  } catch (err) {
    Logger.log('Erro ao salvar historico: ' + err.toString());
  }
}

function registrarAuditoria(ss, usuario, acao, escola, idRelatorio) {
  registrarAuditoriaRows(ss, [[new Date(), usuario || 'Sistema', acao || '', escola || '', idRelatorio || '']]);
}

function registrarAuditoriaRows(ss, rows) {
  if (!rows || !rows.length) return;
  try {
    var sheet = findSheetCI_(ss, SHEET_AUDITORIA) || ss.insertSheet(SHEET_AUDITORIA);
    if (sheet.getLastRow() === 0 || sheet.getLastColumn() === 0) {
      sheet.getRange(1, 1, 1, AUDITORIA_HEADERS_OFICIAIS.length).setValues([AUDITORIA_HEADERS_OFICIAIS]);
      sheet.setFrozenRows(1);
    }
    sheet.getRange(sheet.getLastRow() + 1, 1, rows.length, AUDITORIA_HEADERS_OFICIAIS.length).setValues(rows);
  } catch (err) {
    Logger.log('Erro na auditoria: ' + err.toString());
  }
}

function migrarTecnicosSeNecessario(ss) {
  try {
    var incorrect = ss.getSheetByName('tecnicos') || ss.getSheetByName('Tecnicos');
    if (!incorrect) return;

    var correct = getTecnicosSheet(ss);
    if (!correct) {
      incorrect.setName(SHEET_TECNICOS);
      clearCache(CACHE_TECNICOS);
      return;
    }

    var incorrectRows = incorrect.getDataRange().getValues();
    var correctRows = correct.getDataRange().getValues();
    var rowByKey = {};
    for (var i = 1; i < correctRows.length; i++) {
      var id = correctRows[i][0] ? String(correctRows[i][0]) : '';
      var matricula = correctRows[i][2] ? String(correctRows[i][2]) : '';
      if (id) rowByKey[id] = i;
      if (matricula) rowByKey[matricula] = i;
    }

    var toAppend = [];
    for (var j = 1; j < incorrectRows.length; j++) {
      var row = incorrectRows[j];
      var rid = row[0] ? String(row[0]) : '';
      var rmat = row[2] ? String(row[2]) : '';
      if (!rid && !rmat) continue;
      var existingIndex = rowByKey[rid] !== undefined ? rowByKey[rid] : rowByKey[rmat];
      if (existingIndex === undefined) {
        toAppend.push(row);
      } else if (countFilled(row) > countFilled(correctRows[existingIndex])) {
        correctRows[existingIndex] = normalizeRowLength(row, correct.getLastColumn());
      }
    }

    if (correctRows.length > 1) {
      correct.getRange(1, 1, correctRows.length, correctRows[0].length).setValues(correctRows);
    }
    if (toAppend.length) {
      correct.getRange(correct.getLastRow() + 1, 1, toAppend.length, correct.getLastColumn()).setValues(toAppend.map(function(row) {
        return normalizeRowLength(row, correct.getLastColumn());
      }));
    }
    ss.deleteSheet(incorrect);
    clearCache(CACHE_TECNICOS);
  } catch (err) {
    Logger.log('Erro na migracao de tecnicos: ' + err.toString());
  }
}

function findRelatorioRowById(sheet, idReport) {
  var map = getHeaderMap(sheet);
  var idCol = getHeaderIndexByAliases(map, RELATORIO_FIELD_ALIASES.id);
  if (!idCol) throw new Error('Coluna ID do Relatorio nao encontrada');
  var values = sheet.getDataRange().getValues();
  var target = String(idReport || '').trim();
  for (var i = 1; i < values.length; i++) {
    if (String(values[i][idCol - 1] || '').trim() === target) return i + 1;
  }
  return null;
}

function parseFotosJsonForClient(fotosJson, urlFotos) {
  var photos = [];
  function addPhoto(url, comment) {
    var cleanUrl = String(url || '').trim();
    if (!cleanUrl || cleanUrl.indexOf('drive.google.com/drive/folders') !== -1) return;
    photos.push({path: cleanUrl, url: cleanUrl, comment: comment || ''});
  }
  if (fotosJson) {
    try {
      var parsed = JSON.parse(String(fotosJson));
      if (!Array.isArray(parsed)) parsed = [parsed];
      for (var i = 0; i < parsed.length; i++) {
        var item = parsed[i];
        if (typeof item === 'string') addPhoto(item, '');
        else if (item) addPhoto(item.url || item.path || item.link || item.downloadUrl, item.comment || item.comentario || '');
      }
    } catch (err) {
      Logger.log('Fotos JSON invalido: ' + err.toString());
    }
  }
  if (!photos.length && urlFotos) {
    var parts = String(urlFotos).split(/[\n;,]/);
    for (var p = 0; p < parts.length; p++) addPhoto(parts[p], '');
  }
  return photos;
}

function parseMateriaisTiJson(value) {
  if (!value) return [];
  try {
    var parsed = JSON.parse(String(value));
    return Array.isArray(parsed) ? parsed : [];
  } catch (err) {
    return [];
  }
}

function normalizeMateriaisTiJson(value) {
  if (value === null || value === undefined || value === '') return '[]';
  if (Array.isArray(value) || typeof value === 'object') return JSON.stringify(value);
  var text = String(value).trim();
  return text ? text : '[]';
}

function directDriveUrl(fileId) {
  return fileId ? 'https://drive.google.com/uc?export=download&id=' + fileId : '';
}

function resposta(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}

function toIsoStringOrNow(value) {
  try {
    var date = value instanceof Date ? value : new Date(value);
    if (isNaN(date.getTime())) return new Date().toISOString();
    return date.toISOString();
  } catch (err) {
    return new Date().toISOString();
  }
}

function splitList(value) {
  if (!value) return [];
  if (Array.isArray(value)) return value;
  return String(value).split(',').map(function(item) { return item.trim(); }).filter(Boolean);
}

function isTipoTecnico(tipo) {
  if (tipo === true) return true;
  var text = normalizeText(tipo);
  return text === 'tecnico' || text === 'tecnica' || text === 'technical' || text === '';
}

function blankRow(length) {
  var row = [];
  for (var i = 0; i < length; i++) row.push('');
  return row;
}

function normalizeRowLength(row, length) {
  var copy = row ? row.slice(0, length) : [];
  while (copy.length < length) copy.push('');
  return copy;
}

function countFilled(row) {
  var count = 0;
  for (var i = 0; i < row.length; i++) if (row[i] !== undefined && row[i] !== null && String(row[i]).trim() !== '') count++;
  return count;
}

function getRowRecencyScore(row, map, fallbackIndex) {
  var value = getRelatorioValue(row, map, 'dataEnvio', '');
  var date = value ? new Date(value) : null;
  if (date && !isNaN(date.getTime())) return date.getTime();
  return fallbackIndex;
}

function getHistoricoSheet(ss) {
  return ss.getSheetByName(SHEET_HISTORICO) ||
         ss.getSheetByName('Historico_Relatorios') ||
         ss.getSheetByName('HISTORICO_RELATORIOS') ||
         ss.getSheetByName('Histórico_Relatorios') ||
         ss.getSheetByName('Histórico de Relatórios');
}

var HISTORICO_FIELD_ALIASES = {
  dataSnapshot: ['DATA_SNAPSHOT', 'dataSnapshot'],
  versao: ['VERSAO', 'versao'],
  editadoPor: ['EDITADO_POR', 'editadoPor'],
  dataRegistro: ['DATA_REGISTRO', 'dataRegistro'],
  id: ['ID', 'id'],
  usuario: ['USUARIO', 'usuario'],
  escola: ['ESCOLA', 'escola'],
  dataVisita: ['DATA_VISITA', 'dataVisita'],
  tipo: ['TIPO', 'tipo'],
  motivos: ['MOTIVOS', 'motivos'],
  tecnicos: ['TECNICOS', 'Técnicos Presentes', 'Tecnicos Presentes', 'tecnicos'],
  responsavel: ['RESPONSAVEL', 'responsavel'],
  observacoes: ['OBSERVACOES', 'observacoes'],
  urlAssinatura: ['URL_ASSINATURA', 'urlAssinatura', 'Link Assinatura'],
  urlFotos: ['URL_FOTOS', 'urlFotos', 'Link Foto', 'Link Fotos'],
  numeroRelatorio: ['NUMERO_RELATORIO', 'Número do Relatório', 'Numero do Relatorio', 'numeroRelatorio', 'reportNumber'],
  gre: ['GRE', 'gre', 'Regional (GRE)'],
  endereco: ['ENDERECO', 'endereco', 'Endereço da Escola', 'Endereco da Escola'],
  fotosJson: ['FOTOS_JSON', 'fotosJson', 'fotos_json'],
  municipio: ['MUNICIPIO', 'municipio', 'Município', 'Municipio'],
  inep: ['INEP', 'inep', 'schoolInep']
};

function getHistoricoValue(row, headerMap, fieldKey, fallback) {
  var aliases = HISTORICO_FIELD_ALIASES[fieldKey] || [];
  var col = getHeaderIndexByAliases(headerMap, aliases);
  if (!col) return fallback;
  var value = row[col - 1];
  return value !== undefined && value !== null && value !== '' ? value : fallback;
}

function toIsoStringOrBlank(value) {
  if (!value) return '';
  var date = value instanceof Date ? value : new Date(value);
  if (date && !isNaN(date.getTime())) return date.toISOString();
  return String(value);
}

function fetchHistoryAction(ss, payload) {
  var sheet = getHistoricoSheet(ss);
  if (!sheet) return resposta({status: 'success', success: true, data: []});

  var values = sheet.getDataRange().getValues();
  if (values.length <= 1) return resposta({status: 'success', success: true, data: []});

  var map = getHeaderMap(sheet);
  var result = [];
  for (var i = values.length - 1; i >= 1; i--) {
    var row = values[i];
    var id = getHistoricoValue(row, map, 'id', '');
    if (!id) continue;

    var municipio = getHistoricoValue(row, map, 'municipio', '');
    var inep = getHistoricoValue(row, map, 'inep', '');
    var assinatura = getHistoricoValue(row, map, 'urlAssinatura', '');

    result.push({
      dataSnapshot: toIsoStringOrBlank(getHistoricoValue(row, map, 'dataSnapshot', '')),
      versao: String(getHistoricoValue(row, map, 'versao', '')),
      editadoPor: String(getHistoricoValue(row, map, 'editadoPor', '')),
      dataRegistro: toIsoStringOrBlank(getHistoricoValue(row, map, 'dataRegistro', '')),
      id: String(id),
      usuario: String(getHistoricoValue(row, map, 'usuario', '')),
      escola: String(getHistoricoValue(row, map, 'escola', '')),
      dataVisita: toIsoStringOrBlank(getHistoricoValue(row, map, 'dataVisita', '')),
      tipo: String(getHistoricoValue(row, map, 'tipo', '')),
      motivos: String(getHistoricoValue(row, map, 'motivos', '')),
      tecnicos: String(getHistoricoValue(row, map, 'tecnicos', '')),
      responsavel: String(getHistoricoValue(row, map, 'responsavel', '')),
      observacoes: String(getHistoricoValue(row, map, 'observacoes', '')),
      urlAssinatura: String(assinatura),
      signatureUrl: String(assinatura),
      urlFotos: String(getHistoricoValue(row, map, 'urlFotos', '')),
      numeroRelatorio: String(getHistoricoValue(row, map, 'numeroRelatorio', id)),
      gre: String(getHistoricoValue(row, map, 'gre', '')),
      endereco: String(getHistoricoValue(row, map, 'endereco', '')),
      fotosJson: String(getHistoricoValue(row, map, 'fotosJson', '')),
      municipio: String(municipio),
      schoolCity: String(municipio),
      inep: String(inep),
      schoolInep: String(inep)
    });
  }

  return resposta({status: 'success', success: true, data: result});
}
