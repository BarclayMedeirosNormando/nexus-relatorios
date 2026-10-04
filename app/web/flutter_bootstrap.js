{{flutter_js}}
{{flutter_build_config}}

// O service worker do Flutter foi descontinuado; o app usa o proprio
// (web/nexus_sw.js, registrado em index.html). Por isso nao passamos
// serviceWorkerSettings aqui.
_flutter.loader.load({});
