from typing import Any, Callable
from urllib.parse import quote
import makejinja


def urlencode(value: str) -> str:
    """Percent-encode a string for safe embedding in URLs."""
    return quote(value, safe="")


class Plugin(makejinja.plugin.Plugin):
    def __init__(self, data: dict[str, Any], config: makejinja.config.Config):
        self._data = data
        self._config = config

    def filters(self) -> makejinja.plugin.Filters:
        return [urlencode]

    def globals(self) -> list[Callable[..., Any]]:
        return []
