"""
BROKA v4.0 — Alembic Migration Quick Reference
───────────────────────────────────────────────
Commands:
  # Generate migration after schema change
  alembic revision --autogenerate -m "add_idempotency_key_to_mpesa"

  # Apply all pending migrations (dev)
  alembic upgrade head

  # Apply to production
  DATABASE_URL=postgresql+asyncpg://... alembic upgrade head

  # Show current revision
  alembic current

  # Rollback one step
  alembic downgrade -1

  # Generate SQL for review (do this before prod)
  alembic upgrade head --sql > migration.sql

Rules:
  1. Every schema change → Alembic, no exceptions in production.
  2. Never call create_all() in production. Only in in-memory tests.
  3. Keep migrations small and reversible.
  4. Name migrations descriptively: add_trust_score_to_users, not revision_001.
"""
