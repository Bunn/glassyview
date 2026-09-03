"""Synthetic-only tests. No test opens or changes a real macOS Keychain."""

import base64
from contextlib import ExitStack, contextmanager, redirect_stderr, redirect_stdout
import ctypes
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import warnings

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import host_release_credentials as credentials


class FakeNative:
    def __init__(self):
        self.keychain = credentials._CFRef(101)
        self.access = credentials._CFRef(102)
        self.events = []
        self.queries = []
        self.updates = []
        self.additions = []
        self.imports = []
        self.copy_result = (0, b"synthetic-token")
        self.update_statuses = [0]
        self.add_status = 0
        self.import_result = (0, True)
        self.ui_disabled = False

    @contextmanager
    def no_ui(self):
        self.events.append("disable-ui")
        self.ui_disabled = True
        try:
            yield
        finally:
            self.ui_disabled = False
            self.events.append("restore-ui")

    @contextmanager
    def default_keychain(self):
        assert self.ui_disabled
        self.events.append("default-keychain")
        yield self.keychain

    @contextmanager
    def open_keychain(self, path):
        assert self.ui_disabled
        self.events.append(("open-keychain", path))
        yield self.keychain

    @contextmanager
    def calling_application_access(self, description):
        assert self.ui_disabled
        self.events.append("caller-only-access")
        yield self.access

    @contextmanager
    def codesigning_access(self):
        assert self.ui_disabled
        self.events.append("codesign-only-access")
        yield self.access

    def copy_matching(self, query):
        assert self.ui_disabled
        self.queries.append(query)
        return self.copy_result

    def update(self, query, attributes):
        assert self.ui_disabled
        self.updates.append((query, attributes))
        return self.update_statuses.pop(0)

    def add(self, attributes):
        assert self.ui_disabled
        self.additions.append(attributes)
        return self.add_status

    def import_pkcs12(self, p12, options):
        assert self.ui_disabled
        self.imports.append((p12, options))
        return self.import_result


class ContextTestCase(unittest.TestCase):
    def setUp(self):
        self.contexts = ExitStack()
        self.addCleanup(self.contexts.close)

    def enterContext(self, context):
        # Compatible with the Python 3.9 provided by Apple's developer tools.
        return self.contexts.enter_context(context)


class MockedNativeCase(ContextTestCase):
    def setUp(self):
        super().setUp()
        self.native = FakeNative()
        self.factory = self.enterContext(patch.object(credentials, "_NativeSecurity", return_value=self.native))
        self.enterContext(patch.dict(os.environ, {"CI": "", "GITHUB_ACTIONS": ""}))
        self.store = credentials.CredentialStore()


class MockedCredentialTests(MockedNativeCase):
    def test_read_is_scoped_to_service_account_and_default_user_keychain(self):
        self.assertEqual(self.store.get("github-token"), "synthetic-token")
        query = self.native.queries[0]
        self.assertEqual(query["kSecAttrService"], "dev.bunn.glassydesk.release")
        self.assertEqual(query["kSecAttrAccount"], "github-token")
        self.assertEqual(query["kSecClass"], credentials._Symbol("kSecClassGenericPassword"))
        self.assertEqual(query["kSecUseAuthenticationUI"], credentials._Symbol("kSecUseAuthenticationUIFail"))
        self.assertEqual(query["kSecMatchSearchList"], [self.native.keychain])
        self.assertFalse(query["kSecAttrSynchronizable"])
        self.assertFalse(query["kSecUseDataProtectionKeychain"])
        self.assertTrue(query["kSecReturnData"])
        self.assertEqual(self.native.events, ["disable-ui", "default-keychain", "restore-ui"])

    def test_only_item_not_found_returns_none(self):
        self.native.copy_result = (-25300, None)
        self.assertIsNone(self.store.get("github-token"))
        for status in (-25293, -25308, -128, -25291, -25294, -25295, -9999):
            with self.subTest(status=status):
                self.native.copy_result = (status, None)
                with self.assertRaises(credentials.CredentialError) as error:
                    self.store.get("github-token")
                self.assertIn(str(status), str(error.exception))
                self.assertNotIn("synthetic-token", str(error.exception))
                self.assertFalse(self.native.ui_disabled)

    def test_locked_keychain_message_is_actionable_and_does_not_prompt(self):
        self.native.copy_result = (-25308, None)
        with self.assertRaisesRegex(credentials.CredentialError, "Unlock.*trusted Python"):
            self.store.get("notary-key")

    def test_empty_signing_password_and_text_whitespace_are_preserved(self):
        self.native.copy_result = (0, b"")
        self.assertEqual(self.store.get("codesign-password"), "")
        self.native.copy_result = (0, b"  synthetic password \n")
        self.assertEqual(self.store.get("codesign-password"), "  synthetic password \n")
        self.store.set("codesign-password", "")
        self.assertEqual(self.native.updates[0][1], {"kSecValueData": b""})

    def test_invalid_stored_data_is_rejected_without_disclosure(self):
        for data in (None, b"\xffsecret", b"", b"secret\0suffix", b"s" * (credentials.MAX_SECRET_BYTES + 1)):
            with self.subTest(length=None if data is None else len(data)):
                self.native.copy_result = (0, data)
                with self.assertRaises(credentials.CredentialError) as error:
                    self.store.get("github-token")
                self.assertNotIn("suffix", str(error.exception))

    def test_existing_item_update_changes_only_data_and_keeps_acl(self):
        secret = "-----BEGIN PRIVATE KEY-----\nsynthetic\n-----END PRIVATE KEY-----\n"
        self.store.set("notary-key", secret)
        query, changed = self.native.updates[0]
        self.assertEqual(changed, {"kSecValueData": secret.encode()})
        self.assertEqual(query["kSecMatchSearchList"], [self.native.keychain])
        self.assertEqual(query["kSecUseAuthenticationUI"], credentials._Symbol("kSecUseAuthenticationUIFail"))
        self.assertNotIn("kSecAttrAccess", query)
        self.assertNotIn("caller-only-access", self.native.events)
        self.assertEqual(self.native.additions, [])

    def test_new_item_has_caller_only_access_and_explicit_user_keychain(self):
        self.native.update_statuses = [-25300]
        self.store.set("cloudflare-token", "synthetic-cloudflare")
        attributes = self.native.additions[0]
        self.assertEqual(attributes["kSecAttrAccess"], self.native.access)
        self.assertEqual(attributes["kSecUseKeychain"], self.native.keychain)
        self.assertEqual(attributes["kSecUseAuthenticationUI"], credentials._Symbol("kSecUseAuthenticationUIFail"))
        self.assertEqual(attributes["kSecValueData"], b"synthetic-cloudflare")
        self.assertNotIn("kSecMatchSearchList", attributes)
        self.assertIn("caller-only-access", self.native.events)

    def test_creation_race_retries_value_only_update(self):
        self.native.update_statuses = [-25300, 0]
        self.native.add_status = -25299
        self.store.set("sparkle-key", "synthetic-seed")
        self.assertEqual(len(self.native.additions), 1)
        self.assertEqual(self.native.updates, [self.native.updates[0], self.native.updates[0]])
        self.assertEqual(self.native.updates[1][1], {"kSecValueData": b"synthetic-seed"})

    def test_denied_update_does_not_recreate_item_or_change_access(self):
        self.native.update_statuses = [-25308]
        with self.assertRaises(credentials.CredentialError):
            self.store.set("github-token", "synthetic-new-token")
        self.assertEqual(self.native.additions, [])
        self.assertNotIn("caller-only-access", self.native.events)
        self.assertFalse(self.native.ui_disabled)

    def test_invalid_names_and_inputs_fail_before_native_access(self):
        for account, value in (("invalid", "synthetic"), ("github-token", ""), ("notary-key", "x\0y"),
                               ("sparkle-key", b"not-text"), ("github-token", "\ud800"),
                               ("github-token", "x" * (credentials.MAX_SECRET_BYTES + 1))):
            with self.subTest(account=account):
                with self.assertRaises(credentials.CredentialError):
                    self.store.set(account, value)
        with self.assertRaises(credentials.CredentialError):
            self.store.get("invalid")
        self.factory.assert_not_called()

    def test_ci_refuses_local_keychain_even_after_backend_was_initialized(self):
        self.store.get("github-token")
        for env in ({"CI": "true"}, {"GITHUB_ACTIONS": "true"}):
            with patch.dict(os.environ, env):
                with self.assertRaisesRegex(credentials.CredentialError, "CI must use"):
                    self.store.get("github-token")
                with self.assertRaises(credentials.CredentialError):
                    self.store.set("github-token", "synthetic")
        self.assertEqual(len(self.native.queries), 1)
        self.assertEqual(self.native.updates, [])


class SigningImportTests(MockedNativeCase):
    def setUp(self):
        super().setUp()
        self.directory = self.enterContext(tempfile.TemporaryDirectory())
        self.path = Path(self.directory) / "isolated.keychain-db"
        self.path.write_bytes(b"synthetic-keychain-placeholder")

    def test_signing_import_uses_only_explicit_keychain_and_no_password_argv(self):
        with patch.dict(os.environ, {"CI": "true"}):
            credentials.import_signing_identity(b"synthetic-p12", "synthetic p12 password", self.path)
        self.assertEqual(self.native.imports, [(b"synthetic-p12", {
            "kSecImportExportPassphrase": "synthetic p12 password",
            "kSecImportExportKeychain": self.native.keychain,
            "kSecImportExportAccess": self.native.access,
        })])
        self.assertNotIn("default-keychain", self.native.events)
        self.assertEqual(self.native.events, ["disable-ui", ("open-keychain", self.path), "codesign-only-access", "restore-ui"])

    def test_signing_import_handles_password_errors_and_missing_identity(self):
        for result, message in (((-25293, False), "password is incorrect"), ((-26275, False), "malformed"),
                                ((-25308, False), "authentication"), ((0, False), "private key")):
            with self.subTest(result=result):
                self.native.import_result = result
                with self.assertRaisesRegex(credentials.CredentialError, message) as error:
                    credentials.import_signing_identity(b"synthetic-p12", "synthetic-private-password", self.path)
                self.assertNotIn("synthetic-private-password", str(error.exception))
                self.assertFalse(self.native.ui_disabled)

    def test_signing_import_rejects_bad_input_before_native_access(self):
        for data, password, path in ((b"", "", self.path), ("not-bytes", "", self.path),
                                     (b"p12", "null\0password", self.path), (b"p12", "", Path("relative")),
                                     (b"p12", "", self.path.parent), (b"p12", "", self.path.parent / "missing")):
            with self.subTest(path=path):
                with self.assertRaises(credentials.CredentialError):
                    credentials.import_signing_identity(data, password, path)
        link = self.path.parent / "link"
        link.symlink_to(self.path)
        with self.assertRaises(credentials.CredentialError):
            credentials.import_signing_identity(b"p12", "", link)
        self.factory.assert_not_called()


class CLIImportTests(ContextTestCase):
    def setUp(self):
        super().setUp()
        self.enterContext(patch.dict(os.environ, {"CI": "", "GITHUB_ACTIONS": ""}))
        self.store = self.enterContext(patch.object(credentials, "CredentialStore")).return_value
        self.native_factory = self.enterContext(patch.object(credentials, "_NativeSecurity", side_effect=AssertionError("Unexpected Keychain access")))
        self.directory = Path(self.enterContext(tempfile.TemporaryDirectory()))

    def run_cli(self, args, stdin=None):
        stdout, stderr = io.StringIO(), io.StringIO()
        source = io.TextIOWrapper(io.BytesIO(stdin or b""), encoding="utf-8")
        with patch.object(sys, "stdin", source), redirect_stdout(stdout), redirect_stderr(stderr):
            status = credentials.main(args)
        return status, stdout.getvalue(), stderr.getvalue()

    def private_file(self, value):
        path = self.directory / "credential"
        path.write_bytes(value)
        path.chmod(0o600)
        return path

    def test_private_file_import_preserves_pem_and_prints_only_name(self):
        content = b"-----BEGIN PRIVATE KEY-----\nsynthetic-file-secret\n-----END PRIVATE KEY-----\n"
        status, stdout, stderr = self.run_cli(["import", "--name", "notary-key", "--file", str(self.private_file(content))])
        self.assertEqual(status, 0)
        self.store.set.assert_called_once_with("notary-key", content.decode())
        self.assertNotIn("synthetic-file-secret", stdout + stderr)
        self.assertIn("Stored notary-key", stdout)

    def test_binary_p12_file_is_encoded_and_base64_stdin_is_normalized(self):
        data = b"\x00synthetic\xffPKCS12\x80"
        value = base64.b64encode(data).decode()
        result = self.run_cli(["import", "--name", "codesign-p12", "--file", str(self.private_file(data))])
        self.assertEqual(result[0], 0)
        self.store.set.assert_called_with("codesign-p12", value)
        result = self.run_cli(["import", "--name", "codesign-p12", "--file", "-"], (value[:4] + "\n" + value[4:] + "\n").encode())
        self.assertEqual(result[0], 0)
        self.store.set.assert_called_with("codesign-p12", value)

    def test_stdin_preserves_password_whitespace_and_accepts_empty_password(self):
        result = self.run_cli(["import", "--name", "codesign-password", "--file", "-"], b"  synthetic password \n")
        self.assertEqual(result[0], 0)
        self.store.set.assert_called_with("codesign-password", "  synthetic password \n")
        result = self.run_cli(["import", "--name", "codesign-password", "--file", "-"], b"")
        self.assertEqual(result[0], 0)
        self.store.set.assert_called_with("codesign-password", "")

    def test_non_private_file_and_symlink_are_refused_before_store(self):
        path = self.private_file(b"synthetic-secret")
        path.chmod(0o644)
        result = self.run_cli(["import", "--name", "github-token", "--file", str(path)])
        self.assertEqual(result[0], 1)
        self.assertIn("600", result[2])
        path.chmod(0o600)
        link = self.directory / "link"
        link.symlink_to(path)
        self.assertEqual(self.run_cli(["import", "--name", "github-token", "--file", str(link)])[0], 1)
        self.store.set.assert_not_called()

    def test_non_regular_source_is_rejected_without_blocking_on_a_fifo(self):
        fifo = self.directory / "pipe"
        os.mkfifo(fifo, 0o600)
        self.assertEqual(self.run_cli(["import", "--name", "github-token", "--file", str(fifo)])[0], 1)
        self.store.set.assert_not_called()

    def test_invalid_utf8_oversize_input_and_invalid_base64_are_sanitized(self):
        for name, data in (("github-token", b"synthetic\xffsecret"),
                           ("github-token", b"s" * (credentials.MAX_SECRET_BYTES + 1)),
                           ("codesign-p12", b"synthetic not-base64!"), ("codesign-p12", b"")):
            with self.subTest(name=name, length=len(data)):
                status, stdout, stderr = self.run_cli(["import", "--name", name, "--file", "-"], data)
                self.assertEqual(status, 1)
                self.assertNotIn("synthetic", stdout + stderr)
        self.store.set.assert_not_called()

    def test_hidden_prompt_requires_tty_and_never_falls_back_to_visible_entry(self):
        result = self.run_cli(["import", "--name", "github-token"])
        self.assertEqual(result[0], 1)
        self.assertIn("needs a terminal", result[2])
        terminal = Mock()
        terminal.isatty.return_value = True
        with patch.object(sys, "stdin", terminal), patch.object(credentials.getpass, "getpass", return_value="synthetic-hidden"), redirect_stdout(io.StringIO()):
            self.assertEqual(credentials.main(["import", "--name", "github-token"]), 0)
        self.store.set.assert_called_once_with("github-token", "synthetic-hidden")

    def test_getpass_echo_failure_is_an_error_before_visible_input(self):
        terminal = Mock()
        terminal.isatty.return_value = True
        def unsafe_prompt(_):
            warnings.warn("synthetic echo failure", credentials.getpass.GetPassWarning)
            self.fail("Visible credential entry must never be reached")
        with patch.object(sys, "stdin", terminal), patch.object(credentials.getpass, "getpass", side_effect=unsafe_prompt):
            with self.assertRaisesRegex(credentials.CredentialError, "Unable to disable terminal echo"):
                credentials._read_import("github-token", None)
        self.store.set.assert_not_called()

    def test_ci_import_fails_before_reading_a_source_or_store(self):
        with patch.dict(os.environ, {"CI": "true"}), patch.object(credentials, "_read_import") as read:
            result = self.run_cli(["import", "--name", "github-token", "--file", "-"])
        self.assertEqual(result[0], 1)
        read.assert_not_called()
        self.store.set.assert_not_called()

    def test_help_is_portable_and_invalid_arguments_do_not_echo_secret(self):
        for args, expected_status in ((["--help"], 0), (["import", "--help"], 0),
                                      (["import", "--name", "synthetic-accidental-secret"], 2)):
            output = io.StringIO()
            with redirect_stdout(output), redirect_stderr(output):
                with self.assertRaises(SystemExit) as result:
                    credentials.main(args)
            self.assertEqual(result.exception.code, expected_status)
            self.assertNotIn("synthetic-accidental-secret", output.getvalue())
        self.native_factory.assert_not_called()
        self.store.set.assert_not_called()


class NativePolicyTests(unittest.TestCase):
    def test_no_ui_scope_restores_previous_setting_after_success_and_failure(self):
        for initially_allowed in (0, 1):
            for fail in (False, True):
                api = credentials._NativeSecurity.__new__(credentials._NativeSecurity)
                api.sec = Mock()
                def read_setting(result):
                    result._obj.value = initially_allowed
                    return 0
                api.sec.SecKeychainGetUserInteractionAllowed.side_effect = read_setting
                api.sec.SecKeychainSetUserInteractionAllowed.return_value = 0
                if fail:
                    with self.assertRaisesRegex(RuntimeError, "synthetic failure"):
                        with api.no_ui():
                            raise RuntimeError("synthetic failure")
                else:
                    with api.no_ui():
                        pass
                self.assertEqual(
                    [call.args[0] for call in api.sec.SecKeychainSetUserInteractionAllowed.call_args_list],
                    [False, initially_allowed],
                )

    def test_access_creation_passes_null_trusted_list_and_releases_owned_reference(self):
        api = credentials._NativeSecurity.__new__(credentials._NativeSecurity)
        api.sec, api.cf = Mock(), Mock()
        @contextmanager
        def value(_):
            yield 42
        api._value = value
        def create_access(descriptor, trusted, result):
            self.assertEqual(descriptor, 42)
            self.assertIsNone(trusted)
            result._obj.value = 73
            return 0
        api.sec.SecAccessCreate.side_effect = create_access
        with api.calling_application_access("Synthetic access description") as access:
            self.assertEqual(access, credentials._CFRef(73))
        api.cf.CFRelease.assert_called_once_with(73)

    def test_cf_callbacks_match_public_64_bit_abi(self):
        pointer = ctypes.sizeof(ctypes.c_void_p)
        self.assertEqual(ctypes.sizeof(credentials._ArrayCallbacks), 5 * pointer)
        self.assertEqual(ctypes.sizeof(credentials._DictionaryKeyCallbacks), 6 * pointer)
        self.assertEqual(ctypes.sizeof(credentials._DictionaryValueCallbacks), 5 * pointer)

    def test_import_access_trusts_only_system_codesign_and_releases_references(self):
        api = credentials._NativeSecurity.__new__(credentials._NativeSecurity)
        api.sec, api.cf = Mock(), Mock()
        @contextmanager
        def value(item):
            if isinstance(item, list):
                self.assertEqual(item, [credentials._CFRef(17)])
                yield 22
            else:
                self.assertEqual(item, "Glassy Host release signing identity")
                yield 42
        api._value = value
        def trusted_application(path, result):
            self.assertEqual(path, b"/usr/bin/codesign")
            result._obj.value = 17
            return 0
        def create_access(descriptor, trusted, result):
            self.assertEqual(descriptor, 42)
            self.assertEqual(trusted, 22)
            result._obj.value = 73
            return 0
        api.sec.SecTrustedApplicationCreateFromPath.side_effect = trusted_application
        api.sec.SecAccessCreate.side_effect = create_access
        with api.codesigning_access() as access:
            self.assertEqual(access, credentials._CFRef(73))
        self.assertEqual([call.args[0] for call in api.cf.CFRelease.call_args_list], [73, 17])


if __name__ == "__main__":
    unittest.main()
