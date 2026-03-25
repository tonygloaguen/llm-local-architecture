# PARTIE 2 — ORCHESTRATEUR PAR SUJET

## Stratégie : routing déterministe, pas de ML

Le routing est basé sur des règles explicites appliquées sur le prompt entrant.
Pas d'embedding, pas de classificateur, pas de latence supplémentaire.
Un nœud Python évalue les règles en <1ms et dispatche.

---

## Règles de routing (priorité décroissante)

```python
ROUTING_RULES = [
    # Priorité 1 — Audit/Sécurité
    {
        "model": "granite3.3:8b",
        "role": "audit",
        "keywords": [
            "dockerfile", "github actions", "ci/cd", "cve", "vulnerability",
            "trivy", "gitleaks", "checkov", "bandit", "pip-audit", "supply chain",
            "sast", "dast", "owasp", "secret", "credentials", "audit", "pentest",
            "nis2", "anssi", "sigma", "mitre", "att&ck", "incident", "siem",
            "revue de code sécurité", "durcissement", "hardening"
        ],
        "task_types": ["audit", "security_review", "compliance"]
    },
    # Priorité 2 — Code (détection syntaxe)
    {
        "model": "qwen2.5-coder:7b-instruct",
        "role": "code",
        "keywords": [
            "python", "fastapi", "sqlalchemy", "langgraph", "asyncio", "async def",
            "pydantic", "pytest", "docker-compose", "dockerfile", "bash script",
            "arm64", "raspberry pi", "playwright", "langchain", "openai sdk",
            "refactor", "génère", "génère le code", "implémente", "module",
            ".py", "def ", "class ", "import ", "```python"
        ],
        "task_types": ["code_generation", "code_review", "debugging_code", "fim"]
    },
    # Priorité 3 — Orchestration / Logique agent
    {
        "model": "deepseek-r1:7b",
        "role": "agent",
        "keywords": [
            "orchestr", "planifie", "décompose", "stratégie", "workflow",
            "étapes", "multi-étapes", "décide", "agent", "graph", "node",
            "raisonne", "analyse", "why", "pourquoi", "cause", "root cause",
            "architecture", "conception"
        ],
        "task_types": ["orchestration", "planning", "analysis", "root_cause"]
    },
    # Priorité 4 — Rédaction française
    {
        "model": "mistral:7b-instruct-v0.3-q4_K_M",
        "role": "redaction",
        "keywords": [
            "rédige", "reformule", "synthèse", "linkedin", "mail", "email",
            "professionnel", "rapport", "résumé", "présentation", "post",
            "lettre", "document", "note de synthèse", "compte rendu"
        ],
        "task_types": ["writing", "summarization", "professional_text"]
    },
    # Priorité 5 — Debug rapide (fallback)
    {
        "model": "phi4-mini",
        "role": "debug",
        "keywords": [
            "erreur", "error", "traceback", "exception", "bug", "crash",
            "broken", "why", "quick", "explain briefly", "what is",
            "en une ligne", "sanity check", "vite", "rapide"
        ],
        "task_types": ["quick_debug", "quick_question", "explain"]
    }
]
```

---

## Critères de décision complémentaires

```python
def estimate_complexity(prompt: str) -> str:
    """Retourne 'simple' | 'medium' | 'complex'"""
    word_count = len(prompt.split())
    has_code_block = "```" in prompt
    has_multi_step = any(w in prompt.lower() for w in ["étapes", "puis", "ensuite", "enfin", "step"])

    if word_count < 50 and not has_code_block:
        return "simple"   # → phi4-mini suffit
    if word_count > 500 or (has_code_block and has_multi_step):
        return "complex"  # → deepseek-r1 ou modèle spécialisé
    return "medium"
```

**Règle de taille** :
- < 50 mots, pas de code → phi4-mini directement (pas de routing nécessaire)
- > 500 mots avec code → forcer le modèle spécialisé (ne pas laisser phi4-mini)

---

## Cas séquentiels (2 modèles en pipeline)

| Scénario | Modèle 1 | Modèle 2 | Déclencheur |
|----------|----------|----------|-------------|
| Génération + review sécurité | qwen2.5-coder | granite3.3 | `mode="generate_and_audit"` |
| Planification + implémentation | deepseek-r1 | qwen2.5-coder | `mode="plan_then_code"` |
| Brouillon + reformulation FR | deepseek-r1 | mistral:7b | `mode="draft_then_polish"` |
| Debug + fix | phi4-mini (triage) | qwen2.5-coder (fix) | erreur code détectée |

---

## Stratégie de fallback (timeout)

```
Timeout par défaut : 120s

Si modèle A timeout ou erreur :
  → deepseek-r1:7b (pivot universel)
  → Si deepseek-r1 aussi en échec : phi4-mini + message "dégradé"

Ordre de fallback :
  code    : qwen2.5-coder → deepseek-r1 → phi4-mini
  audit   : granite3.3    → deepseek-r1 → phi4-mini
  agent   : deepseek-r1   → granite3.3  → phi4-mini
  redact  : mistral:7b    → deepseek-r1 → phi4-mini
  debug   : phi4-mini     → deepseek-r1 (pas de 3e fallback)
```

---

## Stratégie d'arbitrage (deux modèles divergents)

Applicable quand deux modèles sont appelés en parallèle sur la même question :
1. Si les sorties concordent → retourner la plus courte (plus précise)
2. Si divergence sur un fact technique → demander à `deepseek-r1` de trancher avec
   chain-of-thought explicite
3. Si divergence sur du code → exécuter les deux et garder celui qui passe les tests

---

## Architecture LangGraph — pseudo-code Python commenté

```python
"""
Orchestrateur LangGraph local — dispatch multi-modèles
Dépendances : langgraph>=0.2, ollama>=0.3, pydantic>=2.0
"""
from __future__ import annotations

import re
from typing import Literal, Optional
from pydantic import BaseModel, Field
from langgraph.graph import StateGraph, END
import ollama


# ---------------------------------------------------------------------------
# État global du graph
# ---------------------------------------------------------------------------
class OrchestratorState(BaseModel):
    """État Pydantic v2 — chaque nœud lit et écrit ici."""

    # Entrée
    user_prompt: str
    mode: Literal["auto", "generate_and_audit", "plan_then_code", "draft_then_polish"] = "auto"

    # Routing
    routed_to: Optional[str] = None          # modèle sélectionné
    task_type: Optional[str] = None          # type de tâche inféré
    complexity: Optional[str] = None         # simple|medium|complex

    # Réponses
    primary_response: Optional[str] = None   # réponse du modèle primaire
    secondary_response: Optional[str] = None # réponse du modèle secondaire (pipeline)
    final_response: Optional[str] = None     # sortie validée

    # Métadonnées
    tokens_used: int = 0
    model_chain: list[str] = Field(default_factory=list)
    error: Optional[str] = None
    fallback_triggered: bool = False


# ---------------------------------------------------------------------------
# Configuration modèles
# ---------------------------------------------------------------------------
MODELS = {
    "code":     "qwen2.5-coder:7b-instruct",
    "audit":    "granite3.3:8b",
    "agent":    "deepseek-r1:7b",
    "debug":    "phi4-mini",
    "redaction": "mistral:7b-instruct-v0.3-q4_K_M",
}

TIMEOUTS = {
    "code": 120, "audit": 120, "agent": 180, "debug": 30, "redaction": 90
}


# ---------------------------------------------------------------------------
# Nœud 1 : ROUTER
# ---------------------------------------------------------------------------
def node_router(state: OrchestratorState) -> OrchestratorState:
    """
    Classifie le prompt et sélectionne le modèle.
    Règles déterministes, aucune latence réseau.
    """
    prompt_lower = state.user_prompt.lower()

    # Scores par rôle (nombre de keywords matchés)
    scores: dict[str, int] = {role: 0 for role in MODELS}

    for rule in ROUTING_RULES:
        for keyword in rule["keywords"]:
            if keyword.lower() in prompt_lower:
                scores[rule["role"]] += 1

    # Sélectionner le rôle avec le score le plus élevé
    best_role = max(scores, key=lambda r: scores[r])

    # Si score nul → phi4-mini par défaut
    if scores[best_role] == 0:
        best_role = "debug"

    # Estimer la complexité
    word_count = len(state.user_prompt.split())
    has_code = "```" in state.user_prompt
    if word_count < 50 and not has_code:
        complexity = "simple"
        # Pour les questions simples → toujours phi4-mini
        best_role = "debug"
    elif word_count > 500:
        complexity = "complex"
    else:
        complexity = "medium"

    # Override basé sur le mode explicite
    if state.mode != "auto":
        mode_to_role = {
            "generate_and_audit": "code",
            "plan_then_code": "agent",
            "draft_then_polish": "redaction",
        }
        best_role = mode_to_role.get(state.mode, best_role)

    return state.model_copy(update={
        "routed_to": MODELS[best_role],
        "task_type": best_role,
        "complexity": complexity,
        "model_chain": [MODELS[best_role]],
    })


# ---------------------------------------------------------------------------
# Nœud 2 : WORKERS spécialisés (factory function)
# ---------------------------------------------------------------------------
def make_worker_node(role: str):
    """Génère un nœud worker pour le rôle donné."""

    def worker(state: OrchestratorState) -> OrchestratorState:
        model = MODELS[role]
        timeout = TIMEOUTS[role]

        # Prompts système par rôle
        system_prompts = {
            "code": (
                "Tu es un expert Python 3.11+ senior. "
                "Génère du code async, typé strictement (mypy strict), "
                "avec docstrings Google. Pas d'explication si non demandée."
            ),
            "audit": (
                "Tu es un auditeur DevSecOps senior. "
                "Identifie les risques concrets, classe par sévérité (Critique/Haute/Moyenne/Faible), "
                "propose des remèdes avec commandes bash ou config exactes."
            ),
            "agent": (
                "Tu es un architecte système. Raisonne étape par étape. "
                "Décompose le problème, identifie les dépendances, propose une solution structurée."
            ),
            "debug": (
                "Debug rapide. Identifie la cause en 1-2 phrases, "
                "propose le fix en <10 lignes. Direct."
            ),
            "redaction": (
                "Tu es un rédacteur professionnel français. "
                "Registre professionnel, direct, sans blabla. "
                "Jamais de formules creuses."
            ),
        }

        try:
            response = ollama.chat(
                model=model,
                messages=[
                    {"role": "system", "content": system_prompts[role]},
                    {"role": "user", "content": state.user_prompt},
                ],
                options={"temperature": 0.1, "num_predict": 2048},
            )
            content = response["message"]["content"]

            return state.model_copy(update={
                "primary_response": content,
                "tokens_used": state.tokens_used + response.get("eval_count", 0),
            })

        except Exception as exc:
            return state.model_copy(update={"error": str(exc)})

    worker.__name__ = f"node_{role}_worker"
    return worker


# ---------------------------------------------------------------------------
# Nœud 3 : CRITIC / REVIEWER (séquentiel après code)
# ---------------------------------------------------------------------------
def node_critic(state: OrchestratorState) -> OrchestratorState:
    """
    Appelé après node_code_worker en mode generate_and_audit.
    Passe le code généré à granite3.3 pour revue sécurité.
    """
    if state.primary_response is None:
        return state

    review_prompt = (
        f"Voici du code Python généré :\n\n```python\n{state.primary_response}\n```\n\n"
        "Identifie les vulnérabilités de sécurité (injection, secrets hardcodés, "
        "dépendances vulnérables, permissions excessives). "
        "Sois concis. Format : liste numérotée des problèmes + fix pour chacun."
    )

    try:
        response = ollama.chat(
            model=MODELS["audit"],
            messages=[{"role": "user", "content": review_prompt}],
            options={"temperature": 0.0},
        )
        review = response["message"]["content"]
        return state.model_copy(update={
            "secondary_response": review,
            "model_chain": state.model_chain + [MODELS["audit"]],
        })
    except Exception as exc:
        return state.model_copy(update={"error": f"critic: {exc}"})


# ---------------------------------------------------------------------------
# Nœud 4 : FALLBACK
# ---------------------------------------------------------------------------
def node_fallback(state: OrchestratorState) -> OrchestratorState:
    """Appelé si le worker primaire a échoué (error != None)."""
    fallback_model = "deepseek-r1:7b"

    # Ne pas boucler sur deepseek-r1 si c'était déjà le modèle primaire
    if state.routed_to == fallback_model:
        fallback_model = "phi4-mini"

    try:
        response = ollama.chat(
            model=fallback_model,
            messages=[{"role": "user", "content": state.user_prompt}],
            options={"temperature": 0.1},
        )
        return state.model_copy(update={
            "primary_response": response["message"]["content"],
            "fallback_triggered": True,
            "error": None,
            "routed_to": fallback_model,
            "model_chain": state.model_chain + [fallback_model],
        })
    except Exception as exc:
        return state.model_copy(update={
            "primary_response": f"[ERREUR TOTALE] {state.error} | fallback: {exc}",
            "fallback_triggered": True,
        })


# ---------------------------------------------------------------------------
# Nœud 5 : VALIDATOR (assemblage de la réponse finale)
# ---------------------------------------------------------------------------
def node_validator(state: OrchestratorState) -> OrchestratorState:
    """
    Assemble la réponse finale.
    Si secondary_response (critic), ajoute la revue sécurité.
    """
    if state.primary_response is None:
        return state.model_copy(update={"final_response": "Erreur : aucune réponse générée."})

    final = state.primary_response
    if state.secondary_response:
        final += f"\n\n---\n## Revue sécurité (granite3.3)\n\n{state.secondary_response}"

    if state.fallback_triggered:
        final = f"⚠️ Fallback activé (modèle primaire en échec)\n\n{final}"

    return state.model_copy(update={"final_response": final})


# ---------------------------------------------------------------------------
# Conditions de routing (edges conditionnels)
# ---------------------------------------------------------------------------
def should_fallback(state: OrchestratorState) -> Literal["fallback", "next"]:
    return "fallback" if state.error else "next"


def route_to_worker(state: OrchestratorState) -> str:
    """Dispatche vers le bon nœud worker après le router."""
    task_to_node = {
        "code":     "code_worker",
        "audit":    "audit_worker",
        "agent":    "agent_worker",
        "debug":    "debug_worker",
        "redaction": "redaction_worker",
    }
    return task_to_node.get(state.task_type or "debug", "debug_worker")


def should_run_critic(state: OrchestratorState) -> Literal["critic", "validator"]:
    """Lance le critic uniquement en mode generate_and_audit."""
    if state.mode == "generate_and_audit" and state.error is None:
        return "critic"
    return "validator"


# ---------------------------------------------------------------------------
# Construction du graph
# ---------------------------------------------------------------------------
def build_orchestrator_graph() -> StateGraph:
    graph = StateGraph(OrchestratorState)

    # Ajouter les nœuds
    graph.add_node("router", node_router)
    graph.add_node("code_worker", make_worker_node("code"))
    graph.add_node("audit_worker", make_worker_node("audit"))
    graph.add_node("agent_worker", make_worker_node("agent"))
    graph.add_node("debug_worker", make_worker_node("debug"))
    graph.add_node("redaction_worker", make_worker_node("redaction"))
    graph.add_node("fallback", node_fallback)
    graph.add_node("critic", node_critic)
    graph.add_node("validator", node_validator)

    # Edge d'entrée
    graph.set_entry_point("router")

    # Routing conditionnel après router
    graph.add_conditional_edges(
        "router",
        route_to_worker,
        {
            "code_worker":      "code_worker",
            "audit_worker":     "audit_worker",
            "agent_worker":     "agent_worker",
            "debug_worker":     "debug_worker",
            "redaction_worker": "redaction_worker",
        }
    )

    # Après chaque worker : vérifier si fallback nécessaire
    for worker_node in ["code_worker", "audit_worker", "agent_worker",
                        "debug_worker", "redaction_worker"]:
        graph.add_conditional_edges(
            worker_node,
            should_fallback,
            {"fallback": "fallback", "next": "critic" if worker_node == "code_worker" else "validator"}
        )

    # code_worker → critic ou validator (selon mode)
    graph.add_conditional_edges(
        "code_worker",
        lambda s: should_run_critic(s) if not s.error else "fallback",
        {"critic": "critic", "validator": "validator", "fallback": "fallback"}
    )

    # Critic → validator
    graph.add_edge("critic", "validator")

    # Fallback → validator
    graph.add_edge("fallback", "validator")

    # Validator → END
    graph.add_edge("validator", END)

    return graph.compile()


# ---------------------------------------------------------------------------
# Point d'entrée
# ---------------------------------------------------------------------------
def run(prompt: str, mode: str = "auto") -> str:
    """Interface principale de l'orchestrateur."""
    graph = build_orchestrator_graph()
    initial_state = OrchestratorState(user_prompt=prompt, mode=mode)
    result = graph.invoke(initial_state)
    return result.final_response or "Erreur inattendue"


# Usage :
# from orchestrator import run
# print(run("Génère un middleware JWT FastAPI avec rate limiting"))
# print(run("Audite ce Dockerfile : ...", mode="generate_and_audit"))
```

---

## Notes d'implémentation

**Dépendances** (`pyproject.toml`) :
```toml
[project]
requires-python = ">=3.11"
dependencies = [
    "langgraph>=0.2",
    "ollama>=0.3",
    "pydantic>=2.0",
]
```

**Limitation connue** : `StateGraph` de LangGraph ne supporte pas nativement les
edges conditionnels multiples depuis un même nœud. Le workaround ci-dessus
(override des edges pour `code_worker`) peut nécessiter un ajustement selon la
version de LangGraph. Utiliser `add_conditional_edges` une seule fois par nœud
source ou factoriser dans une fonction de routage unique.

**Point d'intégration Ollama** : s'assurer qu'Ollama écoute sur `http://localhost:11434`
(défaut). Si port différent : `export OLLAMA_HOST=http://localhost:PORT`.
