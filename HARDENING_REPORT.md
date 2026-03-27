# Hardening Report — llm-local-architecture

## Lots réalisés
- [x] LOT 1 — Isolation routeur
- [x] LOT 2 — Protection user_message
- [x] LOT 3 — Exceptions Ollama typées
- [x] LOT 4 — Robustesse pipeline documentaire
- [x] LOT 5 — Tests intégration API

## Tests ajoutés
- 22 tests ajoutés sur les lots 1 à 5.
- Inventaire final: 70 tests collectés (`pytest --collect-only -q`).

## Régressions détectées
- Aucune régression fonctionnelle détectée sur la suite finale.
- Suite finale: `70 passed`.
- Warnings restants: 2 avertissements `FastAPI on_event` déprécié, sans impact sur le hardening livré.

## Reste à faire
- LOT 6 : Tests Playwright UI (local-only, non bloquant CI)
- Tests anti-hallucination sur documents réels CPAM / CSTMD (manuel)
- Audit keywords `ROUTING_RULES` complet si nouveaux faux positifs détectés

## Commits réalisés pour ce hardening
- `ef2c363` fix(router): isolate routing from document content injection
- `557a7d2` fix(prompting): protect user_message from truncation
- `46568e8` feat(orchestrator): typed Ollama exceptions with cause logging
- `9983d3f` feat(documents): magic bytes detection, page limit, graceful empty doc
- `a4009f0` test(api): integration coverage with ASGI transport, no live Ollama or SQLite
