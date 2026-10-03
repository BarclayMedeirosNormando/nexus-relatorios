/// Converte exceções técnicas em mensagens curtas para o usuário,
/// sem expor URLs, endereços do servidor ou detalhes internos.
String friendlyError(Object error) {
  final t = error.toString().toLowerCase();

  if (t.contains('networkerror') ||
      t.contains('socketexception') ||
      t.contains('failed host lookup') ||
      t.contains('clientexception') ||
      t.contains('failed to fetch') ||
      t.contains('connection') ||
      t.contains('network')) {
    return 'sem conexão com a internet';
  }
  if (t.contains('timeout') || t.contains('timed out')) {
    return 'o servidor demorou a responder';
  }
  if (t.contains('401') || t.contains('403') || t.contains('sessão') || t.contains('auth')) {
    return 'sessão expirada. Entre novamente';
  }
  if (t.contains('500') || t.contains('502') || t.contains('503')) {
    return 'servidor indisponível no momento';
  }
  return 'erro inesperado';
}
