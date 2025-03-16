import sys
import logging
import click
import warnings
import typing
from datetime import datetime, timedelta, timezone
from cryptography.utils import CryptographyDeprecationWarning

from .yubikey import click_management_key, click_pin, yubikey_one, YUBIKEY


logger = logging.getLogger("pki-certificate")
warnings.filterwarnings(
    "ignore", category=CryptographyDeprecationWarning, message=".*TripleDES.*"
)


@click.group()
def certificate() -> None:
    """Certificate management."""


@certificate.command("root")
@click_management_key(YUBIKEY.ROOT)
@click.option(
    "--subject-name", default="CN=Root CA", help="Subject name", type=click.STRING
)
@click.option(
    "--days",
    default=365 * 20,
    help="Root certificate validity in days",
    type=click.IntRange(min=1),
)
def certificate_root(management_key: bytes, subject_name: str, days: int) -> None:
    """Initialize a new root certificate."""
    from . import dependencies as d

    logger.debug("Generate a new private key")
    private_key = d.ec.generate_private_key(d.ec.SECP384R1())
    subject = d.x509.Name.from_rfc4514_string(subject_name)
    logger.debug("Generate a new certificate")
    cert = (
        (
            d.x509.CertificateBuilder()
            .subject_name(subject)
            .issuer_name(subject)
            .public_key(private_key.public_key())
            .serial_number(1)
            .not_valid_before(datetime.now(timezone.utc))
            .not_valid_after(datetime.now(timezone.utc) + timedelta(days=days))
        )
        .add_extension(
            d.x509.BasicConstraints(ca=True, path_length=None),
            critical=True,
        )
        .add_extension(
            d.x509.KeyUsage(
                digital_signature=True,
                content_commitment=False,
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=True,
                crl_sign=True,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .sign(private_key, d.hashes.SHA384())
    )
    while True:
        with yubikey_one(YUBIKEY.ROOT).open_connection(d.SmartCardConnection) as conn:
            piv = d.PivSession(conn)
            piv.authenticate(management_key)
            piv.put_certificate(d.SLOT.SIGNATURE, cert, compress=True)
            piv.put_key(
                d.SLOT.SIGNATURE,
                private_key,
                d.PIN_POLICY.ONCE,
                d.TOUCH_POLICY.NEVER,
            )
        if not click.confirm("Copy root certificate to another YubiKey?"):
            break


@certificate.command("intermediate")
@click_management_key(YUBIKEY.INTERMEDIATE)
@click_pin(YUBIKEY.ROOT)
@click.option(
    "--subject-name",
    default="CN=Intermediate CA",
    help="Subject name",
    type=click.STRING,
)
@click.option(
    "--days",
    default=365 * 4,
    help="Intermediate certificate validity in days",
    type=click.IntRange(min=1),
)
def certificate_intermediate(
    management_key: bytes, pin: str, subject_name: str, days: int
) -> None:
    """Initialize a new intermediate certificate.

    If the subject name is missing an attribute compared to the root certificate,
    they are copied over.
    """
    from . import dependencies as d

    with yubikey_one(YUBIKEY.INTERMEDIATE).open_connection(
        d.SmartCardConnection
    ) as conn:
        logger.debug("Generate private key for intermediate certificate")
        piv = d.PivSession(conn)
        piv.authenticate(management_key)
        public_key = piv.generate_key(
            d.SLOT.SIGNATURE,
            d.KEY_TYPE.ECCP384,
            d.PIN_POLICY.ONCE,
            d.TOUCH_POLICY.NEVER,
        )
    with yubikey_one(YUBIKEY.ROOT).open_connection(d.SmartCardConnection) as conn:
        logger.debug("Create intermediate certificate")
        piv = d.PivSession(conn)
        root = piv.get_certificate(d.SLOT.SIGNATURE)
        if root.issuer.rfc4514_string() != root.subject.rfc4514_string():
            raise RuntimeError("The inserted key does not look like a root YubiKey!")
        issuer = root.subject
        subject = d.x509.Name.from_rfc4514_string(subject_name)
        missing = [
            attribute
            for attribute in issuer
            if attribute.oid not in [attr.oid for attr in subject]
        ]
        subject = d.x509.Name(missing + [attr for attr in subject])
        logger.debug(f"Subject name is {subject.rfc4514_string()}")
        cert = (
            (
                d.x509.CertificateBuilder()
                .subject_name(subject)
                .issuer_name(issuer)
                .public_key(public_key)
                .serial_number(d.x509.random_serial_number())
                .not_valid_before(datetime.now(timezone.utc))
                .not_valid_after(datetime.now(timezone.utc) + timedelta(days=days))
            )
            .add_extension(
                d.x509.BasicConstraints(ca=True, path_length=None),
                critical=True,
            )
            .add_extension(
                d.x509.KeyUsage(
                    digital_signature=True,
                    content_commitment=False,
                    key_encipherment=False,
                    data_encipherment=False,
                    key_agreement=False,
                    key_cert_sign=True,
                    crl_sign=True,
                    encipher_only=False,
                    decipher_only=False,
                ),
                critical=True,
            )
        )
        piv.verify_pin(pin)
        signed_cert = d.sign_certificate_builder(
            piv,
            slot=d.SLOT.SIGNATURE,
            key_type=d.KEY_TYPE.ECCP384,
            builder=cert,
            hash_algorithm=d.hashes.SHA384,
        )
    with yubikey_one(YUBIKEY.INTERMEDIATE).open_connection(
        d.SmartCardConnection
    ) as conn:
        logger.debug("Store certificate")
        piv = d.PivSession(conn)
        piv.authenticate(management_key)
        piv.put_certificate(d.SLOT.SIGNATURE, signed_cert, compress=True)


@certificate.command("sign")
@click_pin(YUBIKEY.INTERMEDIATE)
@click.option(
    "--subject-name",
    help="Subject name",
    type=click.STRING,
)
@click.option(
    "--days",
    default=365,
    help="Certificate validity in days",
    type=click.IntRange(min=1),
)
@click.option(
    "--csr-file", help="CSR file to sign", type=click.File("rt"), default=sys.stdin
)
@click.option(
    "--out-file",
    help="Output file for signed certificate",
    type=click.File("wt"),
    default=sys.stdout,
)
def certificate_sign(
    pin: str,
    subject_name: str,
    days: int,
    csr_file: typing.TextIO,
    out_file: typing.TextIO,
) -> None:
    """Sign a certificate request with the intermediate certificate.

    If no subject name is provided, the one from the CSR is used.
    """
    from . import dependencies as d

    logger.debug("load CSR file and check signature")
    csr = d.x509.load_pem_x509_csr(csr_file.read().encode("ascii"))
    public_key = csr.public_key()
    if (
        isinstance(public_key, d.rsa.RSAPublicKey)
        and csr.signature_hash_algorithm is not None
    ):
        public_key.verify(
            csr.signature,
            csr.tbs_certrequest_bytes,
            d.padding.PKCS1v15(),
            csr.signature_hash_algorithm,
        )
    elif isinstance(public_key, d.ec.EllipticCurvePublicKey):
        if csr.signature_hash_algorithm is None:
            raise ValueError("No hash algorithm in CSR")
        public_key.verify(
            csr.signature,
            csr.tbs_certrequest_bytes,
            d.ec.ECDSA(csr.signature_hash_algorithm),
        )
    else:
        raise ValueError(f"unsupported public key {public_key}")

    with yubikey_one(YUBIKEY.INTERMEDIATE).open_connection(
        d.SmartCardConnection
    ) as conn:
        piv = d.PivSession(conn)
        intermediate = piv.get_certificate(d.SLOT.SIGNATURE)
        if (
            intermediate.issuer.rfc4514_string()
            == intermediate.subject.rfc4514_string()
        ):
            raise RuntimeError(
                "The inserted key does not look like an intermediate YubiKey!"
            )

        logger.debug("build certificate")
        issuer = intermediate.subject
        if not subject_name:
            subject = csr.subject
        else:
            subject = d.x509.Name.from_rfc4514_string(subject_name)
            missing = [
                attribute
                for attribute in issuer
                if attribute.oid not in [attr.oid for attr in subject]
            ]
            subject = d.x509.Name(missing + [attr for attr in subject])
        logger.info(f"Subject name is {subject.rfc4514_string()}")
        cert = (
            d.x509.CertificateBuilder()
            .subject_name(subject)
            .issuer_name(issuer)
            .public_key(public_key)
            .serial_number(d.x509.random_serial_number())
            .not_valid_before(datetime.now(timezone.utc))
            .not_valid_after(datetime.now(timezone.utc) + timedelta(days=days))
        )
        for extension in csr.extensions:
            logger.debug(f"Add extension {extension.value}")
            cert = cert.add_extension(extension.value, extension.critical)
        # TODO: it would be useful to display the certificate, but there seems
        # to be no method for that.
        click.confirm("Sign this certificate?", abort=True)

        piv.verify_pin(pin)
        signed_cert = d.sign_certificate_builder(
            piv,
            slot=d.SLOT.SIGNATURE,
            key_type=d.KEY_TYPE.ECCP384,
            builder=cert,
            hash_algorithm=d.hashes.SHA384,
        )
        out_file.write(
            signed_cert.public_bytes(encoding=d.serialization.Encoding.PEM).decode(
                "ascii"
            )
        )
