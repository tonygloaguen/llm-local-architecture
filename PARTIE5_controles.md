# PARTIE 5 — CONTRÔLES RÉGULIERS

## Tableau de contrôles récurrents

| Contrôle | Fréquence | Objectif | Outil | Action si anomalie |
|----------|-----------|----------|-------|--------------------|
| Recheck SHA-256 blobs modèles | Quotidien (07h00) | Détecter drift/corruption | `recheck.sh` | Quarantaine automatique + re-pull |
| Inventaire modèles vs manifest | Quotidien | Détecter modèle fantôme ou manquant | `ollama list` diff manifest | Supprimer fantôme ou re-pull manquant |
| Prompt canari par modèle | Hebdomadaire | Valider fonctionnement minimal | `canary_check.py` | Alerter + vérifier intégrité |
| Scan Trivy images Docker | Hebdomadaire | CVE sur images actives | `trivy image` | Mise à jour image ou mitigation |
| pip-audit venv orchestrateur | Hebdomadaire | Vulnérabilités dépendances Python | `pip-audit` | Mettre à jour package vulnérable |
| Contrôle VRAM/GPU | Quotidien | Détecter fuite mémoire GPU | `nvidia-smi` | Restart Ollama si VRAM non libérée |
| Vérification ports exposés | Quotidien | Détecter exposition réseau inattendue | `ss -tlnp` | Couper le process + audit |
| Intégrité Modelfiles/templates | Hebdomadaire | Détecter modification template | `audit_modelfiles.sh` | Comparer baseline + re-pull |
| Revue logs Ollama | Hebdomadaire | Détecter erreurs répétées | `journalctl -u ollama` | Debug selon erreur |
| Contrôle accès et permissions | Mensuel | Détecter élargissement perms | `find ~/.ollama -perm /o+r` | Corriger chmod |

---

## Scripts automatisables

### Contrôle quotidien complet (wrapper)

```bash
#!/usr/bin/env bash
# daily_check.sh — wrapper de tous les contrôles quotidiens
# Cron : 0 7 * * * bash ~/.llm-local/daily_check.sh >> ~/.llm-local/logs/cron.log 2>&1
set -euo pipefail

LOG="${HOME}/.llm-local/logs/daily_$(date +%Y%m%d).log"
ERRORS=0

log() { echo "[$(date -u +%H:%M:%SZ)] $1" | tee -a "$LOG"; }

log "=== Contrôle quotidien démarré ==="

# 1. Recheck SHA-256
log "→ Recheck intégrité..."
bash "${HOME}/.llm-local/recheck.sh" >> "$LOG" 2>&1 || { log "⚠️ DRIFT détecté"; ERRORS=$((ERRORS+1)); }

# 2. Inventaire modèles vs manifest
log "→ Inventaire modèles..."
MANIFEST_MODELS=$(jq -r '.models[].name' "${HOME}/.llm-local/manifests/manifest.json" 2>/dev/null | sort)
OLLAMA_MODELS=$(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' | sort)

PHANTOM=$(comm -13 <(echo "$MANIFEST_MODELS") <(echo "$OLLAMA_MODELS") | tr '\n' ' ')
MISSING=$(comm -23 <(echo "$MANIFEST_MODELS") <(echo "$OLLAMA_MODELS") | tr '\n' ' ')

[[ -n "$PHANTOM" ]] && { log "⚠️ Modèles fantômes : $PHANTOM"; ERRORS=$((ERRORS+1)); } || log "  Pas de modèle fantôme"
[[ -n "$MISSING" ]] && { log "⚠️ Modèles manquants : $MISSING"; ERRORS=$((ERRORS+1)); } || log "  Tous les modèles présents"

# 3. Vérification ports
log "→ Vérification ports..."
EXPOSED=$(ss -tlnp 2>/dev/null | grep -E ':11434|:3000|:8080' | grep -v '127.0.0.1' || true)
[[ -n "$EXPOSED" ]] && { log "⚠️ Port LLM exposé sur réseau : $EXPOSED"; ERRORS=$((ERRORS+1)); } || log "  Ports LLM locaux uniquement ✅"

# 4. VRAM
log "→ Contrôle VRAM..."
VRAM_USED=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null || echo "0")
VRAM_TOTAL=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null || echo "8192")
VRAM_PCT=$(( VRAM_USED * 100 / VRAM_TOTAL ))
log "  VRAM : ${VRAM_USED}/${VRAM_TOTAL} MiB (${VRAM_PCT}%)"
(( VRAM_PCT > 90 )) && { log "⚠️ VRAM > 90% sans charge active"; ERRORS=$((ERRORS+1)); } || true

log "=== Résumé : $([[ $ERRORS -eq 0 ]] && echo 'TOUT OK ✅' || echo "$ERRORS ANOMALIE(S) ⚠️") ==="
exit $ERRORS
```

---

### Prompt canari par modèle (test fonctionnel hebdomadaire)

```python
#!/usr/bin/env python3
"""
canary_check.py — Test fonctionnel minimal de chaque modèle
Exécution : python3 canary_check.py
Exit 0 = tous OK, Exit 1 = au moins un modèle KO
"""
import sys
import json
import time
import datetime
from pathlib import Path
import ollama

CANARY_PROMPTS = {
    "qwen2.5-coder:7b-instruct": {
        "prompt": "Write a Python one-liner to compute SHA-256 of a string. Only code, no explanation.",
        "expected_keywords": ["import hashlib", "sha256", "encode", "hexdigest"],
        "timeout": 30,
    },
    "granite3.3:8b": {
        "prompt": "List 3 critical security issues with 'RUN pip install requests' in a Dockerfile. One line each.",
        "expected_keywords": ["version", "hash", "pin", "supply", "trust", "verify"],
        "timeout": 30,
    },
    "deepseek-r1:7b": {
        "prompt": "What is 15 * 7? Answer with the number only.",
        "expected_keywords": ["105"],
        "timeout": 60,
    },
    "phi4-mini": {
        "prompt": "What does 'set -euo pipefail' do? One sentence.",
        "expected_keywords": ["exit", "error", "unset", "pipe"],
        "timeout": 20,
    },
    "mistral:7b-instruct-v0.3-q4_K_M": {
        "prompt": "Traduis en français : 'The deployment failed due to a missing environment variable.'",
        "expected_keywords": ["déploiement", "variable", "environnement", "manquant"],
        "timeout": 30,
    },
}

LOG_DIR = Path.home() / ".llm-local/logs"
LOG_FILE = LOG_DIR / f"canary_{datetime.date.today().strftime('%Y%m%d')}.log"


def run_canary(model: str, config: dict) -> tuple[bool, str]:
    try:
        start = time.time()
        response = ollama.chat(
            model=model,
            messages=[{"role": "user", "content": config["prompt"]}],
            options={"temperature": 0.0, "num_predict": 256},
        )
        elapsed = time.time() - start
        content = response["message"]["content"].lower()

        # Vérifier la présence d'au moins 1 keyword attendu
        matched = [kw for kw in config["expected_keywords"] if kw.lower() in content]

        if matched:
            return True, f"OK ({elapsed:.1f}s) — keywords: {matched}"
        else:
            return False, f"FAIL — aucun keyword trouvé dans : '{content[:100]}...'"

    except Exception as e:
        return False, f"ERROR — {e}"


def main() -> int:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    results = {}
    global_ok = True

    print(f"=== Canary check {datetime.datetime.utcnow().isoformat()}Z ===")

    for model, config in CANARY_PROMPTS.items():
        ok, msg = run_canary(model, config)
        results[model] = {"ok": ok, "message": msg}
        status = "✅" if ok else "❌"
        print(f"  {status} {model:<45} {msg}")
        if not ok:
            global_ok = False

    # Log
    with open(LOG_FILE, "a") as f:
        f.write(json.dumps({
            "timestamp": datetime.datetime.utcnow().isoformat() + "Z",
            "results": results,
        }) + "\n")

    print(f"\nLog : {LOG_FILE}")
    return 0 if global_ok else 1


if __name__ == "__main__":
    sys.exit(main())
```

---

### Contrôle VRAM et processus Ollama

```bash
# Snapshot VRAM (à intégrer dans daily_check.sh ou cron séparé)
nvidia-smi --query-gpu=name,memory.used,memory.total,temperature.gpu,utilization.gpu \
  --format=csv,noheader | tee -a "${HOME}/.llm-local/logs/vram_$(date +%Y%m%d).csv"

# Vérifier si un modèle est chargé en VRAM sans usage actif
# (Ollama garde le modèle 30min par défaut avant déchargement)
ollama ps 2>/dev/null | tee -a "${HOME}/.llm-local/logs/vram_$(date +%Y%m%d).csv"

# Forcer le déchargement d'un modèle si besoin (libère VRAM)
# ollama stop <model_name>
```

---

### Vérification ports exposés

```bash
# Contrôle des ports LLM/WebUI
# Attendu : uniquement 127.0.0.1 pour les ports 11434, 3000, 8080
check_ports() {
  local issues=0
  for port in 11434 3000 8080 8000; do
    local result
    result=$(ss -tlnp "sport = :${port}" 2>/dev/null | grep -v "127.0.0.1\|State" || true)
    if [[ -n "$result" ]]; then
      echo "⚠️ Port ${port} exposé hors localhost : $result"
      issues=$((issues+1))
    fi
  done
  [[ $issues -eq 0 ]] && echo "✅ Tous les ports LLM sur 127.0.0.1 uniquement"
  return $issues
}
check_ports
```

---

### Contrôle Ollama logs — erreurs répétées

```bash
# Résumé des erreurs Ollama sur les dernières 24h
journalctl -u ollama --since "24 hours ago" --no-pager \
  | grep -iE "(error|failed|panic|fatal|oom|killed)" \
  | sort | uniq -c | sort -rn \
  | head -20 \
  | tee "${HOME}/.llm-local/logs/ollama_errors_$(date +%Y%m%d).log"
```

---

### Intégrité Modelfiles (voir aussi PARTIE3 §6)

```bash
# Détecter si un template a changé depuis la baseline
BASELINE="${HOME}/.llm-local/checksums/modelfiles_baseline.log"
CURRENT="${HOME}/.llm-local/checksums/modelfiles_$(date +%Y%m%d).log"

bash /home/gloaguen/projets/llm-local-architecture/audit_modelfiles.sh > "$CURRENT"

if [[ -f "$BASELINE" ]]; then
  DIFF=$(diff "$BASELINE" "$CURRENT" || true)
  if [[ -n "$DIFF" ]]; then
    echo "⚠️ Drift Modelfiles détecté :"
    echo "$DIFF"
  else
    echo "✅ Modelfiles identiques à la baseline"
  fi
else
  echo "Baseline créée : $CURRENT"
  cp "$CURRENT" "$BASELINE"
fi
```

---

## Fréquences consolidées

```
QUOTIDIEN (cron 07:00 — daily_check.sh) :
  ✓ Recheck SHA-256 des blobs
  ✓ Inventaire modèles vs manifest
  ✓ Vérification ports exposés
  ✓ Snapshot VRAM

HEBDOMADAIRE (cron 08:00 lundi) :
  ✓ Prompt canari × 5 modèles         → canary_check.py
  ✓ Scan Trivy images Docker actives   → trivy image ...
  ✓ pip-audit venv orchestrateur       → pip-audit
  ✓ Revue logs Ollama (erreurs)        → journalctl résumé
  ✓ Intégrité Modelfiles vs baseline   → audit_modelfiles.sh + diff

MENSUEL (manuel) :
  ✓ Revue permissions ~/.llm-local et ~/.ollama
  ✓ Mise à jour Ollama si nouvelle version stable
  ✓ Évaluation de nouveaux modèles candidats
  ✓ Vérification crontab complet
  ✓ Revue manifest.json (cohérence statuts)
  ✓ Test de la procédure de restore (re-pull un modèle)
```

---

## Crontab complet recommandé

```bash
# Installer avec : crontab -e
# LLM local — contrôles quotidiens
0 7 * * * /home/gloaguen/.llm-local/recheck.sh >> /home/gloaguen/.llm-local/logs/cron.log 2>&1
0 7 * * * bash /home/gloaguen/.llm-local/daily_check.sh >> /home/gloaguen/.llm-local/logs/cron.log 2>&1
# LLM local — contrôles hebdomadaires (lundi 08h)
0 8 * * 1 python3 /home/gloaguen/projets/llm-local-architecture/canary_check.py >> /home/gloaguen/.llm-local/logs/cron.log 2>&1
0 8 * * 1 pip-audit -r /home/gloaguen/projets/local-llm-orchestrator/requirements.txt >> /home/gloaguen/.llm-local/logs/pip_audit_$(date +\%Y\%m\%d).log 2>&1
```
