import contextlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import qwen_vl_trial as trial

BASE = 'https://example-workspace.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1'


def sse(*events):
    return io.BytesIO(b''.join(b'data: ' + (e if isinstance(e, bytes) else
                     json.dumps(e, ensure_ascii=False).encode()) + b'\n\n' for e in events))


class QwenTrialTests(unittest.TestCase):
    def test_offline_check_never_opens_network_or_echoes_key(self):
        out = io.StringIO()
        with patch.dict(os.environ, {'DASHSCOPE_API_KEY': 'dummy-sensitive-key',
                                     'QWEN_VL_BASE_URL': BASE}), \
                patch('urllib.request.build_opener', side_effect=AssertionError('network')), \
                contextlib.redirect_stdout(out):
            self.assertEqual(trial.main([]), 0)
        result = json.loads(out.getvalue())
        self.assertEqual(result['network_requests'], 0)
        self.assertTrue(result['api_key_configured'])
        self.assertNotIn('dummy-sensitive-key', out.getvalue())

    def test_one_image_payload_and_credentials_in_header_only(self):
        req = trial.request_for(BASE, 'dummy-key', b'photo', 'image/jpeg', 'qwen3-vl-plus')
        data = json.loads(req.data)
        self.assertNotIn('dummy-key', req.data.decode())
        self.assertEqual(data['messages'][0]['content'][0]['image_url']['url'],
                         'data:image/jpeg;base64,cGhvdG8=')
        self.assertEqual(data['max_tokens'], 256)
        self.assertFalse(data['enable_thinking'])
        self.assertTrue(data['stream'])

    def test_untrusted_or_credential_bearing_endpoint_rejected(self):
        for url in ['http://host.maas.aliyuncs.com/compatible-mode/v1',
                    'https://maas.aliyuncs.com.evil.test/compatible-mode/v1',
                    'https://ap-southeast-1.maas.qwencloudapi.com.evil.test/compatible-mode/v1',
                    'https://token-plan.maas.qwencloudapi.com/compatible-mode/v1',
                    'https://user:secret@host.maas.aliyuncs.com/compatible-mode/v1',
                    BASE + '?key=secret']:
            with self.subTest(url=url), self.assertRaises(trial.TrialError):
                trial.endpoint(url)

    def test_documented_qwencloud_regional_endpoint_needs_no_workspace(self):
        base = 'https://ap-southeast-1.maas.qwencloudapi.com/compatible-mode/v1'
        self.assertEqual(trial.endpoint(base), base + '/chat/completions')
        req = trial.request_for(base, 'dummy-key', b'photo', 'image/jpeg', 'qwen3-vl-plus')
        self.assertEqual(req.full_url, base + '/chat/completions')

    def test_subscription_key_is_not_sent_to_payg_endpoint(self):
        with self.assertRaises(trial.TrialError):
            trial.request_for(BASE, 'sk-sp-dummy', b'photo', 'image/jpeg', 'qwen3-vl-plus')

    def test_redirect_not_followed(self):
        with self.assertRaises(trial.TrialError):
            trial.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://elsewhere.test')

    def test_streamed_unicode_description_and_usage(self):
        stream = sse({'choices': [{'delta': {'content': '牆上有帽。'}}]},
                     {'choices': [{'delta': {}, 'finish_reason': 'stop'}]},
                     {'choices': [], 'usage': {'total_tokens': 42}}, b'[DONE]')
        chunks = []
        result = trial.read_stream(stream, chunks.append)
        self.assertEqual(''.join(chunks), '牆上有帽。')
        self.assertEqual(result['usage']['total_tokens'], 42)
        self.assertGreaterEqual(result['first_text_seconds'], 0)

    def test_truncated_error_and_empty_streams_never_succeed(self):
        streams = [sse({'choices': [{'delta': {'content': 'partial'}}]}),
                   sse({'error': {'message': 'not logged'}}),
                   sse({'choices': [{'delta': {}, 'finish_reason': 'length'}]}),
                   sse(b'[DONE]'), sse(b'not-json')]
        for stream in streams:
            with self.subTest(stream=stream), self.assertRaises(trial.TrialError):
                trial.read_stream(stream, lambda _: None)

    def test_image_type_and_size_bound_before_network(self):
        with tempfile.TemporaryDirectory() as directory:
            p = Path(directory) / 'chosen.jpg'
            p.write_bytes(b'not an image')
            with self.assertRaises(trial.TrialError):
                trial.load_image(p)
            p.write_bytes(b'\xff\xd8\xff' + bytes(trial.MAX_IMAGE))
            with self.assertRaises(trial.TrialError):
                trial.load_image(p)

    def test_send_requires_explicit_image(self):
        with patch('urllib.request.build_opener', side_effect=AssertionError('network')), \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(trial.main(['--send-image']), 1)


if __name__ == '__main__':
    unittest.main()
