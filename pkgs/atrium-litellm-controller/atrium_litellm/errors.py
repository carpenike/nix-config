import re


class ControllerError(Exception):
    """Bounded codes only: native bodies and exception representations are secret."""

    def __init__(self, code: str):
        if not re.fullmatch(r"[a-z][a-z0-9_]{0,79}", code):
            code = "controller_error"
        self.code = code
        super().__init__(code)


def require(condition: object, code: str) -> None:
    if not condition:
        raise ControllerError(code)
