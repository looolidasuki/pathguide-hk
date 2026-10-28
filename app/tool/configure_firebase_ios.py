#!/usr/bin/env python3
"""Generate ignored mobile client configuration from Firebase's public plist.
Never accepts or loads a service-account key. Does not deploy or enable billing.
"""
import argparse
import json
import plistlib
import re
from pathlib import Path


def generate(source: Path, app: Path, web_client_id: str = '', bundle_id: str = 'hk.pathguide.pathguide'):
    with source.open('rb') as stream:
        values = plistlib.load(stream)
    required = ['API_KEY', 'PROJECT_ID', 'GOOGLE_APP_ID', 'GCM_SENDER_ID', 'CLIENT_ID', 'REVERSED_CLIENT_ID', 'BUNDLE_ID']
    if any(not isinstance(values.get(key), str) or not values[key] for key in required):
        raise ValueError('Incomplete GoogleService-Info.plist; enable Google provider and download it again.')
    if values['BUNDLE_ID'] != bundle_id:
        raise ValueError('Bundle ID does not match this app; register the matching iOS app in Firebase.')
    if not re.fullmatch(r'[A-Za-z0-9.\-]+', values['REVERSED_CLIENT_ID']):
        raise ValueError('Invalid reversed client ID.')
    output = {
        'FIREBASE_ENABLED': 'true',
        'FIREBASE_PROJECT_ID': values['PROJECT_ID'], 'FIREBASE_API_KEY': values['API_KEY'],
        'FIREBASE_APP_ID': values['GOOGLE_APP_ID'], 'FIREBASE_MESSAGING_SENDER_ID': values['GCM_SENDER_ID'],
        'FIREBASE_IOS_BUNDLE_ID': bundle_id,
        'GOOGLE_IOS_CLIENT_ID': values['CLIENT_ID'], 'GOOGLE_WEB_CLIENT_ID': web_client_id,
    }
    (app / 'config').mkdir(exist_ok=True)
    (app / 'config/firebase.local.json').write_text(json.dumps(output, indent=2) + '\n')
    (app / 'ios/Flutter/Firebase.local.xcconfig').write_text(
        'PATHGUIDE_GOOGLE_REVERSED_CLIENT_ID=' + values['REVERSED_CLIENT_ID'] + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('plist', type=Path)
    parser.add_argument('--web-client-id', default='')
    parser.add_argument('--bundle-id', default='hk.pathguide.pathguide')
    args = parser.parse_args()
    try:
        generate(args.plist, Path(__file__).resolve().parents[1], args.web_client_id, args.bundle_id)
    except (ValueError, plistlib.InvalidFileException, OSError) as error:
        parser.exit(1, str(error) + '\n')
    print('Created local Firebase client configuration. No cloud resources were changed.')
