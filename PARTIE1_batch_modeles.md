# PARTIE 1 — BATCH OPTIMAL DE MODÈLES

## Contrainte matérielle : RTX 5060 8 Go VRAM / 272 GB/s

- Fenêtre VRAM effective : ~7.0 Go (OS/Ollama overhead ~1 Go)
- Un seul modèle 7-8B en VRAM à la fois
- phi4-mini (2.4 Go) peut coexister avec n'importe quel autre modèle
- Estimation tok/s : `bande_passante_GB_s / taille_modèle_GB` ≈ tokens/s génération
- Prefill (prompt processing) : ~3-5× plus rapide que génération

---

## Modèle A — Code (génération, refactoring, FIM, LangGraph)

**`qwen2.5-coder:7b-instruct`**

```bash
ollama pull qwen2.5-coder:7b-instruct
```

| Attribut | Valeur |
|----------|--------|
| Paramètres | 7B |
| Architecture | Transformer dense |
| Contexte | 128K tokens |
| VRAM Q4_K_M | ~4.1 Go |
| tok/s RTX 5060 | ~65 tok/s (génération) |
| Quantization recommandée | Q4_K_M (qualité/perf optimale) |
| Source HF | Qwen/Qwen2.5-Coder-7B-Instruct |

**Rôle principal** : génération Python, FastAPI, SQLAlchemy, LangGraph, Bash, Docker.
**Rôle secondaire** : complétion FIM (Fill-in-the-Middle) pour auto-complétion inline.

**Intérêt réel** :
- Meilleur modèle <8B sur HumanEval (+85%), MBPP, et benchmarks Python spécifiques
- FIM natif → utilisable comme moteur de complétion dans votre IDE sans API externe
- Contexte 128K → lecture d'un fichier entier pour refactoring cohérent
- Entraîné sur Python/JS/Go/Bash, fortement sur code asynchrone

**Limites concrètes** :
- Raisonnement multi-étapes limité : génère du code correct mais ne "planifie" pas
- Pour LangGraph : génère les nœuds et edges mais pas la logique métier complexe
- Pas de tool calling OpenAI format natif (à wrapper)
- Français moyen : ne pas utiliser pour les commentaires ou docs en français

**À éviter** :
- Ne pas l'utiliser pour des analyses de sécurité (faux positifs/négatifs)
- Ne pas utiliser pour orchestration (manque de raisonnement)
- Éviter Q3_K_S (dégradation sur code complexe)

---

## Modèle B — Orchestrateur / Agent brain / Logique métier

**`deepseek-r1:7b`**

```bash
ollama pull deepseek-r1:7b
```

| Attribut | Valeur |
|----------|--------|
| Paramètres | 7B (distillé depuis R1 671B) |
| Architecture | Transformer dense + chain-of-thought tokens |
| Contexte | 128K tokens |
| VRAM Q4_K_M | ~4.5 Go |
| tok/s RTX 5060 | ~60 tok/s (+ tokens de réflexion internes) |
| Quantization recommandée | Q4_K_M |
| Source HF | deepseek-ai/DeepSeek-R1-Distill-Qwen-7B |

**Rôle principal** : orchestration LangGraph, raisonnement multi-étapes, décision de routing, décomposition de problèmes.
**Rôle secondaire** : debugging complexe nécessitant une trace d'exécution.

**Intérêt réel** :
- Raisonnement structuré via tokens `<think>...</think>` → trace de raisonnement exploitable
- Meilleur modèle <8B pour décomposer une tâche complexe en sous-étapes
- Gère les contradictions et conditions de bord explicitement
- Idéal pour le nœud `router` et `critic` dans un graph LangGraph

**Limites concrètes** :
- Plus lent à l'apparence car génère des tokens de réflexion internes (~30% overhead)
- Ne pas utiliser pour génération de code pure (qwen2.5-coder est meilleur)
- Tool calling : supporté mais moins fiable que granite3.3 sur formats structurés
- Sur Ollama, les tokens `<think>` sont visibles → filtrer en post-traitement si besoin

**À éviter** :
- Ne pas utiliser pour complétion FIM
- Ne pas l'appeler pour des tâches triviales (overhead inutile)

---

## Modèle C — Audit sécurité / DevSecOps / CI-CD

**`granite3.3:8b`**

```bash
ollama pull granite3.3:8b
```

| Attribut | Valeur |
|----------|--------|
| Paramètres | 8B |
| Architecture | Transformer dense (IBM Granite) |
| Contexte | 128K tokens |
| VRAM Q4_K_M | ~4.9 Go |
| tok/s RTX 5060 | ~55 tok/s |
| Quantization recommandée | Q4_K_M |
| Source HF | ibm-granite/granite-3.3-8b-instruct |

**Rôle principal** : audit CI/CD, revue sécurité, analyse de risques, supply chain.
**Rôle secondaire** : tool calling structuré, extraction d'informations from logs/incidents.

**Intérêt réel** :
- IBM a entraîné Granite sur des données enterprise (incidents, rapports sécurité, CVE)
- Tool calling fiable au format OpenAI function calling
- Forte cohérence sur les formats structurés (JSON, YAML, tableaux)
- Répond bien aux questions de type "revue critique" avec un angle risque
- Granite 3.3 spécifiquement entraîné pour les agents enterprise

**Limites concrètes** :
- 4.9 Go → le plus gourmand du batch, ne peut pas coexister avec un autre 7B+
- Génération de code moins fluide que qwen2.5-coder
- Contexte francophone limité : préférer l'anglais pour les prompts d'audit
- Pas de chain-of-thought explicite : conclusions sans trace de raisonnement

**À éviter** :
- Ne pas utiliser pour génération Python pure
- Ne pas utiliser pour rédaction française

---

## Modèle D — Debug rapide / Router / Sanity check

**`phi4-mini`**

```bash
ollama pull phi4-mini
```

| Attribut | Valeur |
|----------|--------|
| Paramètres | 3.8B |
| Architecture | Transformer dense (Microsoft) |
| Contexte | 128K tokens |
| VRAM Q4_K_M | ~2.4 Go |
| tok/s RTX 5060 | ~113 tok/s |
| Quantization recommandée | Q4_K_M |
| Source HF | microsoft/Phi-4-mini-instruct |

**Rôle principal** : classification de tâche (routing), debug rapide, sanity check de sorties.
**Rôle secondaire** : premier filtre pour décider quel modèle appeler.

**Intérêt réel** :
- 2.4 Go VRAM → seul modèle qui reste en permanence en GPU
- ~113 tok/s → réponse quasi-instantanée pour les tâches courtes
- Raisonnement solide pour sa taille (meilleur que Mistral-7B sur benchmarks logique)
- Très bon pour classifier une question en <2s et router vers le bon modèle
- Contexte 128K utilisable même en 3.8B

**Limites concrètes** :
- 3.8B : ne pas confier une analyse sécurité complexe ou un refactoring >100 lignes
- Cohérence qui se dégrade sur les tâches de rédaction >300 mots
- Pas entraîné spécifiquement sur code enterprise

**À éviter** :
- Ne pas utiliser comme seul modèle pour les tâches complexes
- Ne pas utiliser pour l'audit sécurité (trop petit)

**Verdict Phi-4-mini pour debug rapide** : OUI, explicitement. Sa vitesse et sa faible empreinte VRAM en font le modèle de première ligne idéal pour les questions courtes et le routing.

---

## Modèle E — Rédaction professionnelle française

**`mistral:7b-instruct-v0.3-q4_K_M`**

```bash
ollama pull mistral:7b-instruct-v0.3-q4_K_M
```

| Attribut | Valeur |
|----------|--------|
| Paramètres | 7B |
| Architecture | Transformer dense (Mistral AI) |
| Contexte | 32K tokens |
| VRAM Q4_K_M | ~4.1 Go |
| tok/s RTX 5060 | ~65 tok/s |
| Quantization recommandée | Q4_K_M |
| Source HF | mistralai/Mistral-7B-Instruct-v0.3 |

**Rôle principal** : rédaction française professionnelle, synthèses, mails, LinkedIn.
**Rôle secondaire** : fallback général si un autre modèle est indisponible.

**Intérêt réel** :
- Mistral AI est française → Mistral-7B v0.3 a une compréhension du registre français supérieure aux modèles asiatiques
- Registre naturel et non-mécanique en français
- Contexte 32K suffisant pour les tâches de rédaction
- Modèle de référence éprouvé depuis 2023, stable et prévisible

**Limites concrètes** :
- Pas de chain-of-thought, pas de tool calling natif en v0.3
- 32K contexte (inférieur aux autres modèles du batch)
- Peut dériver vers l'anglais sur des prompts techniques mixtes
- Strictement "completor" : ne planifie pas

**Confirmation comme référence rédaction française** : OUI. Sur les benchmarks de rédaction française (HellaSwag-FR, FLORES), Mistral-7B reste supérieur à ses concurrents de même taille malgré son âge. Pour du texte professionnel court-medium, c'est le choix.

---

## Synthèse VRAM / coexistence

```
Scénario A — Task courte (routing) :
  phi4-mini → 2.4 Go VRAM
  Disponible instantanément

Scénario B — Code + review :
  qwen2.5-coder:7b → 4.1 Go (+swap 3-5s)
  puis phi4-mini reste en VRAM pour sanity check

Scénario C — Audit sécurité long :
  granite3.3:8b → 4.9 Go (+swap 3-5s)
  VRAM restante pour phi4-mini : ~2.6 Go → OK

Scénario D — Orchestration complexe :
  deepseek-r1:7b → 4.5 Go (+swap 3-5s)
  puis qwen2.5-coder pour implémentation : swap 3-5s

Scénario IMPOSSIBLE — deux modèles 7B+ simultanément :
  4.1 + 4.5 = 8.6 Go > 7.0 Go disponibles → OOM ou CPU fallback
  → Ne jamais charger deux modèles lourds en parallèle
```

---

## Évaluation Nemotron-3-Nano-4B (demandé explicitement)

**Non inclus dans le batch principal. Voici pourquoi.**

| Critère | Évaluation |
|---------|-----------|
| Architecture | Hybride Mamba-Transformer (SSM) |
| Contexte | 1M tokens — avantage réel |
| VRAM Q4_K_M | ~2.5 Go — excellent |
| tok/s estimé | ~105 tok/s (Mamba = génération rapide) |
| Support Ollama | Partiel — llama.cpp a SSM support depuis fin 2024 |
| Tool calling | Non validé sur architecture hybride en production |

**Verdict** : Nemotron-3-Nano-4B est intéressant **uniquement** si votre usage implique
des contextes >100K tokens (lecture d'un repo entier, analyse de logs long). Dans ce cas
précis, remplacez `deepseek-r1:7b` par Nemotron. Pour les tâches standard du batch,
`deepseek-r1:7b` est strictement supérieur en raisonnement et fiabilité du tool calling.

**Installation si besoin** (via Modelfile car pas en registry Ollama stable) :
```bash
# Télécharger le GGUF depuis HF
huggingface-cli download nvidia/NVIDIA-Nemotron-3-Nano-4B-Instruct \
  --include "*.Q4_K_M.gguf" --local-dir ~/.ollama/imports/nemotron/

# Créer le Modelfile
cat > ~/.llm-local/Modelfile.nemotron << 'EOF'
FROM /home/gloaguen/.ollama/imports/nemotron/Nemotron-3-Nano-4B-Instruct-Q4_K_M.gguf
PARAMETER num_ctx 32768
PARAMETER temperature 0.1
TEMPLATE "{{ .Prompt }}"
EOF

# Importer dans Ollama
ollama create nemotron-nano:4b -f ~/.llm-local/Modelfile.nemotron
```
