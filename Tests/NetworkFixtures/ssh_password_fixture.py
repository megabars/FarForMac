#!/usr/bin/env python3
"""Unprivileged loopback SSH/SFTP fixture. Requires test-only paramiko==4.0.0.

The password is received on stdin, never in command arguments. Files are confined
beneath an ephemeral root; no macOS accounts or sshd settings are touched.
"""
import json
import os
from pathlib import Path
import socket
import sys
import threading
import time

import paramiko

root = Path(sys.argv[1]).resolve()
delay = float(sys.argv[2])
password = sys.stdin.readline().rstrip("\n")
key = paramiko.RSAKey.generate(2048)
count_lock = threading.Lock()
count = 0


class Server(paramiko.ServerInterface):
    def get_allowed_auths(self, username):
        return "password"

    def check_auth_password(self, username, supplied):
        global count
        with count_lock:
            count += 1
            (root / "auth-count").write_text(str(count))
        time.sleep(delay)
        return paramiko.AUTH_SUCCESSFUL if username == "fixture" and supplied == password else paramiko.AUTH_FAILED

    def check_channel_request(self, kind, chanid):
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED


class FileHandle(paramiko.SFTPHandle):
    def stat(self):
        return paramiko.SFTPAttributes.from_stat(os.fstat(self.readfile.fileno()))


class Files(paramiko.SFTPServerInterface):
    def local(self, path):
        result = (root / path.lstrip("/")).resolve()
        if not result.is_relative_to(root):
            raise PermissionError("outside fixture root")
        return result

    def list_folder(self, path):
        try:
            result = []
            for p in self.local(path).iterdir():
                a = paramiko.SFTPAttributes.from_stat(p.lstat())
                a.filename = p.name
                result.append(a)
            return result
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)

    def stat(self, path):
        try:
            return paramiko.SFTPAttributes.from_stat(self.local(path).stat())
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)

    def lstat(self, path):
        try:
            return paramiko.SFTPAttributes.from_stat(self.local(path).lstat())
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)

    def mkdir(self, path, attr):
        try:
            self.local(path).mkdir(mode=0o700)
            return paramiko.SFTP_OK
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)

    def rmdir(self, path):
        try:
            self.local(path).rmdir()
            return paramiko.SFTP_OK
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)

    def open(self, path, flags, attr):
        try:
            fd = os.open(self.local(path), flags, 0o600)
            handle = FileHandle(flags)
            # Separate handles support both positioned reads and writes.
            mode = "r+b" if flags & os.O_RDWR else "wb" if flags & os.O_WRONLY else "rb"
            stream = os.fdopen(fd, mode)
            handle.readfile = stream
            handle.writefile = stream
            return handle
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)

    def rename(self, oldpath, newpath):
        try:
            self.local(oldpath).rename(self.local(newpath))
            return paramiko.SFTP_OK
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)

    posix_rename = rename

    def remove(self, path):
        try:
            self.local(path).unlink()
            return paramiko.SFTP_OK
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)


def serve(client):
    transport = paramiko.Transport(client)
    try:
        transport.add_server_key(key)
        transport.set_subsystem_handler("sftp", paramiko.SFTPServer, Files)
        transport.start_server(server=Server())
        while transport.is_active():
            time.sleep(0.02)
    except (EOFError, OSError, paramiko.SSHException):
        pass
    finally:
        transport.close()


listener = socket.socket()
listener.bind(("127.0.0.1", 0))
listener.listen(16)
(root / "auth-count").write_text("0")
print(json.dumps({"port": listener.getsockname()[1], "keyType": key.get_name(), "publicKey": key.get_base64()}), flush=True)
while True:
    client, _ = listener.accept()
    threading.Thread(target=serve, args=(client,), daemon=True).start()
