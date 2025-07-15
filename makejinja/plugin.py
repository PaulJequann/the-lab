import bcrypt
from typing import Any, Callable
import makejinja


def bcrypt_password(value: str) -> str:
    """Return the bcrypt hash of the given password string."""
    salt = bcrypt.gensalt()
    hashed = bcrypt.hashpw(value.encode('utf-8'), salt)
    return hashed.decode('utf-8')


def build_helm_secrets_path(ns: str, secret: str, key: str) -> str:
    return f"secrets+age-import-kubernetes://{ns}/{secret}#{key}?values.sops.yaml"


class Plugin(makejinja.plugin.Plugin):
    def __init__(self, data: dict[str, Any], config: makejinja.config.Config):
        # Store config/data if needed for future extension
        self._data = data
        self._config = config

    def filters(self) -> makejinja.plugin.Filters:
        # Only the bcrypt_password filter is registered
        return [bcrypt_password]

    def globals(self) -> list[Callable[..., Any]]:
        # This method registers functions that can be called directly in templates.
        return [build_helm_secrets_path]
