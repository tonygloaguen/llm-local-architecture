# PARTIE 4 — SÉCURITÉ OPÉRATIONNELLE INSPIRÉE NIS2

## Périmètre : poste Ubuntu 24.04 + Ollama + Docker, usage local

Traduction des articles NIS2 en mesures techniques concrètes et actionnables.
Format : **P1** = immédiat (bloquant), **P2** = semaine 1, **P3** = mensuel/continu.

---

## A. Gestion des actifs (Art. 21 §2.a)

| Priorité | Mesure | Commande / Script |
|----------|--------|------------------|
| **P1** | Inventaire modèles en place | `ollama list > ~/.llm-local/assets/models_$(date +%Y%m%d).txt` |
| **P1** | Inventaire runtimes | `dpkg -l ollama docker* nvidia* 2>/dev/null >> ~/.llm-local/assets/runtimes.txt` |
| **P2** | Inventaire conteneurs actifs | `docker ps -a --format '{{.Names}}\|{{.Image}}\|{{.Status}}' >> ~/.llm-local/assets/containers.txt` |
| **P2** | Inventaire ports exposés | `ss -tlnp > ~/.llm-local/assets/ports_$(date +%Y%m%d).txt` |
| **P3** | Drift inventaire (diff mensuel) | `diff assets/models_prev.txt assets/models_cur.txt` |

```bash
# Script d'inventaire complet (à lancer après bootstrap)
mkdir -p ~/.llm-local/assets
ollama list > ~/.llm-local/assets/models_$(date +%Y%m%d).txt
docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}' \
  > ~/.llm-local/assets/containers_$(date +%Y%m%d).txt 2>/dev/null || true
ss -tlnp > ~/.llm-local/assets/ports_$(date +%Y%m%d).txt
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader \
  >> ~/.llm-local/assets/gpu.txt 2>/dev/null || true
echo "Inventaire : $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> ~/.llm-local/assets/inventory.log
```

---

## B. Gestion des risques (Art. 21 §2.b)

**Matrice simplifiée — menaces réalistes sur ce périmètre** :

| Menace | Probabilité | Impact | Mesure P1 |
|--------|------------|--------|-----------|
| Modèle corrompu à l'import | Faible | Critique | SHA-256 systématique (PARTIE3) |
| Exfiltration données via prompt | Moyenne | Élevé | Pas de réseau sortant depuis Ollama |
| Vulnérabilité llama.cpp/Ollama | Moyenne | Élevé | `apt upgrade ollama` hebdomadaire |
| Supply chain GGUF HF compromis | Faible | Critique | Sources autorisées + hash (PARTIE3) |
| Accès non autorisé port 11434 | Faible | Moyen | Ollama bind sur 127.0.0.1 uniquement |
| Conteneur Docker breakout | Très faible | Critique | User namespaces + no-new-privileges |
| Prompt injection via RAG | Moyenne | Moyen | Validation input dans orchestrateur |

---

## C. Supply chain security (Art. 21 §2.d)

| Priorité | Mesure | Implémentation |
|----------|--------|---------------|
| **P1** | Liste blanche sources GGUF | registry.ollama.ai + HF officiel uniquement (voir PARTIE3) |
| **P1** | Vérification SHA avant import | `check_blob.sh` (PARTIE3) |
| **P1** | Pas de `ollama pull` depuis URL arbitraire | Politique : nom modèle officiel uniquement |
| **P2** | Scan pip-audit sur venv orchestrateur | `pip-audit -r requirements.txt` hebdomadaire |
| **P2** | Pinning versions dans pyproject.toml | `uv lock` ou `pip-compile` |
| **P3** | Revue des nouveaux modèles avant ajout au batch | Vérification source HF, réputation auteur |

```bash
# Vérification supply chain Python (à lancer après création du venv)
pip-audit --require-hashes -r requirements.txt 2>/dev/null \
  | tee ~/.llm-local/logs/pip_audit_$(date +%Y%m%d).log \
  || echo "Vulnérabilités détectées — voir log ci-dessus"

# Scan Trivy sur image Docker si utilisée
trivy image --severity HIGH,CRITICAL --exit-code 1 \
  open-webui/open-webui:latest 2>/dev/null \
  | tee ~/.llm-local/logs/trivy_$(date +%Y%m%d).log || true
```

---

## D. Journalisation (Art. 21 §2.h)

**Ce qui doit être loggué** (minimum opérationnel) :

| Événement | Où | Format |
|-----------|-----|--------|
| Pull modèle (succès/échec) | `~/.llm-local/logs/bootstrap_*.log` | Timestamp ISO + modèle + status |
| Recheck intégrité | `~/.llm-local/logs/integrity_YYYYMMDD.log` | Timestamp + modèle + verdict |
| Requête Ollama (optionnel) | `~/.ollama/logs/server.log` | Natif Ollama |
| Drift détecté | `~/.llm-local/logs/integrity_YYYYMMDD.log` | CRITICAL level |
| Quarantaine activée | `~/.llm-local/quarantine/quarantine.log` | Timestamp + modèle + hash |

```bash
# Activer les logs Ollama (si pas actif par défaut)
# Vérifier le service systemd
systemctl status ollama 2>/dev/null | grep -i log || true

# Logs Ollama accessibles ici sur Ubuntu :
journalctl -u ollama --since "1 day ago" --no-pager \
  | tee ~/.llm-local/logs/ollama_$(date +%Y%m%d).log

# Rotation des logs (logrotate)
cat > /etc/logrotate.d/llm-local << 'EOF'
/home/gloaguen/.llm-local/logs/*.log {
    daily
    rotate 30
    compress
    missingok
    notifempty
    dateext
}
EOF
```

**Durée de rétention** : 30 jours minimum (aligné NIS2 Art. 21 et recommandations ANSSI).

---

## E. Gestion des incidents (Art. 21 §2.e + Art. 23)

| Priorité | Étape | Action |
|----------|-------|--------|
| **P1** | Détection | `recheck.sh` quotidien + alertes exit code 1 |
| **P1** | Isolation | Quarantaine automatique du modèle affecté |
| **P1** | Notification | Log dans `incidents.log` avec timestamp |
| **P2** | Triage | Script `triage_incident.sh` ci-dessous |
| **P2** | Remédiation | Procédure PARTIE3 §8 |
| **P3** | Post-mortem | Documenter dans `~/.llm-local/logs/postmortem_YYYYMMDD.md` |

```bash
#!/usr/bin/env bash
# triage_incident.sh — collecte rapide d'information lors d'un incident
set -euo pipefail

INCIDENT_DIR="${HOME}/.llm-local/logs/incident_$(date +%Y%m%d_%H%M%S)"
mkdir -p "${INCIDENT_DIR}"

echo "=== TRIAGE INCIDENT $(date -u) ===" | tee "${INCIDENT_DIR}/summary.txt"
ollama list >> "${INCIDENT_DIR}/summary.txt" 2>&1 || true
cat "${HOME}/.llm-local/manifests/manifest.json" >> "${INCIDENT_DIR}/manifest.json"
journalctl -u ollama --since "1 hour ago" --no-pager >> "${INCIDENT_DIR}/ollama.log" 2>/dev/null || true
ss -tlnp >> "${INCIDENT_DIR}/ports.txt"
ps aux | grep -E "(ollama|python|docker)" >> "${INCIDENT_DIR}/processes.txt"
nvidia-smi >> "${INCIDENT_DIR}/gpu.txt" 2>/dev/null || true

echo "Données collectées dans : ${INCIDENT_DIR}"
```

---

## F. Sauvegarde / Reprise (Art. 21 §2.c)

| Ce qui mérite sauvegarde | Fréquence | Outil |
|--------------------------|-----------|-------|
| `~/.llm-local/manifests/manifest.json` | Quotidien (git commit) | git |
| `~/.llm-local/checksums/` | Hebdomadaire | rsync vers /opt/backup/ |
| Config Ollama (~/.ollama/config, Modelfiles) | À chaque modification | git |
| Venv Python orchestrateur + pyproject.toml | À chaque modification | git |
| **À ne PAS sauvegarder** : les blobs GGUF (20+ Go) | — | Re-pull depuis registry |

```bash
# Sauvegarde quotidienne du manifest (via cron)
# Ajouter dans crontab : 0 7 30 * * * bash ~/.llm-local/backup_manifest.sh
cat > ~/.llm-local/backup_manifest.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
BACKUP_DIR="/opt/backup/llm-local/$(date +%Y%m)"
mkdir -p "${BACKUP_DIR}"
cp -r "${HOME}/.llm-local/manifests" "${BACKUP_DIR}/"
cp -r "${HOME}/.llm-local/checksums" "${BACKUP_DIR}/"
echo "Backup : $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${HOME}/.llm-local/logs/backup.log"
EOF
chmod +x ~/.llm-local/backup_manifest.sh
```

**RTO estimé** : 20-45 min (re-pull des 5 modèles sur connexion standard).
**RPO** : 24h (recheck quotidien).

---

## G. Contrôle des accès (Art. 21 §2.i)

| Priorité | Mesure | Commande |
|----------|--------|---------|
| **P1** | Ollama écoute sur 127.0.0.1 uniquement | Vérifier `ss -tlnp \| grep 11434` → doit être `127.0.0.1` |
| **P1** | Permissions strictes sur ~/.llm-local | `chmod 700 ~/.llm-local && chmod 600 ~/.llm-local/manifests/*` |
| **P1** | Permissions strictes sur ~/.ollama | `chmod 700 ~/.ollama` |
| **P2** | Ollama sans socket réseau public | `OLLAMA_HOST=127.0.0.1` dans `/etc/systemd/system/ollama.service.d/override.conf` |
| **P2** | Docker rootless | `dockerd-rootless-setuptool.sh install` |
| **P3** | Audit permissions fichiers modèles | `find ~/.ollama -perm /o+r -type f` → doit être vide |

```bash
# Vérification et durcissement des permissions
chmod 700 ~/.llm-local ~/.ollama
chmod 600 ~/.llm-local/manifests/manifest.json
find ~/.llm-local -type f -exec chmod 600 {} \;
find ~/.llm-local -type d -exec chmod 700 {} \;

# S'assurer qu'Ollama n'écoute pas sur 0.0.0.0
if ss -tlnp | grep ':11434' | grep -q '0.0.0.0'; then
  echo "ATTENTION : Ollama expose sur 0.0.0.0 — corriger OLLAMA_HOST"
fi

# Forcer Ollama sur localhost
sudo mkdir -p /etc/systemd/system/ollama.service.d/
cat << 'EOF' | sudo tee /etc/systemd/system/ollama.service.d/override.conf
[Service]
Environment="OLLAMA_HOST=127.0.0.1:11434"
EOF
sudo systemctl daemon-reload && sudo systemctl restart ollama
```

---

## H. Gestion des vulnérabilités (Art. 21 §2.f)

```bash
# Scan hebdomadaire — à ajouter en cron (0 8 * * 1)
#!/usr/bin/env bash
set -euo pipefail
LOG="${HOME}/.llm-local/logs/vuln_$(date +%Y%m%d).log"

echo "=== Scan vulnérabilités $(date -u) ===" > "$LOG"

# 1. Mise à jour Ollama
apt list --upgradable 2>/dev/null | grep ollama >> "$LOG" || true

# 2. pip-audit sur le venv orchestrateur
if [[ -f "${HOME}/projets/local-llm-orchestrator/pyproject.toml" ]]; then
  cd "${HOME}/projets/local-llm-orchestrator"
  pip-audit 2>&1 >> "$LOG" || echo "pip-audit: vulnérabilités détectées" >> "$LOG"
fi

# 3. Docker images
docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | while read -r img; do
  trivy image --severity HIGH,CRITICAL --quiet "$img" 2>&1 >> "$LOG" || true
done

# 4. Rapport
echo "Scan terminé. Résultats : $LOG"
grep -c "CRITICAL\|HIGH" "$LOG" > /dev/null && echo "⚠️ Vulnérabilités HIGH/CRITICAL détectées" || echo "✅ Aucune vulnérabilité critique"
```

---

## I. Durcissement hôte Ubuntu 24.04

| Priorité | Mesure | Commande |
|----------|--------|---------|
| **P1** | AppArmor actif | `sudo aa-status \| grep "profiles are in enforce mode"` |
| **P1** | UFW activé + règle Ollama | `sudo ufw allow from 127.0.0.1 to any port 11434 && sudo ufw enable` |
| **P1** | Désactiver SSH password auth | `/etc/ssh/sshd_config : PasswordAuthentication no` |
| **P2** | Kernel hardening sysctl | `kernel.dmesg_restrict=1`, `net.ipv4.tcp_syncookies=1` |
| **P2** | Auditd pour accès fichiers modèles | `auditctl -w ~/.ollama/models -p rwxa -k model_access` |
| **P3** | CIS Benchmark Ubuntu 24.04 | `sudo apt install lynis && sudo lynis audit system` |

```bash
# Vérifications rapides de durcissement
echo "=== Hardening check ==="
sudo ufw status | head -5
sudo aa-status --enabled && echo "AppArmor: actif" || echo "AppArmor: INACTIF"
grep "PasswordAuthentication" /etc/ssh/sshd_config 2>/dev/null || true
ss -tlnp | grep -E "(:11434|:3000|:8080)" | grep -v 127.0.0.1 \
  && echo "⚠️ Port exposé sur réseau" || echo "✅ Ports LLM locaux uniquement"
```

---

## J. Gestion de configuration / Drift detection (Art. 21 §2.g)

```bash
# Versionner les configs clés dans git
cd ~/.llm-local
git init 2>/dev/null || true
git add manifests/ checksums/ recheck.sh

# Détecter drift de configuration Ollama
OLLAMA_CONFIG_HASH=$(sha256sum ~/.ollama/config.json 2>/dev/null | awk '{print $1}' || echo "no_config")
echo "Config Ollama SHA : ${OLLAMA_CONFIG_HASH}" >> ~/.llm-local/logs/config_check.log

# Comparer avec baseline
BASELINE="${HOME}/.llm-local/checksums/ollama_config_baseline.sha256"
if [[ -f "$BASELINE" ]]; then
  EXPECTED=$(cat "$BASELINE")
  [[ "$OLLAMA_CONFIG_HASH" == "$EXPECTED" ]] \
    && echo "Config Ollama : inchangée" \
    || echo "⚠️ Config Ollama modifiée"
else
  echo "${OLLAMA_CONFIG_HASH}" > "$BASELINE"
  echo "Baseline config créée"
fi
```

---

## K. Revue périodique (Art. 21 §2.a)

| Cadence | Revue | Checklist |
|---------|-------|-----------|
| **Quotidien** (auto) | Intégrité modèles | `recheck.sh` — vérifier exit code |
| **Hebdomadaire** (manuel, 15 min) | Vulnérabilités + inventaire | Voir script §H |
| **Mensuel** (manuel, 1h) | Drift config + revue accès + mise à jour modèles | Voir checklist ci-dessous |
| **Trimestriel** | Revue architecture + nouveaux modèles pertinents | Revisiter PARTIE1 |

**Checklist mensuelle** (copier-coller en markdown) :
```
## Revue mensuelle LLM local — YYYY-MM

### Modèles
- [ ] ollama list vs manifest.json : pas de modèle fantôme
- [ ] Tous les modèles trustés ont un recheck OK sur le mois
- [ ] Nouveaux modèles du batch à évaluer ?

### Sécurité
- [ ] pip-audit : 0 vulnérabilité CRITICAL/HIGH
- [ ] Trivy images : 0 vulnérabilité CRITICAL
- [ ] Ollama version à jour : apt show ollama | grep Version
- [ ] Ports : ss -tlnp | grep -v 127.0.0.1 → vide

### Accès et configuration
- [ ] Permissions ~/.llm-local : 700 (dossiers) / 600 (fichiers)
- [ ] Ollama OLLAMA_HOST = 127.0.0.1 confirmé
- [ ] Cron recheck actif : crontab -l | grep recheck

### Journaux
- [ ] Aucun CRITICAL dans les logs du mois
- [ ] Rotation des logs fonctionnelle
```
