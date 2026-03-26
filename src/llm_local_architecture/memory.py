"""Mémoire locale persistante en SQLite."""

from __future__ import annotations

import sqlite3
from datetime import UTC, datetime
from uuid import uuid4

from .config import APP_DB_PATH, DOCUMENT_EXCERPT_CHARS, SHORT_TERM_MESSAGE_LIMIT
from .schemas import MemoryBundle, ProcessedDocument


def _utcnow() -> str:
    return datetime.now(UTC).isoformat()


def _connect() -> sqlite3.Connection:
    conn = sqlite3.connect(APP_DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def initialize_database() -> None:
    """Initialise le schéma SQLite de l'application."""
    with _connect() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS documents (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                filename TEXT NOT NULL,
                stored_path TEXT NOT NULL,
                extracted_path TEXT NOT NULL,
                mime_type TEXT NOT NULL,
                source_type TEXT NOT NULL,
                extraction_method TEXT NOT NULL,
                ocr_used INTEGER NOT NULL,
                page_count INTEGER NOT NULL,
                created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS document_contents (
                document_id TEXT PRIMARY KEY,
                extracted_text TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS document_notes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                document_id TEXT NOT NULL,
                note TEXT NOT NULL,
                created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS preferences (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            """
        )


def ensure_session(session_id: str | None = None) -> str:
    """Retourne une session existante ou en crée une nouvelle."""
    now = _utcnow()
    session = session_id or uuid4().hex
    with _connect() as conn:
        row = conn.execute("SELECT id FROM sessions WHERE id = ?", (session,)).fetchone()
        if row is None:
            conn.execute(
                "INSERT INTO sessions (id, created_at, updated_at) VALUES (?, ?, ?)",
                (session, now, now),
            )
        else:
            conn.execute("UPDATE sessions SET updated_at = ? WHERE id = ?", (now, session))
    return session


def save_message(session_id: str, role: str, content: str) -> None:
    """Persiste un message de session."""
    now = _utcnow()
    with _connect() as conn:
        conn.execute(
            "INSERT INTO messages (session_id, role, content, created_at) VALUES (?, ?, ?, ?)",
            (session_id, role, content, now),
        )
        conn.execute("UPDATE sessions SET updated_at = ? WHERE id = ?", (now, session_id))


def save_document(session_id: str, document: ProcessedDocument) -> str:
    """Persiste un document et son texte extrait."""
    now = _utcnow()
    with _connect() as conn:
        conn.execute(
            """
            INSERT INTO documents (
                id, session_id, filename, stored_path, extracted_path, mime_type,
                source_type, extraction_method, ocr_used, page_count, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                document.document_id,
                session_id,
                document.filename,
                document.stored_path,
                document.extracted_path,
                document.mime_type,
                document.source_type,
                document.extraction_method,
                int(document.ocr_used),
                document.page_count,
                now,
            ),
        )
        conn.execute(
            "INSERT OR REPLACE INTO document_contents (document_id, extracted_text) VALUES (?, ?)",
            (document.document_id, document.text),
        )
    return document.document_id


def build_memory_bundle(session_id: str, document_id: str | None = None) -> MemoryBundle:
    """Construit le contexte mémoire des trois couches."""
    bundle = MemoryBundle()
    with _connect() as conn:
        messages = conn.execute(
            """
            SELECT role, content
            FROM messages
            WHERE session_id = ?
            ORDER BY id DESC
            LIMIT ?
            """,
            (session_id, SHORT_TERM_MESSAGE_LIMIT),
        ).fetchall()
        if messages:
            ordered = list(reversed(messages))
            bundle.short_term_text = "\n".join(
                f"{row['role']}: {row['content']}" for row in ordered
            )
            bundle.sources.append("short_term")

        if document_id is not None:
            doc_row = conn.execute(
                """
                SELECT dc.extracted_text
                FROM document_contents dc
                JOIN documents d ON d.id = dc.document_id
                WHERE d.id = ?
                """,
                (document_id,),
            ).fetchone()
            if doc_row is not None:
                bundle.documentary_text = doc_row["extracted_text"][:DOCUMENT_EXCERPT_CHARS]
                bundle.sources.append("documentary")

        prefs = conn.execute(
            "SELECT key, value FROM preferences ORDER BY key ASC"
        ).fetchall()
        if prefs:
            bundle.preferences_text = "\n".join(
                f"{row['key']}: {row['value']}" for row in prefs
            )
            bundle.sources.append("preferences")

    return bundle
