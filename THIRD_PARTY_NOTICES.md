# Third-party notices

FarForMac's own code is licensed separately under the proprietary evaluation
terms in LICENSE. Those terms do not replace or restrict the licenses below.

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

## Far Manager — search and preserve-style adaptations

The preserve-style algorithm in `Sources/FarCore/EditorSearchStyle.swift`, the
Unicode search normalization in `Sources/FarCore/SearchTextFolding.swift`, and
related FAR golden cases in `Tests/FarCoreTests/EditorEditingTests.swift` and
`Tests/FarCoreTests/SearchTextFoldingTests.swift` are adapted from Far Manager:

- `far/preservestyle.cpp` (Copyright © 2013 Far Group)
- `far/string_utils.cpp` (Copyright © 2017 Far Group)
- Source revision: https://github.com/FarGroup/FarManager/tree/1a6b02544b339615232078e0551463ef15b73ff9

These adaptations remain subject to the following BSD terms; the proprietary
license for independently written FarForMac code does not override them.

Copyright © 2013, 2017 Far Group
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.
3. The name of the authors may not be used to endorse or promote products
   derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## Embedded Lua, LPeg and MoonScript

- Lua 5.4.9, from https://github.com/lua/lua/tree/v5.4.9, in
  `Sources/CFarLua/Vendor/lua`. The host adds deadline checks to native Lua
  pattern matching and disables Lua table finalizers.
- LPeg 1.1.0, from https://github.com/roberto-ieru/LPeg/tree/v1.1.0, in
  `Sources/CFarLua/Vendor/lpeg`. The host adds a deadline check to the
  pattern VM and uses an LPeg-specific debug macro.
- MoonScript 0.7.0 compiler modules, from the pinned Far Manager bundle
  https://github.com/FarGroup/FarManager/blob/1a6b02544b339615232078e0551463ef15b73ff9/plugins/luamacro/moonscript.lua,
  are stored as C string literals in `Sources/CFarLua/Vendor/moonscript`.
  The build includes the compiler modules and omits the command-line tools.
  Upstream license: https://github.com/leafo/moonscript/blob/v0.7.0/README.md#license-mit.

Copyright (C) 1994-2026 Lua.org, PUC-Rio.
Copyright (C) 2007-2023 Lua.org, PUC-Rio.
Copyright (C) 2025 by Leaf Corcoran.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to
do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Far Manager LuaMacro test fixtures

`Panel.SpaceToSelect.lua` and `Editor.ColorWord.moon` in
`Tests/FarCoreTests/Fixtures/FarLua` come from
https://github.com/FarGroup/FarManager/tree/1a6b02544b339615232078e0551463ef15b73ff9/extra/Addons/Macros.

BSD 3-Clause License

Copyright (c) 1996, Eugene Roshal
Copyright (c) 2000, Far Group
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

* Neither the name of the copyright holder nor the names of its
  contributors may be used to endorse or promote products derived from
  this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
