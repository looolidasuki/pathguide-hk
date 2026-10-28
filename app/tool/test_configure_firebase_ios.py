import plistlib
import tempfile
import unittest
from pathlib import Path
from configure_firebase_ios import generate

class ClientConfigurationTest(unittest.TestCase):
    def test_generates_only_public_client_files_and_validates_bundle(self):
        values = dict(API_KEY='public-example-key', PROJECT_ID='demo-pathguide', GOOGLE_APP_ID='1:123:ios:example',
                      GCM_SENDER_ID='123', CLIENT_ID='example.apps.googleusercontent.com',
                      REVERSED_CLIENT_ID='com.googleusercontent.apps.example', BUNDLE_ID='hk.pathguide.pathguide')
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root/'ios/Flutter').mkdir(parents=True)
            source = root/'GoogleService-Info.plist'
            source.write_bytes(plistlib.dumps(values))
            generate(source, root)
            self.assertTrue((root/'config/firebase.local.json').exists())
            self.assertIn('com.googleusercontent.apps.example', (root/'ios/Flutter/Firebase.local.xcconfig').read_text())
            with self.assertRaises(ValueError):
                generate(source, root, bundle_id='another.app')
            values['REVERSED_CLIENT_ID'] = 'bad\nINJECTED_SETTING=true'
            source.write_bytes(plistlib.dumps(values))
            with self.assertRaises(ValueError):
                generate(source, root)

if __name__ == '__main__':
    unittest.main()
