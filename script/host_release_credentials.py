#!/usr/bin/env python3
"""Local release credentials and isolated signing imports, without secret argv.

The store uses the current user's default, file-based macOS Keychain. New items
trust only the calling Python executable; updates preserve their existing ACLs.
All Keychain operations disable authentication UI. An unlocked Keychain and a
trusted, stable Python executable are prerequisites, not permissions this module
can grant. Other scripts running under the same executable share that identity.
CI must supply credentials through its secret environment, not this local store.

Only ``import`` is exposed by the CLI: there is deliberately no export command.
The signing helper imports bytes into an explicitly supplied, already-created
Keychain. Its caller owns that temporary Keychain's creation and cleanup.
"""

from __future__ import annotations

import argparse
import base64
import binascii
from contextlib import ExitStack, contextmanager
import ctypes
from dataclasses import dataclass
import getpass
import os
from pathlib import Path
import stat
import sys
import threading
from typing import Iterator
import warnings


SERVICE = "dev.bunn.glassydesk.release"
ACCOUNTS = (
    "github-token",
    "cloudflare-token",
    "sparkle-key",
    "notary-key",
    "codesign-p12",
    "codesign-password",
)
MAX_SECRET_BYTES = 1024 * 1024
_SUCCESS = 0
_DUPLICATE_ITEM = -25299
_ITEM_NOT_FOUND = -25300
_AUTH_FAILED = -25293
_INTERACTION_NOT_ALLOWED = -25308
_USER_CANCELED = -128
_NO_SUCH_KEYCHAIN = -25294
_INVALID_KEYCHAIN = -25295
_NOT_AVAILABLE = -25291
_DECODE_ERROR = -26275
_INTERACTION_LOCK = threading.RLock()


class CredentialError(RuntimeError):
    """An actionable error whose message never includes credential contents."""


def _check_status(status: int, operation: str) -> None:
    if status == _SUCCESS:
        return
    if status in (_AUTH_FAILED, _INTERACTION_NOT_ALLOWED, _USER_CANCELED):
        raise CredentialError(
            f"Cannot {operation}: Keychain access requires authentication or permission "
            f"(status {status}). Unlock the user Keychain in Keychain Access and use "
            "the same trusted Python executable used for setup, or supply the release "
            "credential through its environment variable. No authentication dialog was requested."
        )
    if status in (_NO_SUCH_KEYCHAIN, _INVALID_KEYCHAIN, _NOT_AVAILABLE):
        raise CredentialError(
            f"Cannot {operation}: the requested Keychain is unavailable (status {status}). "
            "Check its existence and unlock state, or supply credentials through the environment."
        )
    raise CredentialError(f"Cannot {operation}: Security.framework returned status {status}.")


def _check_account(account: str) -> None:
    if account not in ACCOUNTS:
        raise CredentialError("Unknown release credential name. Use --help to list supported names.")


def _secret_bytes(account: str, secret: str) -> bytes:
    if not isinstance(secret, str):
        raise CredentialError("A release credential must be text.")
    try:
        encoded = secret.encode("utf-8")
    except UnicodeError:
        raise CredentialError("The release credential must contain valid UTF-8 text.") from None
    if b"\0" in encoded:
        raise CredentialError("A release credential cannot contain a null character.")
    if not encoded and account != "codesign-password":
        raise CredentialError("The release credential is empty.")
    if len(encoded) > MAX_SECRET_BYTES:
        raise CredentialError("The release credential exceeds the 1 MiB size limit.")
    return encoded


def _is_ci() -> bool:
    return any(
        os.environ.get(name, "").lower() not in ("", "0", "false", "no")
        for name in ("CI", "GITHUB_ACTIONS")
    )


@dataclass(frozen=True)
class _Symbol:
    name: str


@dataclass(frozen=True)
class _CFRef:
    pointer: int


class _ArrayCallbacks(ctypes.Structure):
    _fields_ = [("version", ctypes.c_long)] + [
        (name, ctypes.c_void_p) for name in ("retain", "release", "description", "equal")
    ]


class _DictionaryKeyCallbacks(ctypes.Structure):
    _fields_ = _ArrayCallbacks._fields_ + [("hash", ctypes.c_void_p)]


class _DictionaryValueCallbacks(ctypes.Structure):
    _fields_ = _ArrayCallbacks._fields_


class _NativeSecurity:
    """Small owning CF bridge; dictionary keys are Security constant names."""

    def __init__(self) -> None:
        if sys.platform != "darwin":
            raise CredentialError("Local Keychain credentials require macOS. In CI, use secret environment variables.")
        try:
            self.cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
            self.sec = ctypes.CDLL("/System/Library/Frameworks/Security.framework/Security")
            self._configure()
        except (OSError, AttributeError, ValueError):
            raise CredentialError("The required macOS Security.framework APIs are unavailable.") from None

    def _configure(self) -> None:
        ref = ctypes.c_void_p
        refs = ctypes.POINTER(ref)
        index = ctypes.c_long
        status = ctypes.c_int32
        boolean = ctypes.c_ubyte
        signatures = {
            "CFRelease": (None, [ref]),
            "CFGetTypeID": (ctypes.c_ulong, [ref]),
            "CFDataGetTypeID": (ctypes.c_ulong, []),
            "CFArrayGetTypeID": (ctypes.c_ulong, []),
            "CFDictionaryGetTypeID": (ctypes.c_ulong, []),
            "CFDataCreate": (ref, [ref, ref, index]),
            "CFDataGetLength": (index, [ref]),
            "CFDataGetBytePtr": (ref, [ref]),
            "CFStringCreateWithBytes": (ref, [ref, ref, index, ctypes.c_uint32, boolean]),
            "CFArrayCreate": (ref, [ref, refs, index, ctypes.POINTER(_ArrayCallbacks)]),
            "CFArrayGetCount": (index, [ref]),
            "CFArrayGetValueAtIndex": (ref, [ref, index]),
            "CFDictionaryCreate": (
                ref,
                [ref, refs, refs, index, ctypes.POINTER(_DictionaryKeyCallbacks), ctypes.POINTER(_DictionaryValueCallbacks)],
            ),
            "CFDictionaryGetValue": (ref, [ref, ref]),
        }
        for name, (result, args) in signatures.items():
            function = getattr(self.cf, name)
            function.restype, function.argtypes = result, args
        signatures = {
            "SecItemCopyMatching": (status, [ref, refs]),
            "SecItemUpdate": (status, [ref, ref]),
            "SecItemAdd": (status, [ref, refs]),
            "SecKeychainCopyDefault": (status, [refs]),
            "SecKeychainOpen": (status, [ctypes.c_char_p, refs]),
            "SecKeychainGetUserInteractionAllowed": (status, [ctypes.POINTER(boolean)]),
            "SecKeychainSetUserInteractionAllowed": (status, [boolean]),
            "SecAccessCreate": (status, [ref, ref, refs]),
            "SecTrustedApplicationCreateFromPath": (status, [ctypes.c_char_p, refs]),
            "SecPKCS12Import": (status, [ref, ref, refs]),
        }
        for name, (result, args) in signatures.items():
            function = getattr(self.sec, name)
            function.restype, function.argtypes = result, args
        self.array_callbacks = _ArrayCallbacks.in_dll(self.cf, "kCFTypeArrayCallBacks")
        self.key_callbacks = _DictionaryKeyCallbacks.in_dll(self.cf, "kCFTypeDictionaryKeyCallBacks")
        self.value_callbacks = _DictionaryValueCallbacks.in_dll(self.cf, "kCFTypeDictionaryValueCallBacks")

    def _symbol(self, name: str) -> int:
        try:
            pointer = ctypes.c_void_p.in_dll(self.sec, name).value
        except ValueError:
            raise CredentialError("A required macOS Keychain API constant is unavailable.") from None
        if not pointer:
            raise CredentialError("A required macOS Keychain API constant is unavailable.")
        return pointer

    @contextmanager
    def _value(self, value: object) -> Iterator[int]:
        if isinstance(value, _Symbol):
            yield self._symbol(value.name)
            return
        if isinstance(value, _CFRef):
            yield value.pointer
            return
        if isinstance(value, bool):
            yield ctypes.c_void_p.in_dll(self.cf, "kCFBooleanTrue" if value else "kCFBooleanFalse").value
            return
        with ExitStack() as stack:
            if isinstance(value, str):
                encoded = value.encode("utf-8")
                data = ctypes.create_string_buffer(encoded)
                pointer = self.cf.CFStringCreateWithBytes(None, data, len(encoded), 0x08000100, False)
            elif isinstance(value, bytes):
                data = ctypes.create_string_buffer(value)
                pointer = self.cf.CFDataCreate(None, data, len(value))
            elif isinstance(value, dict):
                keys = [self._symbol(key) for key in value]
                values = [stack.enter_context(self._value(item)) for item in value.values()]
                pointer = self.cf.CFDictionaryCreate(
                    None, (ctypes.c_void_p * len(keys))(*keys), (ctypes.c_void_p * len(values))(*values),
                    len(keys), ctypes.byref(self.key_callbacks), ctypes.byref(self.value_callbacks),
                )
            elif isinstance(value, (list, tuple)):
                values = [stack.enter_context(self._value(item)) for item in value]
                pointer = self.cf.CFArrayCreate(
                    None, (ctypes.c_void_p * len(values))(*values), len(values), ctypes.byref(self.array_callbacks),
                )
            else:
                raise CredentialError("Unsupported internal Keychain value type.")
            if not pointer:
                raise CredentialError("Unable to allocate a Keychain request.")
            try:
                yield pointer
            finally:
                self.cf.CFRelease(pointer)

    @contextmanager
    def no_ui(self) -> Iterator[None]:
        # Legacy file-based Keychain APIs also need this process-scoped guard.
        # Restore the prior setting; no persistent Keychain policy is changed.
        with _INTERACTION_LOCK:
            previous = ctypes.c_ubyte()
            _check_status(self.sec.SecKeychainGetUserInteractionAllowed(ctypes.byref(previous)), "read Keychain UI policy")
            _check_status(self.sec.SecKeychainSetUserInteractionAllowed(False), "disable Keychain authentication UI")
            try:
                yield
            finally:
                _check_status(self.sec.SecKeychainSetUserInteractionAllowed(previous.value), "restore Keychain UI policy")

    @contextmanager
    def default_keychain(self) -> Iterator[_CFRef]:
        result = ctypes.c_void_p()
        status = self.sec.SecKeychainCopyDefault(ctypes.byref(result))
        try:
            _check_status(status, "open the user's default Keychain")
            if not result.value:
                raise CredentialError("The user's default Keychain is unavailable.")
            yield _CFRef(result.value)
        finally:
            if result.value:
                self.cf.CFRelease(result.value)

    @contextmanager
    def open_keychain(self, path: Path) -> Iterator[_CFRef]:
        result = ctypes.c_void_p()
        status = self.sec.SecKeychainOpen(os.fsencode(path), ctypes.byref(result))
        try:
            _check_status(status, "open the isolated signing Keychain")
            if not result.value:
                raise CredentialError("The isolated signing Keychain is unavailable.")
            yield _CFRef(result.value)
        finally:
            if result.value:
                self.cf.CFRelease(result.value)

    @contextmanager
    def calling_application_access(self, description: str) -> Iterator[_CFRef]:
        # A NULL trusted-list means only the calling executable, not all apps.
        with self._access(description, None) as access:
            yield access

    @contextmanager
    def codesigning_access(self) -> Iterator[_CFRef]:
        application = ctypes.c_void_p()
        status = self.sec.SecTrustedApplicationCreateFromPath(b"/usr/bin/codesign", ctypes.byref(application))
        try:
            _check_status(status, "identify the trusted system code-signing tool")
            if not application.value:
                raise CredentialError("The trusted system code-signing tool is unavailable.")
            with self._value([_CFRef(application.value)]) as trusted_list:
                # Partition IDs are an additional gate; they do not grant an
                # unlisted executable access through this application ACL.
                with self._access("Glassy Host release signing identity", trusted_list) as access:
                    yield access
        finally:
            if application.value:
                self.cf.CFRelease(application.value)

    @contextmanager
    def _access(self, description: str, trusted_list: int | None) -> Iterator[_CFRef]:
        result = ctypes.c_void_p()
        with self._value(description) as descriptor:
            status = self.sec.SecAccessCreate(descriptor, trusted_list, ctypes.byref(result))
        try:
            _check_status(status, "create a restricted Keychain access policy")
            if not result.value:
                raise CredentialError("Unable to create a restricted Keychain access policy.")
            yield _CFRef(result.value)
        finally:
            if result.value:
                self.cf.CFRelease(result.value)

    def copy_matching(self, query: dict) -> tuple[int, bytes | None]:
        result = ctypes.c_void_p()
        with self._value(query) as query_ref:
            status = self.sec.SecItemCopyMatching(query_ref, ctypes.byref(result))
        try:
            if status != _SUCCESS:
                return status, None
            if not result.value or self.cf.CFGetTypeID(result.value) != self.cf.CFDataGetTypeID():
                raise CredentialError("The stored release credential has an unexpected Keychain data type.")
            length = self.cf.CFDataGetLength(result.value)
            if length < 0 or length > MAX_SECRET_BYTES:
                raise CredentialError("The stored release credential exceeds the 1 MiB size limit.")
            return status, ctypes.string_at(self.cf.CFDataGetBytePtr(result.value), length)
        finally:
            if result.value:
                self.cf.CFRelease(result.value)

    def update(self, query: dict, attributes: dict) -> int:
        with self._value(query) as query_ref, self._value(attributes) as attributes_ref:
            return self.sec.SecItemUpdate(query_ref, attributes_ref)

    def add(self, attributes: dict) -> int:
        with self._value(attributes) as attributes_ref:
            return self.sec.SecItemAdd(attributes_ref, None)

    def import_pkcs12(self, p12: bytes, options: dict) -> tuple[int, bool]:
        result = ctypes.c_void_p()
        with self._value(p12) as data_ref, self._value(options) as options_ref:
            status = self.sec.SecPKCS12Import(data_ref, options_ref, ctypes.byref(result))
        try:
            if status != _SUCCESS:
                return status, False
            if not result.value or self.cf.CFGetTypeID(result.value) != self.cf.CFArrayGetTypeID():
                return status, False
            identity_key = self._symbol("kSecImportItemIdentity")
            for index in range(self.cf.CFArrayGetCount(result.value)):
                item = self.cf.CFArrayGetValueAtIndex(result.value, index)
                if item and self.cf.CFGetTypeID(item) == self.cf.CFDictionaryGetTypeID():
                    if self.cf.CFDictionaryGetValue(item, identity_key):
                        return status, True
            return status, False
        finally:
            if result.value:
                self.cf.CFRelease(result.value)


class CredentialStore:
    """Current-user release secrets. Empty code-sign passwords remain valid values."""

    def __init__(self) -> None:
        self._native: _NativeSecurity | None = None

    def _api(self) -> _NativeSecurity:
        if _is_ci():
            raise CredentialError("CI must use secret environment variables; local Keychain credential access is disabled.")
        if self._native is None:
            self._native = _NativeSecurity()
        return self._native

    @staticmethod
    def _identity(account: str) -> dict:
        return {
            "kSecClass": _Symbol("kSecClassGenericPassword"),
            "kSecAttrService": SERVICE,
            "kSecAttrAccount": account,
            "kSecAttrSynchronizable": False,
            "kSecUseDataProtectionKeychain": False,
            "kSecUseAuthenticationUI": _Symbol("kSecUseAuthenticationUIFail"),
        }

    def get(self, account: str) -> str | None:
        _check_account(account)
        api = self._api()
        with api.no_ui(), api.default_keychain() as keychain:
            query = self._identity(account) | {
                "kSecMatchSearchList": [keychain],
                "kSecMatchLimit": _Symbol("kSecMatchLimitOne"),
                "kSecReturnData": True,
            }
            status, data = api.copy_matching(query)
            if status == _ITEM_NOT_FOUND:
                return None
            _check_status(status, "read the release credential")
            if data is None:
                raise CredentialError("The stored release credential is missing its data.")
            try:
                secret = data.decode("utf-8")
            except UnicodeError:
                raise CredentialError("The stored release credential is not valid UTF-8 text. Import it again.") from None
            _secret_bytes(account, secret)
            return secret

    def set(self, account: str, secret: str) -> None:
        _check_account(account)
        data = _secret_bytes(account, secret)
        api = self._api()
        with api.no_ui(), api.default_keychain() as keychain:
            query = self._identity(account) | {"kSecMatchSearchList": [keychain]}
            # Change only data on existing records. Never delete/re-add an item
            # or weaken its ACL to make a headless update succeed.
            status = api.update(query, {"kSecValueData": data})
            if status == _ITEM_NOT_FOUND:
                with api.calling_application_access("Glassy Host release credential") as access:
                    attributes = self._identity(account) | {
                        "kSecUseKeychain": keychain,
                        "kSecAttrAccess": access,
                        "kSecValueData": data,
                    }
                    status = api.add(attributes)
                if status == _DUPLICATE_ITEM:
                    # Another setup process may have created it after our lookup.
                    status = api.update(query, {"kSecValueData": data})
            _check_status(status, "store the release credential")


def import_signing_identity(p12: bytes, password: str, keychain_path: Path) -> None:
    """Import into an existing isolated Keychain; no secret ever enters argv.

    Unlike CredentialStore, this is also usable in CI with environment-supplied
    P12 bytes/password. The caller must create, unlock, and clean up the explicit
    temporary Keychain, and pass its path to each code-signing operation.
    Imported private keys trust only /usr/bin/codesign; the caller must also
    configure the temporary Keychain's partition list for unattended signing.
    """
    if not isinstance(p12, bytes) or not p12 or len(p12) > MAX_SECRET_BYTES:
        raise CredentialError("The signing P12 must contain between 1 byte and 1 MiB of binary data.")
    _secret_bytes("codesign-password", password)
    path = Path(keychain_path)
    if not path.is_absolute() or not path.is_file() or path.is_symlink():
        raise CredentialError("The isolated signing Keychain must be an existing regular file at an absolute path.")
    api = _NativeSecurity()
    with api.no_ui(), api.open_keychain(path) as keychain:
        with api.codesigning_access() as access:
            status, contains_identity = api.import_pkcs12(p12, {
                "kSecImportExportPassphrase": password,
                "kSecImportExportKeychain": keychain,
                "kSecImportExportAccess": access,
            })
    if status == _AUTH_FAILED:
        raise CredentialError("Unable to import the signing identity: the P12 password is incorrect or the P12 data is damaged.")
    if status == _DECODE_ERROR:
        raise CredentialError("Unable to import the signing identity: the P12 data is malformed.")
    _check_status(status, "import the signing identity into the isolated Keychain")
    if not contains_identity:
        raise CredentialError("The signing P12 does not contain a certificate with its private key.")


def _read_private_file(path: str) -> bytes:
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as source:
            info = os.fstat(source.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                raise CredentialError("The credential source must be a regular file owned by the current user.")
            if stat.S_IMODE(info.st_mode) & 0o077:
                raise CredentialError("The credential source is accessible to other users. Set its permissions to 600 before importing.")
            data = source.read(MAX_SECRET_BYTES + 1)
    except OSError:
        raise CredentialError("Unable to open the credential source. Use a readable regular file, not a symbolic link.") from None
    if len(data) > MAX_SECRET_BYTES:
        raise CredentialError("The credential source exceeds the 1 MiB size limit.")
    return data


def _read_import(name: str, file: str | None) -> str:
    if file is None:
        if not sys.stdin.isatty():
            raise CredentialError("Hidden credential entry needs a terminal. Use --file - for a secure stdin pipeline.")
        try:
            with warnings.catch_warnings():
                # getpass otherwise falls back to visible input if disabling
                # terminal echo fails. Refuse that fallback before it reads.
                warnings.simplefilter("error", getpass.GetPassWarning)
                return getpass.getpass(f"{name} (hidden): ")
        except getpass.GetPassWarning:
            raise CredentialError("Unable to disable terminal echo. Use a private credential file or a secure stdin pipeline.") from None
        except (EOFError, KeyboardInterrupt):
            raise CredentialError("Credential import was canceled.") from None
    if file == "-":
        if sys.stdin.isatty():
            raise CredentialError("Use a pipe with --file -, or omit --file for hidden terminal entry.")
        try:
            data = sys.stdin.buffer.read(MAX_SECRET_BYTES + 1)
        except OSError:
            raise CredentialError("Unable to read the credential from stdin.") from None
        if len(data) > MAX_SECRET_BYTES:
            raise CredentialError("The credential source exceeds the 1 MiB size limit.")
    else:
        data = _read_private_file(file)
        if name == "codesign-p12":
            return base64.b64encode(data).decode("ascii")
    try:
        return data.decode("utf-8")
    except UnicodeError:
        raise CredentialError("The credential source must be UTF-8 text; codesign-p12 stdin must be base64 text.") from None


class _SafeArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        # argparse normally echoes invalid arguments, which could contain a
        # mistakenly supplied secret. Keep the error independent of argv.
        self.exit(2, "Invalid arguments. Use --help; credential values must never be passed as arguments.\n")


def main(argv: list[str] | None = None) -> int:
    parser = _SafeArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    setup = commands.add_parser("import", help="Store a credential from a private file, stdin, or a hidden prompt.")
    setup.add_argument("--name", choices=ACCOUNTS, required=True)
    setup.add_argument(
        "--file", metavar="PATH|-",
        help="Read a current-user-only (600) file, or stdin with '-'. For codesign-p12, PATH is binary P12; stdin is base64 text. Without --file, use hidden entry (base64 for codesign-p12).",
    )
    args = parser.parse_args(argv)
    try:
        if _is_ci():
            raise CredentialError("CI must use secret environment variables; local Keychain setup is disabled.")
        secret = _read_import(args.name, args.file)
        if args.name == "codesign-p12":
            try:
                decoded = base64.b64decode("".join(secret.split()), validate=True)
            except (ValueError, binascii.Error):
                raise CredentialError("The signing P12 must be a binary file or valid base64 text on stdin.") from None
            if not decoded:
                raise CredentialError("The signing P12 is empty.")
            secret = base64.b64encode(decoded).decode("ascii")
        CredentialStore().set(args.name, secret)
    except CredentialError as error:
        print(str(error), file=sys.stderr)
        return 1
    print(f"Stored {args.name} in the current user's Keychain.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
