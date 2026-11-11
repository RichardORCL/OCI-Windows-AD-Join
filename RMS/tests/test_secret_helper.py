import base64
from contextlib import redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, mock_open, patch

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("read_secret", ROOT / "scripts/read_secret.py")
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class SecretHelperTest(unittest.TestCase):
    def fetch(self, content, content_type="BASE64", use_profile=False):
        bundle = SimpleNamespace(secret_bundle_content=SimpleNamespace(content_type=content_type, content=content))
        client = MagicMock()
        client.get_secret_bundle.return_value.data = bundle
        oci = MagicMock()
        oci.secrets.SecretsClient.return_value = client
        config = json.dumps({"secret_id": "ocid1.vaultsecret.test", "region": "eu-amsterdam-1", "config_from_vault": use_profile})
        output = io.StringIO()
        with patch.dict("sys.modules", {"oci": oci}), patch("builtins.open", mock_open(read_data=config)), redirect_stdout(output):
            helper.main()
        client.get_secret_bundle.assert_called_once_with("ocid1.vaultsecret.test", stage="CURRENT")
        return output.getvalue(), oci

    def test_non_ascii_and_shell_characters_survive_pipe(self):
        credentials = {"username": "CORP\\join-service", "password": "päss'\"$`\\\n密碼"}
        encoded = base64.b64encode(json.dumps(credentials).encode()).decode()
        output, oci = self.fetch(encoded)
        self.assertEqual(json.loads(output), credentials)
        self.assertTrue(output.isascii())
        oci.auth.signers.InstancePrincipalsSecurityTokenSigner.assert_called_once_with(log_requests=False)

    def test_missing_password_rejected(self):
        encoded = base64.b64encode(b'{"username":"join-service"}').decode()
        with self.assertRaises(ValueError):
            self.fetch(encoded)

    def test_unexpected_content_type_rejected(self):
        with self.assertRaises(ValueError):
            self.fetch("sensitive-body", content_type="OTHER")

    def test_malformed_base64_rejected(self):
        with self.assertRaises(ValueError):
            self.fetch("!invalid!")

    def test_optional_vault_profile_is_returned_only_when_requested(self):
        content = {"username": "join-service", "password": "secret", "ad_join": {"domain": "corp.example.com", "override_dns": False}}
        encoded = base64.b64encode(json.dumps(content).encode()).decode()
        output, _ = self.fetch(encoded, use_profile=True)
        self.assertEqual(json.loads(output)["ad_join"], content["ad_join"])
        output, _ = self.fetch(encoded)
        self.assertNotIn("ad_join", json.loads(output))

    def test_requested_vault_profile_must_exist(self):
        encoded = base64.b64encode(b'{"username":"join-service","password":"secret"}').decode()
        with self.assertRaises(ValueError):
            self.fetch(encoded, use_profile=True)


if __name__ == "__main__":
    unittest.main()
