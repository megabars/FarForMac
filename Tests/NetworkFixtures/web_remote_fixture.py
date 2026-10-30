"""Loopback-only FTP + DAV conformance fixture, no third-party dependencies."""
import base64
import http.server
import json
import os
import socket
import socketserver
import ssl
import subprocess
import sys
import threading
import time
import urllib.parse
import xml.sax.saxutils

root = sys.argv[1]
files = {"/hello space.txt": b"hello remote world"}
files.update({"/root.txt": b"Loopback FTP and WebDAV test file.\n", "/Тестовая папка/Привет.txt": "Привет из локальной тестовой папки.\n".encode()})
files.update({"/interrupted": b"A" * 131072, "/ignore-range": b"hello remote world", "/wrong-response-etag": b"hello remote world"})
etags = {path: '"v1"' for path in files}
request_events = []
directories = {"/", "/Тестовая папка"}
lock = threading.Lock()
expected_auth = "Basic " + base64.b64encode(b"tester:memory-only-secret").decode()

class DAV(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *_): pass
    def reply(self, status, body=b"", **headers):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        for key, value in headers.items(): self.send_header(key.replace("_", "-"), value)
        self.end_headers()
        if body: self.wfile.write(body)
    def path_value(self): return urllib.parse.unquote(urllib.parse.urlsplit(self.path).path).rstrip("/") or "/"
    def authorized(self):
        if self.headers.get("Authorization") != expected_auth:
            self.reply(401); return False
        return True
    def do_PROPFIND(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if not self.authorized(): return
        path = self.path_value()
        if path not in files and path not in directories: return self.reply(404)
        paths = [path]
        if self.headers.get("Depth") == "1":
            paths += [p for p in list(files) + list(directories) if p != path and (p.rsplit("/", 1)[0] or "/") == path]
        body = '<d:multistatus xmlns:d="DAV:">'
        for p in paths:
            href = xml.sax.saxutils.escape(urllib.parse.quote(p))
            kind = "<d:collection/>" if p in directories else ""
            tag = xml.sax.saxutils.escape(etags.get(p, '"v1"'))
            body += f'<d:response><d:href>{href}</d:href><d:propstat><d:prop><d:resourcetype>{kind}</d:resourcetype><d:getcontentlength>{len(files.get(p, b""))}</d:getcontentlength><d:getetag>{tag}</d:getetag><d:getlastmodified>Wed, 21 Oct 2015 07:28:00 GMT</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>'
        self.reply(207, (body + "</d:multistatus>").encode(), Content_Type="application/xml")
    def do_GET(self):
        if not self.authorized(): return
        p = self.path_value()
        if os.environ.get("FAR_WEB_FIXTURE_EXPORT_STATE") == "1":
            request_events.append({"method": "GET", "path": p, "range": self.headers.get("Range"), "time": time.time()})
            del request_events[:-1000]
        if p == "/redirect": return self.reply(302, Location="/leak")
        if p == "/leak":
            open(os.path.join(root, "credential-leak"), "w").write(self.headers.get("Authorization", ""))
            return self.reply(200, b"leaked")
        if p == "/slow": time.sleep(3); return self.reply(200, b"slow")
        if p not in files: return self.reply(404)
        if self.headers.get("If-Match") and self.headers["If-Match"] != etags.get(p): return self.reply(412)
        data = files[p]
        tag = '"wrong"' if p == "/wrong-response-etag" else etags.get(p, '"v1"')
        if self.headers.get("Range"):
            start = int(self.headers["Range"].split("=")[1].split("-")[0])
            if p == "/ignore-range": return self.reply(200, data, ETag=tag)
            return self.reply(206, data[start:], Content_Range=f"bytes {start}-{len(data)-1}/{len(data)}", ETag=tag)
        if p == "/interrupted":
            self.send_response(200); self.send_header("Content-Length", str(len(data))); self.send_header("ETag", tag); self.end_headers()
            self.wfile.write(data[:65536]); self.wfile.flush()
            # Allow the streaming client to receive a complete chunk before the
            # connection closes short of the advertised representation length.
            time.sleep(0.2); self.close_connection = True
            return
        self.reply(200, data, ETag=tag)
    def do_PUT(self):
        data = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if not self.authorized(): return
        p = self.path_value()
        if self.headers.get("If-Match") and self.headers["If-Match"] != etags.get(p): return self.reply(412)
        files[p] = data; etags[p] = '"v2"'; self.reply(201)
    def do_MOVE(self):
        if not self.authorized(): return
        src = self.path_value(); dest = urllib.parse.unquote(urllib.parse.urlsplit(self.headers["Destination"]).path)
        if src not in files: return self.reply(404)
        if dest in files and self.headers.get("Overwrite") == "F": return self.reply(412)
        files[dest] = files.pop(src); etags[dest] = etags.pop(src, '"v1"'); self.reply(201)
    def do_DELETE(self):
        if not self.authorized(): return
        p = self.path_value()
        if p == "/partial": return self.reply(207, b'<d:multistatus xmlns:d="DAV:"/>')
        if p in files: del files[p]
        elif p in directories: directories.remove(p)
        else: return self.reply(404)
        self.reply(204)
    def do_MKCOL(self):
        if not self.authorized(): return
        p = self.path_value()
        if p in files or p in directories: return self.reply(405)
        directories.add(p); self.reply(201)

class FTP(socketserver.StreamRequestHandler):
    def send(self, message): self.wfile.write((message + "\r\n").encode()); self.wfile.flush()
    def handle(self):
        self.connection.settimeout(5)
        self.send("220 loopback test FTP")
        cwd = "/"; restart = 0; passive = None; source = None
        def normalize(value):
            # FTP paths are rooted at a single slash; POSIX normpath deliberately
            # preserves a leading //, which has no special meaning in this fixture.
            return "/" + os.path.normpath(value if value.startswith("/") else cwd + "/" + value).lstrip("/")
        while True:
            line = self.rfile.readline().decode().rstrip("\r\n")
            if not line: return
            command, _, arg = line.partition(" "); command = command.upper()
            if command == "USER": self.send("331 Password required")
            elif command == "PASS": self.send("230 Logged in" if arg == "memory-only-secret" else "530 Bad password")
            elif command == "PWD": self.send(f'257 "{cwd}"')
            elif command == "CWD":
                target = normalize(arg)
                if target in directories: cwd = target; self.send("250 Directory changed")
                else: self.send("550 Missing directory")
            elif command in ("TYPE", "OPTS"): self.send("200 OK")
            elif command in ("EPSV", "PASV"):
                passive = socket.socket(); passive.bind(("127.0.0.1", 0)); passive.listen(); passive.settimeout(5)
                port = passive.getsockname()[1]
                self.send(f"229 Entering Extended Passive Mode (|||{port}|)" if command == "EPSV" else f"227 Entering Passive Mode (127,0,0,1,{port//256},{port%256})")
            elif command == "REST": restart = int(arg); self.send("350 Restart accepted")
            elif command in ("SIZE", "MDTM"):
                target = normalize(arg)
                self.send(("213 " + (str(len(files[target])) if command == "SIZE" else "20261030123456")) if target in files else "550 Missing")
            elif command in ("MLSD", "RETR", "STOR"):
                target = normalize(arg) if arg else cwd
                if command == "MLSD" and target == "/unsupported": self.send("502 MLSD unavailable"); continue
                if command == "RETR" and target not in files: self.send("550 Missing"); continue
                self.send("150 Opening data")
                data_socket, _ = passive.accept()
                if command == "MLSD":
                    listing = b""
                    for path in list(files) + list(directories):
                        if path != target and (path.rsplit("/", 1)[0] or "/") == target:
                            kind = "dir" if path in directories else "file"
                            listing += f"type={kind};size={len(files.get(path,b''))};modify=20261030123456; {path.rsplit('/',1)[1]}\r\n".encode()
                    data_socket.sendall(listing)
                elif command == "RETR": data_socket.sendall(files[target][restart:]); restart = 0
                else:
                    data = b""
                    while True:
                        chunk = data_socket.recv(65536)
                        if not chunk: break
                        data += chunk
                    files[target] = data
                data_socket.close(); passive.close(); self.send("226 Complete")
            elif command == "RNFR": source = normalize(arg); self.send("350 Rename destination required")
            elif command == "RNTO": files[normalize(arg)] = files.pop(source); self.send("250 Renamed")
            elif command == "DELE":
                p = normalize(arg)
                if p in files: del files[p]; self.send("250 Deleted")
                else: self.send("550 Missing")
            elif command == "MKD": directories.add(normalize(arg)); self.send("257 Created")
            elif command == "RMD": directories.remove(normalize(arg)); self.send("250 Removed")
            elif command == "QUIT": self.send("221 Bye"); return
            else: self.send("502 Unsupported")

httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), DAV)
ftpd = socketserver.ThreadingTCPServer(("127.0.0.1", 0), FTP)
directories.add("/unsupported")
threading.Thread(target=httpd.serve_forever, daemon=True).start()
threading.Thread(target=ftpd.serve_forever, daemon=True).start()
ports = {"http": httpd.server_port, "ftp": ftpd.server_address[1]}
if os.environ.get("FAR_WEB_FIXTURE_EXPORT_STATE") == "1":
    def export_state():
        while True:
            try:
                snapshot = {"directories": sorted(list(directories)), "files": {p: {"size": len(data), "base64": base64.b64encode(data).decode()} for p, data in list(files.items())}, "requests": list(request_events)}
                temporary = os.path.join(root, "state.json.tmp")
                with open(temporary, "w") as output: json.dump(snapshot, output, ensure_ascii=False)
                os.replace(temporary, os.path.join(root, "state.json"))
            except (OSError, RuntimeError): pass
            time.sleep(0.2)
    threading.Thread(target=export_state, daemon=True).start()
if len(sys.argv) > 2 and sys.argv[2] == "tls":
    key = os.path.join(root, "key.pem"); cert = os.path.join(root, "cert.pem")
    subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-subj", "/CN=localhost", "-days", "1"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(cert, key)
    httpsd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), DAV)
    httpsd.socket = context.wrap_socket(httpsd.socket, server_side=True)
    class AuthTLS(socketserver.StreamRequestHandler):
        def handle(self):
            self.connection.settimeout(3)
            self.wfile.write(b"220 TLS certificate test\r\n"); self.wfile.flush()
            command = self.rfile.readline()
            if command.upper().startswith(b"AUTH TLS"):
                self.wfile.write(b"234 Start TLS\r\n"); self.wfile.flush()
                try:
                    channel = context.wrap_socket(self.connection, server_side=True)
                    if channel.recv(4096):
                        open(os.path.join(root, "tls-credentials-sent"), "w").write("unexpected credentials after untrusted certificate")
                    channel.close()
                except ssl.SSLError: pass
    tlsftpd = socketserver.ThreadingTCPServer(("127.0.0.1", 0), AuthTLS)
    threading.Thread(target=httpsd.serve_forever, daemon=True).start()
    threading.Thread(target=tlsftpd.serve_forever, daemon=True).start()
    ports.update({"https": httpsd.server_port, "ftps": tlsftpd.server_address[1]})
with open(os.path.join(root, "ports.json"), "w") as f: json.dump(ports, f)
threading.Event().wait()
