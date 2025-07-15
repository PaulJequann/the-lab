import bcrypt
from typing import Any
import makejinja


def bcrypt_password(value: str) -> str:
    """Return the bcrypt hash of the given password string."""
    salt = bcrypt.gensalt()
    hashed = bcrypt.hashpw(value.encode('utf-8'), salt)
    return hashed.decode('utf-8')


class Plugin(makejinja.plugin.Plugin):
    def __init__(self, data: dict[str, Any], config: makejinja.config.Config):
        # Store config/data if needed for future extension
        self._data = data
        self._config = config

    def filters(self) -> makejinja.plugin.Filters:
        # Only the bcrypt_password filter is registered
        return [bcrypt_password]
