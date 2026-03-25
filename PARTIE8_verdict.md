# PARTIE 8 — VERDICT FINAL

## Batch final : tableau synthétique

| Modèle | Rôle principal | VRAM Q4_K_M | tok/s (RTX 5060) | Chargement |
|--------|---------------|-------------|-----------------|------------|
| `qwen2.5-coder:7b-instruct` | Code (Python, FastAPI, LangGraph, FIM) | ~4.1 Go | ~65 tok/s | À la demande |
| `granite3.3:8b` | Audit, DevSecOps, CI/CD, enterprise reasoning | ~4.9 Go | ~55 tok/s | À la demande |
| `deepseek-r1:7b` | Agent brain, raisonnement structuré, orchestration | ~4.5 Go | ~60 tok/s | À la demande |
| `phi4-mini` | Debug rapide, routing, sanity check | ~2.4 Go | ~113 tok/s | Permanent |
| `mistral:7b-instruct-v0.3-q4_K_M` | Rédaction française, fallback général | ~4.1 Go | ~65 tok/s | À la demande |

**Note RTX 5060 8GB** : bande passante 272 GB/s → un seul modèle 7-8B en VRAM à la
fois. phi4-mini (2.4 Go) peut coexister avec n'importe quel modèle du batch.
Swap Ollama automatique : ~3-5s de latence au premier appel après inactivité (30min).

---

## Rôles par modèle

| Fonction | Modèle affecté | Justification |
|----------|---------------|---------------|
| **Modèle pivot** (polyvalent) | `deepseek-r1:7b` | Chain-of-thought, raisonnement explicite → fallback universel |
| **Modèle router** | `phi4-mini` | 2.4 Go VRAM → toujours en mémoire, classify en <1s |
| **Modèle code** | `qwen2.5-coder:7b-instruct` | FIM natif, 128K ctx, meilleur < 8B sur Python/LangGraph |
| **Modèle audit** | `granite3.3:8b` | Entraîné sur données enterprise, outil-calling robuste |
| **Modèle rédaction** | `mistral:7b-instruct-v0.3` | Référence historique francophone, registre naturel |
| **Modèle debug** | `phi4-mini` | 3.8B, fort raisonnement/taille, réponse rapide |

---

## Chargement GPU

```
Permanent (toujours en VRAM) :
  • phi4-mini          → routing + debug instant

À la demande (swap automatique Ollama) :
  • qwen2.5-coder:7b-instruct   → tâches code
  • granite3.3:8b      → tâches audit
  • deepseek-r1:7b              → orchestration / raisonnement complexe
  • mistral:7b-instruct-v0.3    → rédaction française
```

---

## À éviter absolument

| Ce qu'il ne faut pas faire | Raison |
|---------------------------|--------|
| Charger deux modèles 7B+ simultanément | 8 GB VRAM → OOM ou dégradation vers CPU (×10 plus lent) |
| `deepseek-r1:7b` pour génération de code FIM | R1 raisonne, ne complète pas. Utiliser qwen2.5-coder |
| `qwen2.5-coder` pour audit sécurité | Pas entraîné sur frameworks audit enterprise / NIS2 |
| `phi4-mini` pour rédaction longue (>500 mots) | Contexte court, cohérence se dégrade sur long format |
| `mistral:7b` comme modèle pivot | Aucun chain-of-thought, pas de tool calling natif en v0.3 |
| Nemotron-3-Nano-4B en remplacement de deepseek-r1 | Architecture hybride Mamba → support llama.cpp partiel, comportement imprévisible sur outil-calling |
| Quantization Q2_K ou Q3_K_S | Dégradation qualité audit inacceptable, économie VRAM marginale |
| `ollama run` en mode streaming pour le benchmark | Fausse les tok/s — utiliser l'API REST ou SDK Python |

---

## Évaluation des modèles demandés

### Nemotron-3-Nano-4B (architecture hybride Mamba-Transformer)
**Exclus du batch principal.** Raisons :
- Architecture SSM hybride → support Ollama/llama.cpp présent mais non stable pour tous les cas
- Tool calling (OpenAI function calling) non validé sur cette architecture en production
- DeepSeek-R1-7B fait strictement mieux sur raisonnement structuré pour LangGraph
- **Cas d'usage légitime** : si un contexte >100K tokens est nécessaire (analyse de codebase entier), Nemotron-3-Nano est candidat. Configurer via Modelfile GGUF manuel.

### OpenCoder-8B-Instruct
**Non retenu.** Raisons :
- 8B → 4.9 Go VRAM, même budget que Granite mais spécialisé code uniquement
- Qwen2.5-Coder-7B le surpasse sur Python/FastAPI selon benchmarks HumanEval/MBPP
- Aucun avantage différenciant pour le profil de tâches défini

### Qwen2.5-Coder-7B vs alternatives code
**Confirmé meilleur choix** : FIM natif (Fill-in-the-Middle) pour complétion
inline, contexte 128K, scores HumanEval >85%. Pas de concurrent crédible <8B
sur Python/FastAPI/LangGraph en local à ce jour.

---

## Plan de mise en œuvre (5 étapes dans l'ordre)

```
1. INFRASTRUCTURE (J1 — 30 min)
   bash bootstrap.sh
   → Téléchargement des 5 modèles, vérification intégrité, manifest.json,
     cron quotidien. Vérifier : ~/.llm-local/manifests/manifest.json

2. ORCHESTRATEUR (J1-J2 — 2-3h)
   Implémenter le graph LangGraph décrit en PARTIE2 :
     /home/gloaguen/projets/local-llm-orchestrator/src/orchestrator/
   Valider le routing sur 5 prompts types (un par rôle).

3. BENCHMARK (J3 — 1-2h)
   Lancer le script PARTIE7_benchmark.py sur les 5 modèles.
   Seuil d'acceptation : qualité moyenne ≥ 0.7/1.0, stabilité ≥ 0.8.
   Ajuster le routing si un modèle sous-performe sur son rôle assigné.

4. INTÉGRATION (J4-J5 — variable)
   Intégrer l'orchestrateur dans les projets actifs :
     • local-llm-orchestrator : remplacer appels Gemini/Claude par dispatch local
     • log-analyzer-anssi : modèle audit (granite3.3) sur pipeline Sigma
     • multi-agent-orchestrator : deepseek-r1 comme cerveau agent local

5. OPÉRATIONNEL (J7+)
   Vérifier les premiers rapports cron (07h00).
   Lire : ~/.llm-local/logs/integrity_YYYYMMDD.log
   Si status "unverified" persiste : acceptable (comportement Ollama normal).
   Si "quarantine" : re-pull + recheck manuel.
```

---

## Récapitulatif commandes d'installation

```bash
# Pull complet (aussi fait par bootstrap.sh)
ollama pull qwen2.5-coder:7b-instruct
ollama pull granite3.3:8b
ollama pull deepseek-r1:7b
ollama pull phi4-mini
ollama pull mistral:7b-instruct-v0.3-q4_K_M

# Vérifier
ollama list

# Test rapide (phi4-mini toujours en VRAM)
ollama run phi4-mini "Explique en une ligne ce que fait set -euo pipefail"

# Recheck manuel
bash ~/.llm-local/recheck.sh
```
