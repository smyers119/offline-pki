import logging
import logging.handlers
import sys
import traceback
import click
from pathlib import Path

from .certificate import certificate
from .yubikey import yubikey

logger = logging.getLogger("offline-pki")


class CustomFormatter(logging.Formatter):
    def formatException(self, exc_info):
        exc_type, exc_value, tb = exc_info

        # Find the frame from our code
        relevant_frame = None
        for frame in traceback.extract_tb(tb):
            if Path(frame.filename).parent == Path(__file__).parent:
                relevant_frame = frame

        if relevant_frame is None:
            return super().formatException(self, exc_info)

        relative_filename = Path(relevant_frame.filename).relative_to(
            Path(__file__).parent
        )
        return f" At {relative_filename}:{relevant_frame.lineno}: {relevant_frame.line}"


@click.group()
@click.option("--debug", is_flag=True, default=False)
def cli(debug: bool) -> int:
    """Simple offline PKI using Yubikeys as HSM.

    This program is a very barebone PKI for offline certificates. It requires at
    least three Yubikeys as HSM to store the root certificate (on "ROOT1" and
    "ROOT2", as a backup) and the intermediate certificate (on "INTERMEDIATE").

    The features are quite limited as it only provides root CA and intermediate
    CA creation, CRL gene ration for each of them, and certificate signing.
    """
    root = logging.getLogger("")
    root.setLevel(logging.INFO)
    logger.setLevel(debug and logging.DEBUG or logging.INFO)
    ch = logging.StreamHandler()
    ch.setFormatter(CustomFormatter("%(levelname)s[%(name)s] %(message)s"))
    root.addHandler(ch)


cli.add_command(yubikey)
cli.add_command(certificate)


def main():
    try:
        return cli(prog_name="offline-pki")
    except Exception as e:
        logger.exception("%s", e)
        sys.exit(1)


if __name__ == "__main__":
    sys.exit(main())
