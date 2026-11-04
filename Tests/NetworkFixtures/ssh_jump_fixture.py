#!/usr/bin/env python3
"""Isolated two-jump SSH route + SFTP target; all listeners are loopback-only.

Only direct-tcpip to the declared next endpoint is permitted. Synthetic
credentials and authentication modes arrive on stdin, never command arguments.
The default remains a password target behind two ephemeral-key jump servers.
"""
import json
import os
from pathlib import Path
import select
import socket
import sys
import threading
import time

import paramiko

root = Path(sys.argv[1]).resolve()
options = json.loads(sys.stdin.readline())
password = options["password"]
endpoint_options = options.get("endpoints", {})
auth_delay = float(options.get("authDelay", 0))
jump_delay = float(options.get("jumpDelay", 0))
client_key = paramiko.RSAKey.generate(2048)
identity = root / "client key"
client_key.write_private_key_file(str(identity))
os.chmod(identity, 0o600)
lock = threading.Lock()
stats = {name: {field: 0 for field in ("password", "publickey", "interactive", "response", "accepted", "rejected", "active", "forward", "rename")} for name in ("target", "jump1", "jump2")}


def record(name, field, delta=1):
    with lock:
        stats[name][field] += delta
        tmp = root / "stats.tmp"
        tmp.write_text(json.dumps(stats))
        tmp.replace(root / "stats.json")


class Auth(paramiko.ServerInterface):
    def __init__(self, name, destination=None):
        self.name = name
        self.destination = destination
        self.targets = {}
        self.options = endpoint_options.get(name, {})
        self.mode = self.options.get("mode", "password" if name == "target" else "publickey")
        self.password = self.options.get("password", password)
        self.otp = self.options.get("otp", "123456")
        self.confirmation = self.options.get("confirmation", "654321")
        self.round = 0
        self.key_offered = False

    def get_allowed_auths(self, username):
        if self.mode == "keyOTP":
            return "keyboard-interactive" if self.key_offered else "publickey"
        return {"publickey": "publickey", "password": "password"}.get(self.mode, "keyboard-interactive")

    def result(self, accepted):
        record(self.name, "accepted" if accepted else "rejected")
        return paramiko.AUTH_SUCCESSFUL if accepted else paramiko.AUTH_FAILED

    def check_auth_password(self, username, supplied):
        record(self.name, "password")
        time.sleep(auth_delay if self.name == "target" else jump_delay)
        return self.result(self.mode == "password" and username == "fixture" and supplied == self.password)

    def check_auth_publickey(self, username, supplied):
        record(self.name, "publickey")
        time.sleep(jump_delay)
        if self.mode not in ("publickey", "keyOTP") or username != "fixture" or supplied != client_key:
            return self.result(False)
        if self.mode == "keyOTP":
            self.key_offered = True
            return paramiko.AUTH_PARTIALLY_SUCCESSFUL
        return self.result(True)

    def check_auth_interactive(self, username, submethods):
        record(self.name, "interactive")
        if username != "fixture" or self.mode not in ("interactive", "keyOTP", "endless"):
            return self.result(False)
        if self.mode == "keyOTP" and not self.key_offered:
            return self.result(False)
        self.round = 0
        prompt = "Verification code:" if self.mode == "keyOTP" else "Password:" if self.mode == "interactive" else "Repeat code:"
        return paramiko.InteractiveQuery("Fixture MFA", "Synthetic fixture credentials only", (prompt, False))

    def check_auth_interactive_response(self, responses):
        record(self.name, "response")
        if self.mode == "endless":
            self.round += 1
            return paramiko.InteractiveQuery("Fixture MFA", "", ("Repeat code:", False))
        if self.mode == "keyOTP":
            return self.result(responses == [self.otp])
        if self.round == 0:
            if responses != [self.password]:
                return self.result(False)
            self.round = 1
            return paramiko.InteractiveQuery("Fixture MFA", "Two independent codes", ("Verification code:", False), ("Confirmation code:", False))
        return self.result(responses == [self.otp, self.confirmation])

    def check_channel_request(self, kind, chanid):
        return paramiko.OPEN_SUCCEEDED if self.name == "target" and kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_direct_tcpip_request(self, chanid, origin, destination):
        if self.destination is None or destination != self.destination[:2]:
            return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
        self.targets[chanid] = ("127.0.0.1", self.destination[2])
        record(self.name, "forward")
        return paramiko.OPEN_SUCCEEDED


class FileHandle(paramiko.SFTPHandle):
    def stat(self):
        return paramiko.SFTPAttributes.from_stat(os.fstat(self.readfile.fileno()))


class Files(paramiko.SFTPServerInterface):
    def __init__(self, server, *args, **kwargs):
        super().__init__(server, *args, **kwargs)
        self.server = server

    def local(self, path):
        base = root / "files"
        result = (base / path.lstrip("/")).resolve()
        if not result.is_relative_to(base):
            raise OSError(13, "outside fixture root")
        return result

    def list_folder(self, path):
        try:
            result = []
            for p in self.local(path).iterdir():
                attr = paramiko.SFTPAttributes.from_stat(p.lstat())
                attr.filename = p.name
                result.append(attr)
            return result
        except OSError as exc:
            return paramiko.SFTPServer.convert_errno(exc.errno)

    def stat(self, path):
        delay = root / "request-delay"
        if delay.exists():
            time.sleep(float(delay.read_text()))
        try:
            return paramiko.SFTPAttributes.from_stat(self.local(path).stat())
        except OSError as exc:
            return paramiko.SFTPServer.convert_errno(exc.errno)

    lstat = stat

    def open(self, path, flags, attr):
        try:
            fd = os.open(self.local(path), flags, 0o600)
            handle = FileHandle(flags)
            stream = os.fdopen(fd, "r+b" if flags & os.O_RDWR else "wb" if flags & os.O_WRONLY else "rb")
            handle.readfile = stream
            handle.writefile = stream
            return handle
        except OSError as exc:
            return paramiko.SFTPServer.convert_errno(exc.errno)

    def rename(self, oldpath, newpath):
        try:
            self.local(oldpath).rename(self.local(newpath))
            record("target", "rename")
            marker = root / "disconnect-after-rename"
            if marker.exists():
                marker.unlink()
                # Publish the mutation but drop its reply: the client must never
                # retry an ambiguous write behind the user's back.
                self.server.transport.close()
            return paramiko.SFTP_OK
        except OSError as exc:
            return paramiko.SFTPServer.convert_errno(exc.errno)

    posix_rename = rename

    def remove(self, path):
        try:
            self.local(path).unlink()
            return paramiko.SFTP_OK
        except OSError as exc:
            return paramiko.SFTPServer.convert_errno(exc.errno)


def forward(channel, destination):
    peer = None
    try:
        peer = socket.create_connection(destination, timeout=3)
        peer.settimeout(None)
        while not channel.closed:
            readable, _, _ = select.select([channel, peer], [], [], 0.1)
            for source in readable:
                data = source.recv(32768)
                if not data:
                    return
                (peer if source is channel else channel).sendall(data)
    except (OSError, EOFError, paramiko.SSHException):
        pass
    finally:
        channel.close()
        if peer is not None:
            peer.close()


def serve(client, name, key, destination):
    record(name, "active")
    transport = paramiko.Transport(client)
    auth = Auth(name, destination)
    auth.transport = transport
    try:
        transport.add_server_key(key)
        if name == "target":
            transport.set_subsystem_handler("sftp", paramiko.SFTPServer, Files)
        transport.start_server(server=auth)
        while transport.is_active():
            if name == "target":
                time.sleep(0.02)
            else:
                channel = transport.accept(timeout=0.1)
                if channel is not None:
                    target = auth.targets.get(channel.chanid)
                    if target is None:
                        channel.close()
                    else:
                        threading.Thread(target=forward, args=(channel, target), daemon=True).start()
    except (EOFError, OSError, paramiko.SSHException):
        pass
    finally:
        transport.close()
        record(name, "active", -1)


def listener(name, destination=None):
    key = paramiko.RSAKey.generate(2048)
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    sock.listen(32)
    def accept():
        while True:
            client, _ = sock.accept()
            threading.Thread(target=serve, args=(client, name, key, destination), daemon=True).start()
    threading.Thread(target=accept, daemon=True).start()
    return {"port": sock.getsockname()[1], "keyType": key.get_name(), "publicKey": key.get_base64()}


(root / "files").mkdir()
(root / "files" / "hello.txt").write_text("Привет через SSH-переходы 🔐")
target = listener("target")
jump2 = listener("jump2", ("target.farmac.invalid", target["port"], target["port"]))
jump1 = listener("jump1", ("jump2.farmac.invalid", jump2["port"], jump2["port"]))
record("target", "active", 0)
print(json.dumps({"target": target, "jump1": jump1, "jump2": jump2, "identity": str(identity)}), flush=True)
while True:
    time.sleep(1)
