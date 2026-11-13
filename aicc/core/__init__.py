"""Modell-, dataset-, körnings- och sessionshantering. Importerar aldrig PyTorch."""


class AppError(Exception):
    """Fel som ska visas för användaren (HTTP 400)."""


class NotFound(AppError):
    """Objektet finns inte (HTTP 404)."""
