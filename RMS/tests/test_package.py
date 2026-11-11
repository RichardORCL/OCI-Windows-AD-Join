import importlib.util
from pathlib import Path
import tempfile
import unittest
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("package_stack", ROOT / "scripts/package_stack.py")
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class PackageTest(unittest.TestCase):
    def test_archive_excludes_local_state_and_variables(self):
        with tempfile.TemporaryDirectory() as directory:
            path = packager.package(Path(directory) / "stack.zip")
            with ZipFile(path) as archive:
                names = archive.namelist()
                self.assertIn("schema.yaml", names)
                self.assertIn("main.tf", names)
                self.assertIn("scripts/read_secret.py", names)
                self.assertFalse(any(name.endswith((".tfstate", ".tfvars", ".tfplan")) for name in names))
                self.assertFalse(any(name.startswith(".terraform/") for name in names))
                self.assertIsNone(archive.testzip())


if __name__ == "__main__":
    unittest.main()
