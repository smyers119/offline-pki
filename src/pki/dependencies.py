from ykman.device import list_all_devices
from ykman.piv import (
    pivman_change_pin,
    pivman_set_mgm_key,
    sign_certificate_builder,
)
from yubikit.core import TRANSPORT
from yubikit.core.smartcard import SmartCardConnection
from yubikit.management import ManagementSession, DeviceConfig, CAPABILITY
from yubikit.piv import (
    PivSession,
    SLOT,
    MANAGEMENT_KEY_TYPE,
    PIN_POLICY,
    TOUCH_POLICY,
    KEY_TYPE,
)

from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa, padding
