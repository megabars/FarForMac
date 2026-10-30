# Third-party notices

## libarchive

The application links to the libarchive library supplied by macOS. The unmodified
public headers `archive.h` and `archive_entry.h` in `Sources/CArchive/include` are
from libarchive 3.7.4:

- https://github.com/libarchive/libarchive/blob/v3.7.4/libarchive/archive.h
- https://github.com/libarchive/libarchive/blob/v3.7.4/libarchive/archive_entry.h

Copyright (c) 2003-2010 Tim Kientzle
Copyright (c) 2016 Martin Matuska
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR(S) ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
IN NO EVENT SHALL THE AUTHOR(S) BE LIABLE FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

The macOS runtime library may include additional components and notices supplied
by Apple. No libarchive implementation code is vendored or redistributed here.

## macOS network components

FTP/FTPS uses the libcurl supplied by macOS through an independently written C
wrapper. SFTP launches the system OpenSSH client and speaks the SFTP wire
protocol; WebDAV uses Foundation URLSession. No libcurl or OpenSSH implementation
is bundled or copied into this repository. Their runtime components and licenses
are supplied by Apple with macOS. Protocol references are listed in
`docs/NETWORK_REFERENCE.md` and `docs/NETWORK_CAPABILITIES.md`.
