"""Local stand-in for FCM, Google OAuth and APNs, for worker tests only.

Never contacts a real service. It answers according to the token string, so
tests can provoke each provider outcome, and appends every request it receives
to a JSON-lines log file:

  token contains UNREG      -> the token is unregistered (FCM 404 / APNs 410)
  token contains BADTOKEN   -> the token itself is malformed (FCM 400 naming the
                               token field / APNs 400 BadDeviceToken)
  token contains BADPAYLOAD -> a 400 about the message, not the token
  token contains DOWN       -> 503 every time
  token contains FLAKY      -> 503 the first time, then success
  token contains SLOW       -> success after a delay (to overlap workers)
  anything else             -> success

Usage: python push_provider_mock.py <port> <log_file>
"""
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
LOG = sys.argv[2]
seen = {}
lock = threading.Lock()


def log(entry):
    with lock, open(LOG, 'a', encoding='utf-8') as f:
        f.write(json.dumps(entry) + '\n')


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # keep test output quiet
        pass

    def _reply(self, status, body=None):
        data = json.dumps(body if body is not None else {}).encode()
        self.send_response(status)
        self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _outcome(self, token):
        if 'SLOW' in token:
            time.sleep(1.5)
        if 'FLAKY' in token:
            with lock:
                seen[token] = seen.get(token, 0) + 1
                first = seen[token] == 1
            if first:
                return 503
        if 'DOWN' in token:
            return 503
        if 'UNREG' in token:
            return 'unreg'
        if 'BADTOKEN' in token:
            return 'badtoken'
        if 'BADPAYLOAD' in token:
            return 'badpayload'
        return 200

    def do_POST(self):
        length = int(self.headers.get('content-length') or 0)
        raw = self.rfile.read(length).decode() if length else ''
        path = self.path
        if path == '/token':
            return self._reply(200, {'access_token': 'mock-access-token'})
        if '/messages:send' in path:
            body = json.loads(raw or '{}')
            token = body.get('message', {}).get('token', '')
            log({'provider': 'fcm', 'token': token, 'body': body})
            result = self._outcome(token)
            if result == 200:
                return self._reply(200, {'name': 'projects/x/messages/1'})
            if result == 'unreg':
                return self._reply(404, {'error': {'status': 'NOT_FOUND', 'details': [
                    {'errorCode': 'UNREGISTERED'}]}})
            if result == 'badtoken':
                return self._reply(400, {'error': {'status': 'INVALID_ARGUMENT', 'details': [
                    {'fieldViolations': [{'field': 'message.token'}]}]}})
            if result == 'badpayload':
                return self._reply(400, {'error': {'status': 'INVALID_ARGUMENT', 'details': [
                    {'fieldViolations': [{'field': 'message.data'}]}]}})
            return self._reply(int(result), {'error': {'status': 'UNAVAILABLE'}})
        if path.startswith('/3/device/'):
            token = path.rsplit('/', 1)[1]
            body = json.loads(raw or '{}')
            log({'provider': 'apns', 'token': token, 'body': body})
            result = self._outcome(token)
            if result == 200:
                return self._reply(200, {})
            if result == 'unreg':
                return self._reply(410, {'reason': 'Unregistered'})
            if result == 'badtoken':
                return self._reply(400, {'reason': 'BadDeviceToken'})
            if result == 'badpayload':
                return self._reply(400, {'reason': 'PayloadEmpty'})
            return self._reply(int(result), {'reason': 'ServiceUnavailable'})
        return self._reply(404, {})


if __name__ == '__main__':
    ThreadingHTTPServer(('0.0.0.0', PORT), Handler).serve_forever()
