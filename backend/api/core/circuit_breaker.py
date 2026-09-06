"""
BROKA v4.0 - Circuit Breaker
─────────────────────────────────────────────────────────────────────────────
Prevents cascading failures when an external service (Gemini, OpenRouter,
Groq, M-Pesa) is slow or unavailable.

States:
  CLOSED   — normal operation; requests pass through.
  OPEN     — too many failures; requests rejected immediately with fallback.
  HALF-OPEN — cool-down elapsed; one trial request let through to test recovery.

Usage:
    breaker = CircuitBreaker("gemini", failure_threshold=5, recovery_timeout=30)
    try:
        result = await breaker.call(call_gemini, messages)
    except CircuitOpenError:
        result = await call_fallback(messages)
"""
from __future__ import annotations

import asyncio
import logging
import time
from enum import Enum
from typing import Any, Callable, Coroutine, Optional

logger = logging.getLogger(__name__)


class CircuitState(str, Enum):
    CLOSED    = "closed"
    OPEN      = "open"
    HALF_OPEN = "half_open"


class CircuitOpenError(Exception):
    """Raised when the circuit is OPEN and the call is rejected."""
    pass


class CircuitBreaker:
    """
    Thread-safe (asyncio) circuit breaker.

    Args:
        name:              Human-readable name for logging.
        failure_threshold: Number of consecutive failures before OPEN.
        recovery_timeout:  Seconds to wait before trying HALF-OPEN.
        success_threshold: Successes in HALF-OPEN before returning to CLOSED.
    """

    def __init__(
        self,
        name: str,
        failure_threshold: int = 5,
        recovery_timeout: float = 30.0,
        success_threshold: int = 2,
    ):
        self.name               = name
        self.failure_threshold  = failure_threshold
        self.recovery_timeout   = recovery_timeout
        self.success_threshold  = success_threshold
        self._state             = CircuitState.CLOSED
        self._failure_count     = 0
        self._success_count     = 0
        self._opened_at: Optional[float] = None
        self._lock              = asyncio.Lock()

    @property
    def state(self) -> CircuitState:
        return self._state

    async def call(self, fn: Callable[..., Coroutine[Any, Any, Any]], *args: Any, **kwargs: Any) -> Any:
        await self._maybe_transition()
        async with self._lock:
            if self._state == CircuitState.OPEN:
                logger.warning("[circuit:%s] OPEN — rejecting call", self.name)
                raise CircuitOpenError(f"Circuit '{self.name}' is OPEN")
        try:
            result = await fn(*args, **kwargs)
            await self._on_success()
            return result
        except CircuitOpenError:
            raise
        except Exception as exc:
            await self._on_failure(exc)
            raise

    async def _on_success(self) -> None:
        async with self._lock:
            if self._state == CircuitState.HALF_OPEN:
                self._success_count += 1
                if self._success_count >= self.success_threshold:
                    self._state         = CircuitState.CLOSED
                    self._failure_count = 0
                    self._success_count = 0
                    self._opened_at     = None
                    logger.info("[circuit:%s] CLOSED (recovered)", self.name)
            else:
                self._failure_count = 0

    async def _on_failure(self, exc: Exception) -> None:
        async with self._lock:
            self._failure_count += 1
            logger.warning("[circuit:%s] failure %d/%d: %s", self.name, self._failure_count, self.failure_threshold, exc)
            if self._state == CircuitState.HALF_OPEN:
                self._state     = CircuitState.OPEN
                self._opened_at = time.monotonic()
                self._success_count = 0
                logger.error("[circuit:%s] trial failed — reopening", self.name)
            elif self._failure_count >= self.failure_threshold:
                self._state     = CircuitState.OPEN
                self._opened_at = time.monotonic()
                logger.error("[circuit:%s] threshold reached — OPEN for %ds", self.name, self.recovery_timeout)

    async def _maybe_transition(self) -> None:
        async with self._lock:
            if (
                self._state == CircuitState.OPEN
                and self._opened_at is not None
                and (time.monotonic() - self._opened_at) >= self.recovery_timeout
            ):
                self._state         = CircuitState.HALF_OPEN
                self._success_count = 0
                logger.info("[circuit:%s] HALF-OPEN — allowing trial request", self.name)

    def reset(self) -> None:
        self._state         = CircuitState.CLOSED
        self._failure_count = 0
        self._success_count = 0
        self._opened_at     = None
        logger.info("[circuit:%s] manually reset to CLOSED", self.name)

    def stats(self) -> dict:
        return {
            "name":          self.name,
            "state":         self._state.value,
            "failure_count": self._failure_count,
            "success_count": self._success_count,
            "opened_at":     self._opened_at,
        }


# ── Pre-configured breakers ───────────────────────────────────────────────────
gemini_breaker     = CircuitBreaker("gemini",     failure_threshold=5, recovery_timeout=30)
openrouter_breaker = CircuitBreaker("openrouter", failure_threshold=5, recovery_timeout=30)
groq_breaker       = CircuitBreaker("groq",       failure_threshold=5, recovery_timeout=30)
mpesa_breaker      = CircuitBreaker("mpesa",      failure_threshold=3, recovery_timeout=60)
