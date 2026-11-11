import importlib.util
from pathlib import Path
import tempfile
import unittest
spec=importlib.util.spec_from_file_location('pair',Path(__file__).resolve().parents[1]/'tools/pair_spotify.py')
pair=importlib.util.module_from_spec(spec);spec.loader.exec_module(pair)
class PairingTests(unittest.TestCase):
 def test_private_bootstrap_idempotent_key_and_backup(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp);state=root/'state';spice=root/'spice'
   pair.prepare(state,spice);key=(state/'pairing.key').read_bytes()
   saved=pair.prepare(state,spice)
   self.assertEqual((state/'pairing.key').read_bytes(),key)
   self.assertEqual((spice/'Extensions/daemon-music-session.js').stat().st_mode&0o777,0o600)
   self.assertTrue((saved/'daemon-music-session.js').is_file())
   self.assertEqual(saved.stat().st_mode&0o777,0o700)
 def test_symlink_extension_refused(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp);(root/'spice').mkdir();(root/'real').mkdir();(root/'spice/Extensions').symlink_to(root/'real',target_is_directory=True)
   with self.assertRaises(ValueError):pair.prepare(root/'state',root/'spice')
if __name__=='__main__':unittest.main()
