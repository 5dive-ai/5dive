"""Python client for the 5dive CLI.

The distribution is named ``5dive``; the import name is ``fivedive`` because a
Python identifier cannot begin with a digit.

    from fivedive import FiveDive
    for t in FiveDive().tasks():
        print(t["ident"], t["status"])
"""

from .client import FiveDive, FiveDiveError, CliNotFound

__all__ = ["FiveDive", "FiveDiveError", "CliNotFound"]
__version__ = "0.1.0"
