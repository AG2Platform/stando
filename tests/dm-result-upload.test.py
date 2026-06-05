#!/usr/bin/env python3
"""Tests for `send_dm` REST-multipart upload path in src/dm-result.py.

Phase 5.9 of the OSS→private sync added multipart upload to the
REST-fallback delivery path. Pre-port, dm-result stripped
`[file:|send:|attach:]` markers and logged them as dropped because the
WS-connected bridge was the only path that could actually attach files.
Post-port, dm-result builds the equivalent multipart payload itself so
file delivery survives the bridge being offline.

Five regression guards:

  1. Marker with sendable file → text + file upload, allowlist passes.
  2. Marker with disallowed file → text-only delivered, file rejected
     (logged), no multipart POST issued.
  3. File-only body (text empty, file sendable) → multipart POST with
     empty `content`, no JSON-message POST.
  4. >10 files → batched into chunks of 10 (Discord per-message cap).
  5. Multipart body shape: boundary present, payload_json part
     present, files[N] parts present, filename sanitized.

Test uses a recording fake urllib transport — same shape as
`tests/dm-result-send-dm.test.py` — but extended to handle
multipart/form-data requests (those use `request.data` as bytes,
not JSON, so the existing fake's `json.loads(request.data)` would
choke).
"""

import importlib.util
import json
import os
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

os.environ.setdefault("DISCORD_BOT_TOKEN", "test-token-not-real")

_channels_env = Path.home() / ".claude" / "channels" / "discord" / ".env"
if not _channels_env.exists():
    _channels_env.parent.mkdir(parents=True, exist_ok=True)
    _channels_env.write_text("DISCORD_BOT_TOKEN=test-token-not-real\n")


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


dm = _load("dm_result", REPO / "src" / "dm-result.py")


class _FakeResponse:
    def __init__(self, body_bytes: bytes):
        self._body = body_bytes

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class _FakeTransport:
    """Records every request and replies with canned responses. Unlike
    the JSON-only fake in `dm-result-send-dm.test.py`, this one keeps
    the raw bytes when content-type is multipart so the test can
    introspect the assembled body."""

    def __init__(self, responses):
        self.calls: list[dict] = []
        self._responses = dict(responses)

    def urlopen(self, request, timeout=None):
        method = getattr(request, "method", None) or (
            "POST" if request.data is not None else "GET"
        )
        url = request.full_url
        ct = request.headers.get("Content-type", "") or request.headers.get(
            "Content-Type", ""
        )
        raw = request.data
        body = None
        if raw is not None and ct.startswith("application/json"):
            body = json.loads(raw.decode())
        self.calls.append({
            "method": method,
            "url": url,
            "body": body,
            "raw": raw,
            "content_type": ct,
        })
        for (m, suffix), reply in self._responses.items():
            if m == method and url.endswith(suffix):
                return _FakeResponse(json.dumps(reply).encode())
        raise AssertionError(f"unmocked request: {method} {url}")


def _install_transport(transport):
    dm.urllib.request.urlopen = transport.urlopen


def _restore_transport(original):
    dm.urllib.request.urlopen = original


def _with_access_json(content, fn):
    original = dm.ACCESS_JSON
    tmp = Path(tempfile.mkdtemp(prefix="sutando-dm-upload-test-")) / "access.json"
    tmp.write_text(json.dumps(content))
    dm.ACCESS_JSON = tmp
    try:
        fn()
    finally:
        dm.ACCESS_JSON = original
        tmp.unlink()
        tmp.parent.rmdir()


def _make_sutando_temp_file(name: str = "asset.png", content: bytes = b"PNGDATA") -> str:
    """Materialize a real file under the `/tmp/sutando-` prefix so
    `_is_path_sendable` accepts it. Returns the absolute path.

    Forces `dir="/tmp"` because macOS's default TMPDIR is
    `/var/folders/.../T/`, which doesn't match the allowlist
    prefix — we want this fixture to live under the real allowed
    root regardless of host."""
    fd, path = tempfile.mkstemp(
        prefix="sutando-upload-test-", suffix=f"-{name}", dir="/tmp"
    )
    os.close(fd)
    Path(path).write_bytes(content)
    return path


# -----------------------------------------------------------------------
# 1. Marker with sendable file → text + multipart upload
# -----------------------------------------------------------------------


def test_sendable_file_marker_triggers_multipart_upload():
    """Marker path is real, under allowed prefix → file IS uploaded.
    Pre-port behavior was to silently drop with a stderr log; the
    upload path makes the file deliverable again."""
    fpath = _make_sutando_temp_file()
    try:
        transport = _FakeTransport({
            ("POST", "/users/@me/channels"): {"id": "dm-up-1"},
            ("POST", "/channels/dm-up-1/messages"): {"id": "msg"},
        })
        original = dm.urllib.request.urlopen

        def run():
            _install_transport(transport)
            try:
                ok = dm.send_dm(f"Here's the asset: [file: {fpath}]")
            finally:
                _restore_transport(original)
            assert ok is True
            json_msgs = [c for c in transport.calls if "/messages" in c["url"]
                         and c["content_type"].startswith("application/json")]
            multipart_msgs = [c for c in transport.calls if "/messages" in c["url"]
                              and c["content_type"].startswith("multipart/form-data")]
            assert len(json_msgs) == 1, (
                f"expected exactly one JSON text post; got {len(json_msgs)}"
            )
            assert "Here's the asset:" in json_msgs[0]["body"]["content"]
            assert "[file:" not in json_msgs[0]["body"]["content"]
            assert len(multipart_msgs) == 1, (
                f"expected exactly one multipart upload; got {len(multipart_msgs)}"
            )
            assert os.path.basename(fpath).encode() in multipart_msgs[0]["raw"], (
                "filename missing from multipart body"
            )

        _with_access_json(
            {"allowFrom": ["human"], "tierMap": {"human": "owner"}},
            run,
        )
    finally:
        os.unlink(fpath)


# -----------------------------------------------------------------------
# 2. Disallowed file marker → text-only, no upload
# -----------------------------------------------------------------------


def test_disallowed_file_marker_rejected_without_upload():
    """Marker path doesn't resolve under any allowed root → file is
    rejected by `_is_path_sendable`. Text still posts; NO multipart
    upload happens. Same security gate the WS-bridge enforces."""
    # /etc/hosts: real file, NOT on the allowlist.
    transport = _FakeTransport({
        ("POST", "/users/@me/channels"): {"id": "dm-up-2"},
        ("POST", "/channels/dm-up-2/messages"): {"id": "msg"},
    })
    original = dm.urllib.request.urlopen

    def run():
        _install_transport(transport)
        try:
            ok = dm.send_dm("Look at this: [file: /etc/hosts]")
        finally:
            _restore_transport(original)
        assert ok is True
        multipart_msgs = [c for c in transport.calls
                          if c["content_type"].startswith("multipart/form-data")]
        assert multipart_msgs == [], (
            f"disallowed file leaked into multipart upload: {multipart_msgs}"
        )
        json_msgs = [c for c in transport.calls if "/messages" in c["url"]
                     and c["content_type"].startswith("application/json")]
        assert len(json_msgs) == 1
        assert "[file:" not in json_msgs[0]["body"]["content"]
        assert "Look at this:" in json_msgs[0]["body"]["content"]

    _with_access_json(
        {"allowFrom": ["human"], "tierMap": {"human": "owner"}},
        run,
    )


# -----------------------------------------------------------------------
# 3. File-only body → multipart upload only, no JSON message
# -----------------------------------------------------------------------


def test_file_only_body_uploads_without_json_message():
    """Body is JUST a marker → no text to chunk; multipart upload
    happens with empty `content`. Pre-port this case fell through the
    empty-body guard and returned `True` without delivering anything."""
    fpath = _make_sutando_temp_file(content=b"ONLY_FILE")
    try:
        transport = _FakeTransport({
            ("POST", "/users/@me/channels"): {"id": "dm-up-3"},
            ("POST", "/channels/dm-up-3/messages"): {"id": "msg"},
        })
        original = dm.urllib.request.urlopen

        def run():
            _install_transport(transport)
            try:
                ok = dm.send_dm(f"[file: {fpath}]")
            finally:
                _restore_transport(original)
            assert ok is True
            json_msgs = [c for c in transport.calls if "/messages" in c["url"]
                         and c["content_type"].startswith("application/json")]
            multipart_msgs = [c for c in transport.calls if "/messages" in c["url"]
                              and c["content_type"].startswith("multipart/form-data")]
            assert json_msgs == [], (
                f"file-only body should NOT post a JSON text message; "
                f"got {json_msgs}"
            )
            assert len(multipart_msgs) == 1
            # And the file content actually rode along
            assert b"ONLY_FILE" in multipart_msgs[0]["raw"]

        _with_access_json(
            {"allowFrom": ["human"], "tierMap": {"human": "owner"}},
            run,
        )
    finally:
        os.unlink(fpath)


# -----------------------------------------------------------------------
# 4. >10 files batched at the Discord per-message cap
# -----------------------------------------------------------------------


def test_more_than_ten_files_batched_at_discord_cap():
    """Discord caps attachments at 10 per message. send_dm must split
    into ceil(N/10) multipart POSTs. Pin the batching so a future
    `DISCORD_FILES_PER_MESSAGE` change doesn't silently bin-pack 50
    files into a single 413-payload request."""
    files = [_make_sutando_temp_file(name=f"batch-{i}.bin") for i in range(11)]
    try:
        transport = _FakeTransport({
            ("POST", "/users/@me/channels"): {"id": "dm-up-4"},
            ("POST", "/channels/dm-up-4/messages"): {"id": "msg"},
        })
        original = dm.urllib.request.urlopen
        markers = " ".join(f"[file: {p}]" for p in files)

        def run():
            _install_transport(transport)
            try:
                ok = dm.send_dm(f"Eleven files: {markers}")
            finally:
                _restore_transport(original)
            assert ok is True
            multipart_msgs = [c for c in transport.calls
                              if c["content_type"].startswith("multipart/form-data")]
            assert len(multipart_msgs) == 2, (
                f"expected 2 batches (10 + 1); got {len(multipart_msgs)} "
                f"multipart messages"
            )
            # First batch should carry 10 file parts, second carries 1.
            batch_1_parts = multipart_msgs[0]["raw"].count(b'name="files[')
            batch_2_parts = multipart_msgs[1]["raw"].count(b'name="files[')
            assert batch_1_parts == 10, (
                f"batch 1 should have 10 files; got {batch_1_parts}"
            )
            assert batch_2_parts == 1, (
                f"batch 2 should have 1 file; got {batch_2_parts}"
            )

        _with_access_json(
            {"allowFrom": ["human"], "tierMap": {"human": "owner"}},
            run,
        )
    finally:
        for p in files:
            os.unlink(p)


# -----------------------------------------------------------------------
# 5. Multipart body shape and filename sanitization
# -----------------------------------------------------------------------


def test_multipart_body_shape_and_filename_sanitization():
    """The multipart envelope must include:
       - a boundary in Content-Type
       - a `payload_json` part
       - one `files[N]` part per attachment, with sanitized filename

    Sanitization: filenames containing CR/LF/quote chars must not
    let the file inject its own headers. Pin the same sanitization
    the WS-bridge has (`_safe_attachment_basename`)."""
    # Create a file whose name contains a quote — when Discord's
    # filename header is `filename="..."` an unescaped quote would
    # terminate the value and let the file smuggle arbitrary header
    # fields into the multipart envelope.
    fd, raw_path = tempfile.mkstemp(
        prefix='sutando-upload-shape-test-evil"-name-',
        suffix=".txt",
        dir="/tmp",
    )
    os.close(fd)
    Path(raw_path).write_text("shape-test-body")
    try:
        transport = _FakeTransport({
            ("POST", "/users/@me/channels"): {"id": "dm-up-5"},
            ("POST", "/channels/dm-up-5/messages"): {"id": "msg"},
        })
        original = dm.urllib.request.urlopen

        def run():
            _install_transport(transport)
            try:
                ok = dm.send_dm(f"[file: {raw_path}]")
            finally:
                _restore_transport(original)
            assert ok is True
            multipart_msgs = [c for c in transport.calls
                              if c["content_type"].startswith("multipart/form-data")]
            assert len(multipart_msgs) == 1
            ct = multipart_msgs[0]["content_type"]
            assert "boundary=" in ct
            raw = multipart_msgs[0]["raw"]
            assert b'name="payload_json"' in raw
            assert b'name="files[0]"' in raw
            assert b"shape-test-body" in raw
            # Sanitization: the raw quote char in the filename must
            # have been replaced before landing in the Content-Disposition.
            # Find the filename="...evil_-..." line — should NOT have
            # `evil"-` (the unsanitized quote) on the wire.
            disposition_lines = [
                line for line in raw.split(b"\r\n")
                if line.startswith(b"Content-Disposition: form-data; name=\"files[")
            ]
            assert len(disposition_lines) == 1
            assert b'evil"-name' not in disposition_lines[0], (
                "unsanitized quote leaked into Content-Disposition header"
            )

        _with_access_json(
            {"allowFrom": ["human"], "tierMap": {"human": "owner"}},
            run,
        )
    finally:
        os.unlink(raw_path)


def main():
    test_sendable_file_marker_triggers_multipart_upload()
    test_disallowed_file_marker_rejected_without_upload()
    test_file_only_body_uploads_without_json_message()
    test_more_than_ten_files_batched_at_discord_cap()
    test_multipart_body_shape_and_filename_sanitization()
    print("All dm-result upload tests passed.")


if __name__ == "__main__":
    main()
