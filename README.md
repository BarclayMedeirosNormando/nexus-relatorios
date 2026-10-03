# Nexus Relatórios — PWA

Versão PWA do app de relatórios de visitas às escolas (SEE-PB), usando a **mesma planilha Google** do app atual.

- `apps_script/Code.gs` — backend novo (Apps Script independente, base v2.1.0 + segurança opcional)
- `app/` — projeto Flutter (copiado de `AppSecretaria` + patch para web)
- `flutter_patches/` — o mesmo patch em forma de documentação (referência)
- `docs/MIGRACAO.md` — migração por fases, checklist de validação e rollback
- `ci/deploy-web.yml` — build e publicação no GitHub Pages (copie para `.github/workflows/` no repositório)

Não versionar planilhas com dados de servidores nem URLs/IDs de produção (ver `.gitignore`).
