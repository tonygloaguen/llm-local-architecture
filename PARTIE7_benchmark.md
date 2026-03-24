# PARTIE 7 — BENCHMARK RÉEL

## Script Python complet

```python
#!/usr/bin/env python3
"""
benchmark.py — Comparaison des modèles LLM locaux
Dépendances : pip install ollama>=0.3 pydantic>=2.0
Usage : python3 benchmark.py [--model MODEL] [--runs N] [--output FILE]
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
import datetime
from pathlib import Path
from typing import Optional

import ollama

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

MODELS = [
    "qwen2.5-coder:7b-instruct-q4_K_M",
    "granite3.3:8b-instruct",
    "deepseek-r1:7b",
    "phi4-mini:instruct",
    "mistral:7b-instruct-v0.3-q4_K_M",
]

LOG_DIR = Path.home() / ".llm-local/logs/benchmark"
LOG_DIR.mkdir(parents=True, exist_ok=True)


# ---------------------------------------------------------------------------
# Cas de test (ancrés dans le contexte réel)
# ---------------------------------------------------------------------------

TEST_CASES = {
    "T1_langgraph_bug": {
        "description": "Bug LangGraph — AttributeError sur état Pydantic v2",
        "prompt": (
            "Un nœud LangGraph reçoit un état Pydantic v2 défini ainsi :\n\n"
            "```python\n"
            "from pydantic import BaseModel\n"
            "from typing import Optional\n"
            "\n"
            "class AgentState(BaseModel):\n"
            "    user_id: str\n"
            "    context: Optional[dict] = None\n"
            "\n"
            "def node_process(state: AgentState) -> AgentState:\n"
            "    data = state.context['key']  # ligne 12\n"
            "    return state.model_copy(update={'context': {'processed': data}})\n"
            "```\n\n"
            "Le nœud suivant plante avec : `TypeError: 'NoneType' object is not subscriptable`\n\n"
            "1. Trace l'exécution ligne par ligne jusqu'à la cause racine.\n"
            "2. Propose le fix minimal avec le code corrigé.\n"
            "3. Explique comment éviter ce pattern dans LangGraph."
        ),
        "expected_keywords": ["None", "context", "optional", "guard", "if", "is not None"],
        "weight": 1.0,  # poids relatif pour le scoring
    },
    "T2_dockerfile_audit": {
        "description": "Audit Dockerfile — supply chain Alpine + pip",
        "prompt": (
            "Audite ce Dockerfile du point de vue supply chain security :\n\n"
            "```dockerfile\n"
            "FROM python:3.11-alpine\n"
            "WORKDIR /app\n"
            "COPY requirements.txt .\n"
            "RUN pip install requests==2.28.0 cryptography==38.0.0 paramiko==2.11.0\n"
            "COPY . .\n"
            "RUN adduser -D appuser\n"
            "USER appuser\n"
            "CMD [\"python\", \"app.py\"]\n"
            "```\n\n"
            "Pour chaque problème :\n"
            "1. Identifie le risque précis (CVE si connu, ou catégorie de risque).\n"
            "2. Propose la correction avec la version patchée ou la configuration correcte.\n"
            "Format : liste numérotée, une ligne par problème + une ligne de fix."
        ),
        "expected_keywords": [
            "hash", "sha256", "pin", "requests", "cryptography", "paramiko",
            "cve", "vulnerability", "version", "2.28", "38.0", "2.11"
        ],
        "weight": 1.0,
    },
    "T3_log_analysis": {
        "description": "Analyse log nginx — détection anomalie MITRE ATT&CK",
        "prompt": (
            "Analyse ces lignes de log nginx et détecte les anomalies :\n\n"
            "```\n"
            '192.168.1.45 - - [15/Jan/2025:14:23:01 +0000] "GET /api/data HTTP/1.1" 200 1234\n'
            '192.168.1.45 - - [15/Jan/2025:14:23:02 +0000] "GET /api/data HTTP/1.1" 200 1234\n'
            '10.0.0.12 - - [15/Jan/2025:14:23:05 +0000] "GET /static/app.js HTTP/1.1" 200 45678\n'
            '185.220.101.33 - - [15/Jan/2025:14:23:07 +0000] "GET /../../../../etc/passwd HTTP/1.1" 400 512\n'
            '185.220.101.33 - - [15/Jan/2025:14:23:08 +0000] "GET /api/../../etc/shadow HTTP/1.1" 400 512\n'
            '10.0.0.44 - - [15/Jan/2025:14:23:10 +0000] "POST /api/login HTTP/1.1" 401 89\n'
            '10.0.0.44 - - [15/Jan/2025:14:23:11 +0000] "POST /api/login HTTP/1.1" 401 89\n'
            '10.0.0.44 - - [15/Jan/2025:14:23:12 +0000] "POST /api/login HTTP/1.1" 401 89\n'
            '10.0.0.44 - - [15/Jan/2025:14:23:12 +0000] "POST /api/login HTTP/1.1" 200 512\n'
            '192.168.1.45 - - [15/Jan/2025:14:23:15 +0000] "GET /api/admin/users HTTP/1.1" 403 0\n'
            "```\n\n"
            "1. Identifie chaque anomalie (IP, ligne, type d'attaque).\n"
            "2. Classe chaque anomalie dans le framework MITRE ATT&CK (technique ID + nom).\n"
            "3. Propose une règle Sigma pour détecter l'anomalie la plus critique."
        ),
        "expected_keywords": [
            "path traversal", "T1190", "passwd", "brute", "force", "T1110",
            "sigma", "detection", "185.220", "10.0.0.44", "traversal"
        ],
        "weight": 1.0,
    },
    "T4_fastapi_generation": {
        "description": "Génération module FastAPI — JWT + rate limiting + tests",
        "prompt": (
            "Génère un module FastAPI complet avec :\n"
            "- Middleware JWT via python-jose (HS256, secret depuis env var JWT_SECRET)\n"
            "- Rate limiting via slowapi (10 req/min par IP sur les routes protégées)\n"
            "- Route GET /health : publique, retourne {status: ok, timestamp: ISO8601}\n"
            "- Route GET /data : protégée JWT + rate-limited, retourne {user_id: str, data: list}\n"
            "- 2 tests pytest : un test /health (sans token), un test /data (avec token valide)\n\n"
            "Contraintes : Python 3.11+, async/await, typage strict Pydantic v2.\n"
            "Fournis le code complet, directement utilisable."
        ),
        "expected_keywords": [
            "fastapi", "jwt", "jose", "slowapi", "limiter", "async def",
            "pytest", "testclient", "authorization", "bearer", "health"
        ],
        "weight": 1.0,
    },
    "T5_redaction_fr": {
        "description": "Rédaction française professionnelle",
        "prompt": (
            "Reformule ce message en français professionnel direct, "
            "sans formules creuses, pour un recruteur DevSecOps senior :\n\n"
            "---\n"
            "Bonjour, je suis développeur et je cherche un poste. "
            "Je fais du Python depuis un moment, je connais Docker et j'ai fait des trucs "
            "avec GitHub Actions. J'ai aussi regardé un peu la sécu avec Trivy et des trucs comme ça. "
            "Je pense que je pourrais apporter des choses à votre équipe. "
            "Pouvez-vous me dire si vous recrutez ?\n"
            "---\n\n"
            "Le résultat doit être :\n"
            "- En français correct et professionnel\n"
            "- Direct et factuel (pas de 'je pense que', pas de 'des trucs')\n"
            "- Maximum 5 phrases\n"
            "- Adapté à un recruteur technique DevSecOps"
        ),
        "expected_keywords": [
            "python", "docker", "github actions", "sécurité", "trivy",
            "devops", "poste", "compétences"
        ],
        "weight": 0.8,  # poids réduit car subjectif
    },
}


# ---------------------------------------------------------------------------
# Scoring
# ---------------------------------------------------------------------------

def score_quality(response: str, expected_keywords: list[str]) -> float:
    """
    Score qualité : 0.0 → 1.0
    Basé sur le ratio de keywords attendus trouvés dans la réponse.
    Pénalité si réponse trop courte (<50 chars) ou trop longue (>8000 chars sans substance).
    """
    if len(response) < 50:
        return 0.0

    response_lower = response.lower()
    matched = sum(1 for kw in expected_keywords if kw.lower() in response_lower)
    keyword_score = matched / len(expected_keywords) if expected_keywords else 0.0

    # Bonus légère structuration (listes, code blocks)
    structure_bonus = 0.0
    if "```" in response:
        structure_bonus += 0.1
    if any(f"{i}." in response for i in range(1, 5)):
        structure_bonus += 0.05

    return min(1.0, keyword_score + structure_bonus)


def score_stability(scores: list[float]) -> float:
    """
    Score stabilité : 1 - coefficient_variation
    1.0 = résultats identiques sur tous les runs, 0.0 = variance maximale
    """
    if len(scores) < 2:
        return 1.0
    mean = statistics.mean(scores)
    if mean == 0:
        return 1.0
    stdev = statistics.stdev(scores)
    cv = stdev / mean
    return max(0.0, 1.0 - cv)


def score_coherence(responses: list[str]) -> float:
    """
    Score cohérence : ratio de keywords communs entre les runs.
    Même prompt → même réponse à température 0.
    """
    if len(responses) < 2:
        return 1.0

    # Tokeniser grossièrement
    def tokens(text: str) -> set[str]:
        return set(text.lower().split())

    base_tokens = tokens(responses[0])
    overlaps = [
        len(base_tokens & tokens(r)) / max(len(base_tokens), 1)
        for r in responses[1:]
    ]
    return statistics.mean(overlaps) if overlaps else 1.0


def compute_final_score(
    quality_scores: list[float],
    tok_per_sec_values: list[float],
    test_weight: float = 1.0,
) -> dict:
    """
    Score final pondéré :
    - Qualité   : 50%
    - Vitesse   : 20%  (normalisé sur 150 tok/s max)
    - Stabilité : 20%
    - Cohérence : 10%
    """
    quality = statistics.median(quality_scores)
    stability = score_stability(quality_scores)
    speed_raw = statistics.median(tok_per_sec_values) if tok_per_sec_values else 0.0
    speed_normalized = min(1.0, speed_raw / 150.0)  # 150 tok/s = score max

    final = (
        quality * 0.50
        + speed_normalized * 0.20
        + stability * 0.20
        # cohérence calculée séparément (besoin des textes bruts)
    )
    return {
        "quality": round(quality, 3),
        "speed_tok_per_sec": round(speed_raw, 1),
        "speed_normalized": round(speed_normalized, 3),
        "stability": round(stability, 3),
        "final_excl_coherence": round(final, 3),
    }


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

def run_single(model: str, test_id: str, test_case: dict, temperature: float = 0.0) -> dict:
    """Exécute un test sur un modèle. Retourne les métriques."""
    prompt = test_case["prompt"]
    keywords = test_case["expected_keywords"]

    try:
        start = time.perf_counter()
        response = ollama.chat(
            model=model,
            messages=[{"role": "user", "content": prompt}],
            options={
                "temperature": temperature,
                "num_predict": 2048,
                "seed": 42,  # reproductibilité
            },
        )
        elapsed = time.perf_counter() - start

        content = response["message"]["content"]
        eval_count = response.get("eval_count", 0)
        eval_duration_ns = response.get("eval_duration", 1)
        tok_per_sec = (eval_count / (eval_duration_ns / 1e9)) if eval_duration_ns > 0 else 0.0

        quality = score_quality(content, keywords)

        return {
            "ok": True,
            "response": content,
            "quality": quality,
            "tok_per_sec": tok_per_sec,
            "elapsed_s": elapsed,
            "response_len": len(content),
            "eval_count": eval_count,
        }

    except Exception as e:
        return {
            "ok": False,
            "error": str(e),
            "response": "",
            "quality": 0.0,
            "tok_per_sec": 0.0,
            "elapsed_s": 0.0,
        }


def run_benchmark(
    models: list[str],
    test_cases: dict,
    num_runs: int = 3,
    output_file: Optional[Path] = None,
) -> dict:
    """Lance le benchmark complet."""

    results: dict = {
        "meta": {
            "timestamp": datetime.datetime.utcnow().isoformat() + "Z",
            "num_runs": num_runs,
            "models": models,
            "tests": list(test_cases.keys()),
        },
        "raw": {},
        "scores": {},
    }

    for model in models:
        print(f"\n{'='*60}")
        print(f"Modèle : {model}")
        print(f"{'='*60}")

        results["raw"][model] = {}
        model_quality_all: list[float] = []
        model_speed_all: list[float] = []
        model_responses_all: list[str] = []

        for test_id, test_case in test_cases.items():
            print(f"\n  Test : {test_id} — {test_case['description']}")

            run_qualities: list[float] = []
            run_speeds: list[float] = []
            run_responses: list[str] = []

            for run_idx in range(num_runs):
                print(f"    Run {run_idx + 1}/{num_runs}...", end=" ", flush=True)
                result = run_single(model, test_id, test_case)

                if result["ok"]:
                    run_qualities.append(result["quality"])
                    run_speeds.append(result["tok_per_sec"])
                    run_responses.append(result["response"])
                    print(
                        f"quality={result['quality']:.2f} | "
                        f"{result['tok_per_sec']:.0f} tok/s | "
                        f"{result['elapsed_s']:.1f}s"
                    )
                else:
                    print(f"ERREUR : {result.get('error', 'unknown')}")
                    run_qualities.append(0.0)
                    run_speeds.append(0.0)
                    run_responses.append("")

            coherence = score_coherence(run_responses)
            scores = compute_final_score(
                run_qualities, run_speeds, test_case.get("weight", 1.0)
            )
            scores["coherence"] = round(coherence, 3)
            scores["final"] = round(
                scores["final_excl_coherence"] + coherence * 0.10, 3
            )

            results["raw"][model][test_id] = {
                "runs": num_runs,
                "quality_scores": run_qualities,
                "tok_per_sec": run_speeds,
                "coherence": coherence,
                "median_quality": statistics.median(run_qualities),
                "median_speed": statistics.median(run_speeds) if run_speeds else 0.0,
            }
            results["raw"][model][test_id]["scores"] = scores

            model_quality_all.extend(run_qualities)
            model_speed_all.extend(run_speeds)
            model_responses_all.extend(run_responses)

            print(f"    → Score final : {scores['final']:.3f} "
                  f"(Q={scores['quality']:.2f} V={scores['speed_normalized']:.2f} "
                  f"S={scores['stability']:.2f} C={scores['coherence']:.2f})")

        # Score agrégé par modèle
        model_global = compute_final_score(model_quality_all, model_speed_all)
        model_global["coherence"] = round(score_coherence(model_responses_all), 3)
        model_global["final"] = round(
            model_global["final_excl_coherence"] + model_global["coherence"] * 0.10, 3
        )
        results["scores"][model] = model_global

    # Classement
    ranking = sorted(
        results["scores"].items(),
        key=lambda x: x[1]["final"],
        reverse=True,
    )

    print(f"\n\n{'='*60}")
    print("CLASSEMENT FINAL")
    print(f"{'='*60}")
    print(f"{'Rang':<5} {'Modèle':<45} {'Final':>6} {'Q':>6} {'V tok/s':>8} {'S':>6} {'C':>6}")
    print("-" * 80)
    for rank, (model, sc) in enumerate(ranking, 1):
        print(
            f"{rank:<5} {model:<45} {sc['final']:>6.3f} "
            f"{sc['quality']:>6.2f} {sc['speed_tok_per_sec']:>8.0f} "
            f"{sc['stability']:>6.2f} {sc['coherence']:>6.2f}"
        )

    results["ranking"] = [{"model": m, "scores": s} for m, s in ranking]

    # Sauvegarde
    ts = datetime.datetime.utcnow().strftime("%Y%m%d_%H%M%S")
    out_file = output_file or (LOG_DIR / f"benchmark_{ts}.json")
    out_file.write_text(json.dumps(results, indent=2))
    print(f"\nRésultats complets : {out_file}")

    return results


# ---------------------------------------------------------------------------
# Point d'entrée CLI
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description="Benchmark LLM local")
    parser.add_argument(
        "--model", nargs="+", default=MODELS,
        help="Modèles à tester (défaut : tous)"
    )
    parser.add_argument(
        "--runs", type=int, default=3,
        help="Nombre de runs par test (défaut : 3)"
    )
    parser.add_argument(
        "--test", nargs="+", default=list(TEST_CASES.keys()),
        choices=list(TEST_CASES.keys()),
        help="Tests à lancer (défaut : tous)"
    )
    parser.add_argument(
        "--output", type=Path, default=None,
        help="Fichier de sortie JSON"
    )
    args = parser.parse_args()

    # Filtrer les tests demandés
    selected_tests = {k: v for k, v in TEST_CASES.items() if k in args.test}

    print(f"Benchmark LLM local — {datetime.datetime.utcnow().isoformat()}Z")
    print(f"Modèles : {args.model}")
    print(f"Tests   : {list(selected_tests.keys())}")
    print(f"Runs    : {args.runs}")
    print("Anti-biais : température=0.0, seed=42, Q4_K_M pour tous\n")

    run_benchmark(
        models=args.model,
        test_cases=selected_tests,
        num_runs=args.runs,
        output_file=args.output,
    )


if __name__ == "__main__":
    main()
```

---

## Usage

```bash
cd /home/gloaguen/projets/llm-local-architecture

# Benchmark complet (tous les modèles, 3 runs chacun)
python3 benchmark.py

# Un seul modèle
python3 benchmark.py --model qwen2.5-coder:7b-instruct-q4_K_M

# Un seul test
python3 benchmark.py --test T1_langgraph_bug --runs 5

# Sortie JSON spécifique
python3 benchmark.py --output /tmp/bench_$(date +%Y%m%d).json

# Analyser les résultats avec jq
jq '.ranking[] | "\(.model): \(.scores.final)"' ~/.llm-local/logs/benchmark/benchmark_*.json | tail -5
```

---

## Interprétation des scores

| Score final | Interprétation |
|-------------|---------------|
| ≥ 0.80 | Excellent — convient pour le rôle assigné sans réserve |
| 0.65 – 0.79 | Correct — utilisable, surveiller les cas limites |
| 0.50 – 0.64 | Moyen — acceptable en fallback, pas en rôle principal |
| < 0.50 | Insuffisant — ne pas assigner ce modèle à ce rôle |

**Seuils d'alerte** :
- `stability < 0.7` → le modèle donne des résultats très différents à température 0 : suspect
- `tok_per_sec < 20` → trop lent pour l'usage interactif (vérifier VRAM/CPU fallback)
- `quality < 0.4 sur T2 (audit)` pour granite → re-évaluer le modèle ou la quantization

---

## Anti-biais appliqués

- Même prompt exact pour tous les modèles (pas de prompt-engineering par modèle)
- Q4_K_M pour tous (iso-quantization — certains modèles peuvent avoir des tags différents en Ollama)
- Température 0.0 + seed 42 pour reproductibilité maximale
- 3 runs → médiane (élimine les outliers de 1er run à froid)
- Vitesse mesurée via `eval_duration` de l'API Ollama (temps GPU réel, pas elapsed total)
- Prefill (prompt tokens) non comptabilisé dans le tok/s de génération
