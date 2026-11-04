"""Startup regression checks: python3 -m unittest discover -s Tests/NetworkFixtures."""
import http.client
import json
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import unittest


class FixtureStartupTests(unittest.TestCase):
    def test_readiness_does_not_require_reverse_dns(self):
        script = Path(__file__).with_name("web_remote_fixture.py")
        # Fail immediately if any server constructor attempts reverse DNS. The
        # inherited HTTPServer.server_bind used to call this before readiness.
        wrapper = """
import runpy, socket, sys
def forbidden_dns(*args, **kwargs):
    raise AssertionError('fixture startup attempted reverse DNS')
socket.getfqdn = forbidden_dns
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name='__main__')
"""
        for tls in (False, True):
            with self.subTest(tls=tls), tempfile.TemporaryDirectory() as root:
                command = [sys.executable, "-u", "-c", wrapper, str(script), root]
                if tls:
                    command.append("tls")
                process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                try:
                    ready = Path(root) / "ports.json"
                    deadline = time.monotonic() + 10
                    while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                        time.sleep(0.02)
                    if not ready.exists():
                        process.terminate()
                        _, diagnostics = process.communicate(timeout=3)
                        self.fail("Fixture failed readiness: " + diagnostics.decode())
                    ports = json.loads(ready.read_text())
                    self.assertEqual(set(ports), {"http", "ftp", "https", "ftps"} if tls else {"http", "ftp"})
                    connection = http.client.HTTPConnection("127.0.0.1", ports["http"], timeout=3)
                    try:
                        connection.request("GET", "/")
                        self.assertEqual(connection.getresponse().status, 401)
                    finally:
                        connection.close()
                    with socket.create_connection(("127.0.0.1", ports["ftp"]), timeout=3) as channel:
                        self.assertTrue(channel.recv(1024).startswith(b"220"))
                    if tls:
                        connection = http.client.HTTPSConnection("127.0.0.1", ports["https"], timeout=3)
                        try:
                            with self.assertRaises(ssl.SSLCertVerificationError):
                                connection.request("GET", "/")
                        finally:
                            connection.close()
                        self.assertFalse((Path(root) / "tls-credentials-sent").exists())
                finally:
                    if process.poll() is None:
                        process.terminate()
                    process.communicate(timeout=3)


if __name__ == "__main__":
    unittest.main()
