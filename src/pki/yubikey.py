import logging
import warnings
import re
import secrets
import time
import click
from enum import StrEnum, unique


DEFAULT_PIN = "123456"
DEFAULT_PUK = "12345678"
DEFAULT_MANAGEMENT = bytes.fromhex("010203040506070801020304050607080102030405060708")

logger = logging.getLogger("pki-yubikey")


@unique
class YUBIKEY(StrEnum):
    ROOT = "Root X"
    INTERMEDIATE = "Intermediate"


def validate_pin(ctx, param, value):
    if not re.match(r"[0-9]{6,8}", value):
        raise click.BadParameter("PIN should be 6 to 8 numeric string")
    return value


def validate_puk(ctx, param, value):
    if not re.match(r"[a-zA-Z0-9]{6,8}", value):
        raise click.BadParameter("PUK should be 6 to 8 alphanumeric string")
    return value


def validate_management_key(ctx, param, val):
    try:
        if val == ".":
            val = secrets.token_bytes(32)
            logger.warning(f"Using random management key: {val.hex()}")
            return val
        if type(val) is str:
            val = bytes.fromhex(val)
        if len(val) == 32:
            return val
    except ValueError:
        pass
    raise click.BadParameter(
        "Management key must be exactly 32 (64 hexadecimal digits) long."
    )


def yubikey_one(yk: YUBIKEY):
    """Get exactly one Yubikey."""
    from . import dependencies as d

    click.pause(f'Plug Yubikey "{yk}"...')
    devices = list(d.list_all_devices())
    for nb, di in enumerate(devices):
        device, info = di
        logger.info(f"{nb: >2}: {device.fingerprint}")
        logger.info(f"SN: {info.serial}")
        if len(devices) == 1:
            return device
    if len(devices) == 0:
        raise RuntimeError("No Yubikey found!")
    raise RuntimeError("Too many Yubikeys found!")


def click_pin(yk: str):
    return click.option(
        "--pin",
        prompt=f"PIN code for {yk}",
        help=f"PIN code for {yk}",
        hide_input=True,
        type=click.STRING,
        callback=validate_pin,
    )


def click_management_key(yk: str):
    return click.option(
        "--management-key",
        prompt=f"Management key for {yk}",
        help=f"Management key for {yk}",
        hide_input=True,
        type=click.UNPROCESSED,
        callback=validate_management_key,
    )


@click.group()
def yubikey() -> None:
    """Yubikey management."""


@yubikey.command("info")
def yubikey_info() -> None:
    """Display information about the inserted Yubikeys."""
    from . import dependencies as d

    for nb, di in enumerate(d.list_all_devices()):
        device, info = di
        logger.info(f"{nb: >2}: {device.fingerprint}")
        logger.info(f"SN: {info.serial}")
        logger.info(f"Version: {info.version}")
        with device.open_connection(d.SmartCardConnection) as conn:
            piv = d.PivSession(conn)
            logger.info(f"Slot {d.SLOT.SIGNATURE}:")
            try:
                data = piv.get_slot_metadata(d.SLOT.SIGNATURE)
            except d.ApduError as e:
                if e.sw == d.SW.REFERENCE_DATA_NOT_FOUND:
                    logger.info("  Empty")
                    continue
            logger.info(f"  Private key type: {data.key_type}")
            cert = piv.get_certificate(d.SLOT.SIGNATURE)
            pkey = data.public_key
            algorithm = pkey.curve.name
            issuer = cert.issuer.rfc4514_string()
            subject = cert.subject.rfc4514_string()
            serial = cert.serial_number
            not_before = cert.not_valid_before_utc.isoformat()
            not_after = cert.not_valid_after_utc.isoformat()
            pem_data = cert.public_bytes(encoding=d.serialization.Encoding.PEM).decode(
                "utf-8"
            )
            logger.info("  Public key: ")
            logger.info(f"    Algorithm:  {algorithm}")
            logger.info(f"    Issuer:     {issuer}")
            logger.info(f"    Subject:    {subject}")
            logger.info(f"    Serial:     {serial}")
            logger.info(f"    Not before: {not_before}")
            logger.info(f"    Not after:  {not_after}")
            logger.info(f"    PEM:\n{pem_data}")


@yubikey.command("reset")
@click.confirmation_option(
    prompt="This will reset the connected Yubikey. Are you sure?"
)
@click.option(
    "--new-pin",
    prompt="New PIN code",
    help="PIN code",
    hide_input=True,
    confirmation_prompt=True,
    type=click.STRING,
    callback=validate_pin,
)
@click.option(
    "--new-puk",
    prompt="New PUK code",
    help="PUK code",
    hide_input=True,
    confirmation_prompt=True,
    type=click.STRING,
    callback=validate_puk,
)
@click.option(
    "--new-management-key",
    prompt="New management key ('.' to generate a random one)",
    help="Management key",
    hide_input=True,
    type=click.UNPROCESSED,
    callback=validate_management_key,
)
def yubikey_reset(new_pin: str, new_puk: str, new_management_key: bytes) -> None:
    """Reset the inserted Yubikeys."""
    from . import dependencies as d

    found = False
    for nb, di in enumerate(d.list_all_devices()):
        found = True
        device, info = di
        logger.info(f"{nb: >2}: {device.fingerprint}")
        logger.info(f"SN: {info.serial}")
        logger.info(f"Version: {info.version}")
        with device.open_connection(d.SmartCardConnection) as conn:
            mgt = d.ManagementSession(conn)
            logger.debug("Only enable PIV application")
            config = d.DeviceConfig({}, None, None, None)
            config.enabled_capabilities = {
                d.TRANSPORT.NFC: d.CAPABILITY(0),
                d.TRANSPORT.USB: d.CAPABILITY.PIV,
            }
            mgt.write_device_config(config, True, None, None)
        logger.debug("Wait a bit for Yubikey to reboot")
        for retry in reversed(range(5)):
            with warnings.catch_warnings():
                warnings.filterwarnings("ignore", message="Failed opening device")
                time.sleep(1)
                for _, di2 in enumerate(d.list_all_devices()):
                    device2, info2 = di2
                    if info2.serial == info.serial:
                        device = device2
                        break
                else:
                    if retry > 0:
                        continue
                    raise RuntimeError("no Yubikey found")
                break
        with device.open_connection(d.SmartCardConnection) as conn:
            piv = d.PivSession(conn)
            logger.debug("Reset PIV application")
            piv.reset()
            logger.debug("Set management key")
            piv.authenticate(DEFAULT_MANAGEMENT)
            d.pivman_set_mgm_key(piv, new_management_key, d.MANAGEMENT_KEY_TYPE.AES256)
            logger.debug("Set PIN and PUK code")
            piv.change_puk(DEFAULT_PUK, new_puk)
            d.pivman_change_pin(piv, DEFAULT_PIN, new_pin)
        logger.info("Yubikey reset successful!")
    if not found:
        raise RuntimeError("No Yubikey found!")
