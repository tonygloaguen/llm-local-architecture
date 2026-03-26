# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Objectif

Architecture locale pour orchestration multi-modèles LLM (RTX 5060 8GB, Ubuntu 24.04).
Ce repo contient la documentation d'architecture et les scripts opérationnels — pas de code applicatif.

## Fichiers

| Fichier | Rôle |
|---------|------|
| `bootstrap.sh` | Télécharge les 5 modèles, vérifie SHA-256, génère manifest.json, installe le cron |
| `PARTIE1_batch_modeles.md` | Sélection et justification du batch de modèles |
| `PARTIE2_orchestration.md` | Graph LangGraph + règles de routing déterministes |
| `PARTIE3_integrite.md` | Procédures de vérification SHA et gestion des dérives |
| `PARTIE4_nis2.md` | Checklist sécurité opérationnelle inspirée NIS2 |
| `PARTIE5_controles.md` | Tableau de contrôles récurrents + scripts |
| `PARTIE6_architecture.md` | Architecture technique + pyproject.toml |
| `PARTIE7_benchmark.md` | Script benchmark Python complet (scoring 4 axes) |
| `PARTIE8_verdict.md` | Verdict final, tableau batch, plan de mise en œuvre |

## Commandes clés

```bash
# Déploiement initial
bash bootstrap.sh

# Recheck intégrité manuel
bash ~/.llm-local/recheck.sh

# Test fonctionnel des modèles
python3 canary_check.py    # (extrait de PARTIE5)

# Benchmark complet
python3 benchmark.py       # (extrait de PARTIE7)

# Logs
tail -f ~/.llm-local/logs/cron.log
cat ~/.llm-local/manifests/manifest.json | jq '.models[] | {name, status}'
```

## Batch de modèles

| Modèle | Rôle | VRAM |
|--------|------|------|
| `phi4-mini` | Router + debug (permanent en VRAM) | 2.4 Go |
| `qwen2.5-coder:7b-instruct` | Code Python/FastAPI/LangGraph | 4.1 Go |
| `granite3.3:8b` | Audit DevSecOps / CI-CD | 4.9 Go |
| `deepseek-r1:7b` | Agent brain / raisonnement | 4.5 Go |
| `mistral:7b-instruct-v0.3-q4_K_M` | Rédaction française | 4.1 Go |
