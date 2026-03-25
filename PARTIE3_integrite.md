# PARTIE 3 — INTÉGRITÉ DES MODÈLES

## Structure de stockage Ollama (rappel)

```
~/.ollama/models/
├── manifests/
│   └── registry.ollama.ai/library/<model>/<tag>   ← JSON (digests des layers)
└── blobs/
    └── sha256-<hash>                               ← fichiers GGUF et configs
```

**Principe Ollama** : le nom du blob IS son SHA-256.
`sha256sum ~/.ollama/models/blobs/sha256-abc123...` doit retourner `abc123...`.
C'est la vérification d'intégrité locale de base et la plus fiable.

---

## 1. Sources autorisées (politique d'import)

**Sources acceptées** (liste blanche stricte) :

| Source | Usage | Vérification requise |
|--------|-------|---------------------|
| `ollama pull <model>` depuis registry.ollama.ai | Pull standard | SHA blob auto-vérifié par nom |
| HuggingFace GGUF officiel (auteur du modèle) | Import manuel via Modelfile | SHA-256 fichier + attestation HF |
| HuggingFace GGUF communautaire (bartowski, lmstudio-community) | Toléré si auteur reconnu | SHA-256 fichier obligatoire |

**Sources interdites** :
- GitHub releases sans attestation
- Mirrors non officiels
- Torrents / sites tiers
- `curl | bash` pour installer des runners alternatifs

```bash
# Vérifier qu'un GGUF téléchargé manuellement correspond au SHA HF
# Avant de créer un Modelfile :
EXPECTED_SHA=$(curl -sf "https://huggingface.co/api/models/bartowski/Qwen2.5-Coder-7B-Instruct-GGUF/tree/main" \
  | jq -r '[.[] | select(.path | test("Q4_K_M"))] | .[0].lfs.sha256')
ACTUAL_SHA=$(sha256sum ~/Downloads/model.Q4_K_M.gguf | awk '{print $1}')
[[ "$EXPECTED_SHA" == "$ACTUAL_SHA" ]] && echo "OK" || echo "MISMATCH — ne pas importer"
```

---

## 2. Vérification SHA-256 à l'import

### Vérification locale d'un blob Ollama existant

```bash
#!/usr/bin/env bash
# check_blob.sh — vérifie un blob Ollama par nom de fichier
set -euo pipefail

BLOB_DIR="${HOME}/.ollama/models/blobs"
ERRORS=0

for blob in "${BLOB_DIR}"/sha256-*; do
  filename=$(basename "${blob}")
  expected_hash="${filename#sha256-}"
  actual_hash=$(sha256sum "${blob}" | awk '{print $1}')

  if [[ "${actual_hash}" != "${expected_hash}" ]]; then
    echo "DRIFT: ${blob}"
    echo "  Attendu : ${expected_hash}"
    echo "  Calculé : ${actual_hash}"
    ERRORS=$((ERRORS + 1))
  fi
done

echo "Blobs vérifiés. Erreurs : ${ERRORS}"
[[ $ERRORS -eq 0 ]]
```

### Vérification du manifest vers les blobs

```bash
#!/usr/bin/env bash
# verify_manifest.sh MODEL_NAME TAG
# Exemple : bash verify_manifest.sh qwen2.5-coder 7b-instruct-q4_K_M
set -euo pipefail

MODEL="${1:-}"
TAG="${2:-latest}"
MANIFEST="${HOME}/.ollama/models/manifests/registry.ollama.ai/library/${MODEL}/${TAG}"

[[ -f "$MANIFEST" ]] || { echo "Manifest introuvable : $MANIFEST"; exit 1; }

echo "Manifest : $MANIFEST"
ERRORS=0

while IFS= read -r digest; do
  hash="${digest#sha256:}"
  blob="${HOME}/.ollama/models/blobs/sha256-${hash}"
  [[ -f "$blob" ]] || { echo "BLOB MANQUANT : $blob"; ERRORS=$((ERRORS+1)); continue; }
  actual=$(sha256sum "$blob" | awk '{print $1}')
  if [[ "$actual" == "$hash" ]]; then
    echo "OK  : ${hash:0:16}..."
  else
    echo "FAIL: ${hash:0:16}... (calculé: ${actual:0:16}...)"
    ERRORS=$((ERRORS+1))
  fi
done < <(jq -r '.layers[].digest' "$MANIFEST")

echo "Résultat : $([[ $ERRORS -eq 0 ]] && echo 'INTÈGRE' || echo "ERREURS: $ERRORS")"
[[ $ERRORS -eq 0 ]]
```

---

## 3. Manifest local versionné

Le manifest `/home/gloaguen/.llm-local/manifests/manifest.json` (généré par bootstrap.sh)
est la source de vérité. Il doit être versionné dans un dépôt git dédié :

```bash
cd ~/.llm-local
git init
git add manifests/manifest.json
git commit -m "chore: manifest initial $(date +%Y-%m-%d)"
# Committé à chaque recheck si modifications
```

**Champs critiques à ne jamais modifier manuellement** :
- `sha256_recalculated` (valeur de référence pour la dérive)
- `pulled_at` (date d'import)
- `status` (uniquement via recheck.sh)

---

## 4. Recheck régulier des hashes

Géré par `~/.llm-local/recheck.sh` (créé par bootstrap.sh).
Cron : `0 7 * * *` — exécution quotidienne à 07h00.

**Recheck manuel à la demande** :
```bash
bash ~/.llm-local/recheck.sh
echo "Exit code : $?"  # 0 = OK, 1 = drift détecté
```

**Recheck ciblé sur un seul modèle** :
```bash
# Vérifier uniquement qwen2.5-coder
MODEL="qwen2.5-coder"
TAG="7b-instruct-q4_K_M"
bash /home/gloaguen/projets/llm-local-architecture/verify_manifest.sh "$MODEL" "$TAG"
```

---

## 5. Détection de dérive : modèle attendu vs chargé

Ollama charge le modèle défini dans le manifest. Vérifier que le modèle effectivement
chargé correspond à celui attendu via l'API `/api/show` :

```python
#!/usr/bin/env python3
"""verify_loaded_model.py — vérifie que le modèle chargé correspond au manifest"""
import hashlib
import json
import sys
from pathlib import Path
import urllib.request

MANIFEST_FILE = Path.home() / ".llm-local/manifests/manifest.json"
OLLAMA_URL = "http://localhost:11434"


def get_ollama_model_info(model_name: str) -> dict:
    url = f"{OLLAMA_URL}/api/show"
    payload = json.dumps({"name": model_name}).encode()
    req = urllib.request.Request(url, data=payload, method="POST")
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read())


def verify_against_manifest() -> bool:
    manifest = json.loads(MANIFEST_FILE.read_text())
    all_ok = True

    for model_entry in manifest["models"]:
        name = model_entry["name"]
        try:
            info = get_ollama_model_info(name)
        except Exception as e:
            print(f"SKIP {name}: {e}")
            continue

        # Récupérer le digest du layer modèle depuis l'info Ollama
        ollama_digest = info.get("details", {}).get("digest", "")

        # Comparer avec ce qu'on a dans le manifest
        stored_blobs = model_entry.get("blobs", [])
        stored_hashes = {b["sha256_recalculated"] for b in stored_blobs
                         if b.get("integrity_local") == "ok"}

        if ollama_digest.replace("sha256:", "") in stored_hashes:
            print(f"OK  {name}")
        else:
            print(f"WARN {name}: digest chargé '{ollama_digest}' non trouvé dans manifest")
            all_ok = False

    return all_ok


if __name__ == "__main__":
    ok = verify_against_manifest()
    sys.exit(0 if ok else 1)
```

---

## 6. Contrôle des Modelfiles, adapters, templates

```bash
#!/usr/bin/env bash
# audit_modelfiles.sh — inventaire et hash de tous les Modelfiles Ollama
set -euo pipefail

MODELFILE_LOG="${HOME}/.llm-local/checksums/modelfiles_$(date +%Y%m%d).log"
MANIFEST_DIR="${HOME}/.ollama/models/manifests"

echo "# Audit Modelfiles — $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${MODELFILE_LOG}"

find "${MANIFEST_DIR}" -type f | while read -r manifest; do
  # Extraire le layer template/system si présent
  while IFS= read -r layer; do
    media_type=$(echo "$layer" | jq -r '.mediaType')
    digest=$(echo "$layer" | jq -r '.digest')
    blob_path="${HOME}/.ollama/models/blobs/${digest/:/- }"
    blob_path="${blob_path/ /}"  # Remplacer l'espace (artefact de substitution)
    blob_path="${HOME}/.ollama/models/blobs/${digest/sha256:/sha256-}"

    if [[ "$media_type" == *"template"* ]] || [[ "$media_type" == *"system"* ]]; then
      if [[ -f "$blob_path" ]]; then
        sha=$(sha256sum "$blob_path" | awk '{print $1}')
        echo "${manifest}|${media_type}|${sha}" >> "${MODELFILE_LOG}"
      fi
    fi
  done < <(jq -c '.layers[]' "$manifest" 2>/dev/null || true)
done

echo "Audit Modelfiles écrit : ${MODELFILE_LOG}"
cat "${MODELFILE_LOG}"
```

**Vérifier les templates contre une baseline** :
```bash
# Après le premier audit, créer la baseline
cp "${HOME}/.llm-local/checksums/modelfiles_$(date +%Y%m%d).log" \
   "${HOME}/.llm-local/checksums/modelfiles_baseline.log"

# Comparer au prochain audit
diff "${HOME}/.llm-local/checksums/modelfiles_baseline.log" \
     "${HOME}/.llm-local/checksums/modelfiles_$(date +%Y%m%d).log" \
  && echo "Templates identiques" || echo "DRIFT détecté dans les templates"
```

---

## 7. Séparation trusted vs quarantine

```
~/.llm-local/
├── trusted/
│   └── trusted_blobs.log     ← hash + date d'import pour blobs OK
├── quarantine/
│   └── quarantine.log        ← modèles en dérive avec timestamp
└── manifests/
    └── manifest.json         ← statut par modèle : trusted|unverified|quarantine
```

**Isolation opérationnelle** :
- Un modèle `quarantine` ne doit pas être appelé par l'orchestrateur
- Ajouter une garde dans le nœud router :

```python
def node_router(state: OrchestratorState) -> OrchestratorState:
    import json
    from pathlib import Path

    manifest = json.loads(Path.home().joinpath(".llm-local/manifests/manifest.json").read_text())
    quarantined = {m["name"] for m in manifest["models"] if m["status"] == "quarantine"}

    # ... routing logic ...

    if selected_model in quarantined:
        # Forcer le fallback
        selected_model = MODELS["debug"]  # phi4-mini toujours propre

    return state.model_copy(update={"routed_to": selected_model, ...})
```

---

## 8. Procédure si hash change (étapes numérotées)

```
1. DÉTECTION
   recheck.sh détecte drift → status = "quarantine" dans manifest.json
   Log dans : ~/.llm-local/logs/integrity_YYYYMMDD.log

2. ISOLATION
   L'orchestrateur ne route plus vers ce modèle (garde dans node_router)
   Continuer avec les modèles restants

3. INVESTIGATION
   a. Vérifier si Ollama a mis à jour le modèle automatiquement :
      ollama list | grep <model>
      git log ~/.ollama/models/manifests/... 2>/dev/null || true
   b. Vérifier si le fichier blob a été modifié (date) :
      stat ~/.ollama/models/blobs/sha256-<hash>
   c. Vérifier les logs système pour modification inattendue :
      sudo journalctl --since "1 day ago" | grep ollama

4. DÉCISION
   a. Si modification suite à ollama pull involontaire → re-vérifier le nouveau hash
      et mettre à jour le manifest si le modèle est toujours de la source officielle
   b. Si modification inexpliquée → NE PAS réutiliser le blob
      Passer à l'étape 5

5. SUPPRESSION ET RE-TÉLÉCHARGEMENT
   ollama rm <model_name>
   # Vérifier que les blobs sont supprimés
   ollama pull <model_name>
   bash ~/.llm-local/recheck.sh

6. MISE À JOUR MANIFEST
   Le recheck.sh met à jour manifest.json automatiquement
   git commit -m "fix: re-pull après drift $(date +%Y-%m-%d)" ~/.llm-local/manifests/

7. POST-MORTEM
   Documenter dans ~/.llm-local/logs/incidents.log :
   - Date/heure de détection
   - Modèle affecté
   - Delta entre hash attendu et calculé
   - Cause probable
   - Action corrective
```

---

## 9. Distinction des niveaux d'intégrité

| Niveau | Quoi | Vérification | Outil |
|--------|------|-------------|-------|
| **Fichier modèle** | Blob GGUF dans ~/.ollama/models/blobs/ | `sha256sum blob == nom_fichier` | `recheck.sh` |
| **Modelfile/Template** | Layers template, system dans manifest | Hash du blob template vs baseline | `audit_modelfiles.sh` |
| **Runtime config** | Options passées à Ollama (temperature, ctx) | Comparer `ollama show <model>` vs config voulue | Manuel |
| **Chaîne de téléchargement** | Pull depuis registry.ollama.ai uniquement | TLS vérifié par curl/Ollama, pas de custom CA | Ollama natif |

---

## 10. Politique de re-téléchargement

```bash
# Re-pull forcé d'un modèle (supprime l'ancien blob)
# À utiliser UNIQUEMENT après investigation (étape 8)
MODEL="qwen2.5-coder:7b-instruct"

ollama rm "${MODEL}"
sleep 2
ollama pull "${MODEL}"

# Mettre à jour le manifest
python3 - << 'EOF'
import json, subprocess, datetime
from pathlib import Path

manifest_path = Path.home() / ".llm-local/manifests/manifest.json"
manifest = json.loads(manifest_path.read_text())
ts = datetime.datetime.utcnow().isoformat() + "Z"

for model in manifest["models"]:
    if model["name"] == "qwen2.5-coder:7b-instruct":
        model["status"] = "unverified"
        model["pulled_at"] = ts
        model["last_checked"] = ts
        model["blobs"] = []  # sera recalculé au prochain recheck

manifest_path.write_text(json.dumps(manifest, indent=2))
print(f"Manifest mis à jour : {ts}")
EOF

bash ~/.llm-local/recheck.sh
```
