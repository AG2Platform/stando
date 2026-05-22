#!/usr/bin/env python3
"""
Media generation.

Supports:
- Text-to-image: generate from a text prompt (Gemini Flash Image by default;
  OpenAI gpt-image-1 when IMAGE_PROVIDER=openai)
- Image editing: modify an existing image with a text prompt (both providers)
- Text-to-video: generate video from a text prompt (Veo — Gemini only; no
  OpenAI equivalent yet)
- Image-to-video: generate video from reference image + prompt (Veo only)

Provider selection:
  IMAGE_PROVIDER env var: 'gemini' (default) | 'openai'
  --image-provider CLI flag overrides the env var.
  Video always uses Gemini Veo regardless of IMAGE_PROVIDER.

Usage:
  python3 generate.py --prompt "A sunset over mountains"
  python3 generate.py --input photo.jpg --prompt "Replace the background"
  python3 generate.py --video --prompt "A timelapse of a city" --output city.mp4
  python3 generate.py --video --input ref.jpg --prompt "Animate this scene"
"""

import argparse
import os
import sys
import time
from pathlib import Path


def _resolve_gateway_for_image_gen():
    """Detect whether to route image/video generation via the Sutando
    cloud gateway. Returns {base_url, token} when:
      1. cloud-auth.json exists (user signed in),
      2. GET /api/me confirms paid plan (plus / pro / max),
    otherwise None — caller stays on BYOK.

    Network timeout 3s; failures fall through silently so a downed
    cloud doesn't block local image gen for paid users.
    """
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent.parent / "src"))
        from cloud_metrics import load_cloud_auth  # type: ignore
    except Exception:  # noqa: BLE001
        return None
    auth = load_cloud_auth()
    if not auth:
        return None
    import json
    from urllib import request as _urlreq
    from urllib.error import HTTPError, URLError
    try:
        req = _urlreq.Request(
            f"{auth['apiBase'].rstrip('/')}/api/me",
            method="GET",
            headers={"Authorization": f"Bearer {auth['token']}"},
        )
        with _urlreq.urlopen(req, timeout=3.0) as resp:
            data = json.loads(resp.read().decode("utf-8", errors="replace"))
    except (HTTPError, URLError, OSError, TimeoutError, json.JSONDecodeError):
        return None
    plan = data.get("plan")
    if plan not in ("plus", "pro", "max"):
        return None
    return {
        # Trailing slash is significant — the SDK appends `v1beta/...` to
        # base_url, and gateway's catch-all parses the path-after-`/llm/`.
        "base_url": f"{auth['apiBase'].rstrip('/')}/api/gateway/llm/",
        "token": auth["token"],
    }


def load_env():
    """Load GEMINI_API_KEY from .env files."""
    for env_path in [
        Path(__file__).resolve().parent.parent.parent.parent / ".env",
        Path.home() / ".env",
    ]:
        if env_path.exists():
            for line in env_path.read_text().splitlines():
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, val = line.split("=", 1)
                    val = val.strip()
                    # Strip matching surrounding quotes (mirrors python-
                    # dotenv). Without this, `GEMINI_API_KEY="abc"` in
                    # .env stores `"abc"` (with quotes) and Gemini's
                    # Authorization header gets a malformed key.
                    if len(val) >= 2 and val[0] == val[-1] and val[0] in ('"', "'"):
                        val = val[1:-1]
                    # .env wins over stale shell env — see PR #416.
                    os.environ[key.strip()] = val


def generate_image_openai(args):
    """Generate or edit an image via OpenAI's Images API (gpt-image-1).

    No google.genai dependency — uses urllib + multipart/form-data so this
    code path works in minimal environments (matches openai-tts skill's
    dependency footprint).

    Returns the absolute output path on success; raises on failure.
    """
    import base64
    import json
    from urllib import request as _urlreq
    from urllib.error import HTTPError, URLError

    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        print("Error: OPENAI_API_KEY not set. Add it to .env or set IMAGE_PROVIDER=gemini.", file=sys.stderr)
        sys.exit(1)

    model = args.model or os.environ.get("IMAGE_MODEL_OPENAI") or os.environ.get("IMAGE_MODEL", "gpt-image-1")
    print(f"  Model: {model} (OpenAI)", file=sys.stderr)
    print(f"  Prompt: {args.prompt[:100]}{'...' if len(args.prompt) > 100 else ''}", file=sys.stderr)

    if args.output:
        out_path = Path(args.output)
    else:
        ts = int(time.time() * 1000)
        out_path = Path(f"generated-{ts}.png")
    out_path.parent.mkdir(parents=True, exist_ok=True)

    # OpenAI Images API returns PNG; if the user asked for jpg/webp we re-
    # encode via Pillow after the fact (same path as the Gemini branch).
    ext = out_path.suffix.lower()
    out_format = "JPEG" if ext in (".jpg", ".jpeg") else "WEBP" if ext == ".webp" else "PNG"

    # gpt-image-1 supports 1024x1024 / 1024x1536 / 1536x1024 / "auto".
    size = os.environ.get("IMAGE_SIZE", "auto")

    is_edit = bool(args.input)
    headers = {"Authorization": f"Bearer {api_key}"}

    if is_edit:
        # Multipart upload to /v1/images/edits — supports up to 16 input
        # images per the gpt-image-1 docs. Build the body by hand to avoid
        # an http client dependency.
        boundary = "----sutando-image-edit-" + str(int(time.time() * 1000))
        body = bytearray()
        def _field(name: str, value: str) -> None:
            body.extend(f"--{boundary}\r\n".encode())
            body.extend(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
            body.extend(value.encode())
            body.extend(b"\r\n")
        def _file(name: str, filename: str, mime: str, data: bytes) -> None:
            body.extend(f"--{boundary}\r\n".encode())
            body.extend(f'Content-Disposition: form-data; name="{name}"; filename="{filename}"\r\n'.encode())
            body.extend(f"Content-Type: {mime}\r\n\r\n".encode())
            body.extend(data)
            body.extend(b"\r\n")
        _field("model", model)
        _field("prompt", args.prompt)
        _field("size", size)
        _field("n", "1")
        for img_path in args.input:
            img_path = os.path.expanduser(img_path)
            if not os.path.isfile(img_path):
                print(f"Error: Input image not found: {img_path}", file=sys.stderr)
                sys.exit(1)
            with open(img_path, "rb") as fh:
                _file(
                    "image[]" if len(args.input) > 1 else "image",
                    os.path.basename(img_path),
                    "image/png",
                    fh.read(),
                )
            print(f"  Input: {img_path}", file=sys.stderr)
        body.extend(f"--{boundary}--\r\n".encode())
        headers["Content-Type"] = f"multipart/form-data; boundary={boundary}"
        url = "https://api.openai.com/v1/images/edits"
        req = _urlreq.Request(url, data=bytes(body), headers=headers, method="POST")
    else:
        payload = {
            "model": model,
            "prompt": args.prompt,
            "size": size,
            "n": 1,
        }
        headers["Content-Type"] = "application/json"
        url = "https://api.openai.com/v1/images/generations"
        req = _urlreq.Request(url, data=json.dumps(payload).encode(), headers=headers, method="POST")

    print(f"  Generating image...", file=sys.stderr)
    try:
        with _urlreq.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read().decode("utf-8", errors="replace"))
    except HTTPError as e:
        msg = e.read().decode("utf-8", errors="replace") if hasattr(e, "read") else str(e)
        if e.code == 401:
            print("Error: OpenAI rejected the key (401). Check OPENAI_API_KEY.", file=sys.stderr)
        elif e.code == 429:
            print("Error: OpenAI rate-limited image generation. Try again shortly.", file=sys.stderr)
        else:
            print(f"Error: OpenAI image API call failed ({e.code}): {msg[:300]}", file=sys.stderr)
        sys.exit(1)
    except (URLError, TimeoutError, OSError) as e:
        print(f"Error: OpenAI image API request failed: {e}", file=sys.stderr)
        sys.exit(1)

    items = data.get("data") or []
    if not items or not items[0].get("b64_json"):
        print(f"Error: OpenAI returned no image. Raw response: {json.dumps(data)[:300]}", file=sys.stderr)
        sys.exit(1)

    img_bytes = base64.b64decode(items[0]["b64_json"])

    if out_format == "PNG":
        out_path.write_bytes(img_bytes)
        print(f"  Saved: {out_path} (PNG)", file=sys.stderr)
    else:
        # Re-encode for JPEG/WEBP. Pillow is already a dependency for the
        # Gemini branch; treat it the same here.
        try:
            from PIL import Image
            import io as _io
        except ImportError:
            print("Error: Pillow required for JPEG/WEBP output. Run: pip3 install Pillow", file=sys.stderr)
            sys.exit(1)
        img = Image.open(_io.BytesIO(img_bytes))
        save_kwargs = {"quality": args.quality} if out_format in ("JPEG", "WEBP") else {}
        if out_format == "JPEG":
            img = img.convert("RGB")
        img.save(str(out_path), out_format, **save_kwargs)
        print(f"  Saved: {out_path} ({img.size[0]}x{img.size[1]}, {out_format})", file=sys.stderr)

    print(str(out_path.resolve()))


def generate_image(client, args):
    """Generate or edit an image."""
    from google.genai import types
    from PIL import Image
    import io

    contents = []

    for img_path in args.input:
        img_path = os.path.expanduser(img_path)
        if not os.path.isfile(img_path):
            print(f"Error: Input image not found: {img_path}", file=sys.stderr)
            sys.exit(1)

        img = Image.open(img_path)
        max_dim = 4096
        if max(img.size) > max_dim:
            ratio = max_dim / max(img.size)
            new_size = (int(img.size[0] * ratio), int(img.size[1] * ratio))
            img = img.resize(new_size, Image.LANCZOS)
            print(f"  Resized {img_path} to {new_size[0]}x{new_size[1]}", file=sys.stderr)

        contents.append(img)
        print(f"  Input: {img_path} ({img.size[0]}x{img.size[1]})", file=sys.stderr)

    contents.append(args.prompt)

    if args.output:
        out_path = Path(args.output)
    else:
        ts = int(time.time() * 1000)
        out_path = Path(f"generated-{ts}.png")

    out_path.parent.mkdir(parents=True, exist_ok=True)

    ext = out_path.suffix.lower()
    if ext in (".jpg", ".jpeg"):
        out_format = "JPEG"
    elif ext == ".webp":
        out_format = "WEBP"
    else:
        out_format = "PNG"

    model = args.model or os.environ.get("IMAGE_MODEL", "gemini-3.1-flash-image-preview")
    print(f"  Model: {model}", file=sys.stderr)
    print(f"  Prompt: {args.prompt[:100]}{'...' if len(args.prompt) > 100 else ''}", file=sys.stderr)
    print(f"  Generating image...", file=sys.stderr)

    try:
        response = client.models.generate_content(
            model=model,
            contents=contents,
            config=types.GenerateContentConfig(
                response_modalities=["IMAGE", "TEXT"],
            ),
        )
    except Exception as e:
        msg = str(e)
        # Cloud gateway translates cap-hits to HTTP 402 / 429. The genai
        # SDK surfaces the status as part of the exception string.
        if "402" in msg or "insufficient_credits" in msg:
            print(
                "Error: Wallet empty for image generation. "
                "Top up at https://sutando.ag2.ai/billing.",
                file=sys.stderr,
            )
            sys.exit(2)
        if "429" in msg or "fair_use_burst" in msg:
            print(
                "Error: Cloud rate-limited image generation (burst). "
                "Try again in a minute.",
                file=sys.stderr,
            )
            sys.exit(2)
        print(f"Error: Gemini API call failed: {e}", file=sys.stderr)
        sys.exit(1)

    image_saved = False
    text_response = ""

    if response.candidates:
        for part in response.candidates[0].content.parts:
            if part.inline_data and part.inline_data.mime_type.startswith("image/"):
                img_data = part.inline_data.data
                img = Image.open(io.BytesIO(img_data))

                save_kwargs = {}
                if out_format == "JPEG":
                    img = img.convert("RGB")
                    save_kwargs["quality"] = args.quality
                elif out_format == "WEBP":
                    save_kwargs["quality"] = args.quality

                img.save(str(out_path), out_format, **save_kwargs)
                image_saved = True
                print(f"  Saved: {out_path} ({img.size[0]}x{img.size[1]}, {out_format})", file=sys.stderr)
            elif part.text:
                text_response += part.text

    if not image_saved:
        print(f"Error: No image in response.", file=sys.stderr)
        if text_response:
            print(f"  Model said: {text_response}", file=sys.stderr)
        sys.exit(1)

    if text_response:
        print(f"  Note: {text_response.strip()}", file=sys.stderr)

    print(str(out_path.resolve()))


def generate_video(client, args):
    """Generate a video using Veo."""
    from google.genai import types
    from PIL import Image
    import io

    if args.output:
        out_path = Path(args.output)
    else:
        ts = int(time.time() * 1000)
        out_path = Path(f"generated-{ts}.mp4")

    out_path.parent.mkdir(parents=True, exist_ok=True)

    model = args.model or os.environ.get("VIDEO_MODEL", "veo-3.1-generate-preview")
    aspect = args.aspect or "16:9"

    print(f"  Model: {model}", file=sys.stderr)
    print(f"  Prompt: {args.prompt[:100]}{'...' if len(args.prompt) > 100 else ''}", file=sys.stderr)
    print(f"  Aspect: {aspect}", file=sys.stderr)

    # Build config
    config = types.GenerateVideosConfig(
        aspect_ratio=aspect,
    )

    # If input image provided, use as reference
    image = None
    if args.input:
        img_path = os.path.expanduser(args.input[0])
        if not os.path.isfile(img_path):
            print(f"Error: Input image not found: {img_path}", file=sys.stderr)
            sys.exit(1)
        img = Image.open(img_path)
        print(f"  Reference image: {img_path} ({img.size[0]}x{img.size[1]})", file=sys.stderr)
        # Convert to bytes for the API
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        image = types.Image(image_bytes=buf.getvalue(), mime_type="image/png")

    print(f"  Generating video (this may take 1-3 minutes)...", file=sys.stderr)

    try:
        if image:
            operation = client.models.generate_videos(
                model=model,
                prompt=args.prompt,
                image=image,
                config=config,
            )
        else:
            operation = client.models.generate_videos(
                model=model,
                prompt=args.prompt,
                config=config,
            )
    except Exception as e:
        msg = str(e)
        if "402" in msg or "insufficient_credits" in msg:
            print(
                "Error: Wallet empty for video generation. "
                "Top up at https://sutando.ag2.ai/billing.",
                file=sys.stderr,
            )
            sys.exit(2)
        if "429" in msg or "fair_use_burst" in msg:
            print(
                "Error: Cloud rate-limited video generation. "
                "Try again in a minute.",
                file=sys.stderr,
            )
            sys.exit(2)
        print(f"Error: Veo API call failed: {e}", file=sys.stderr)
        sys.exit(1)

    # Poll for completion
    elapsed = 0
    while not operation.done:
        time.sleep(10)
        elapsed += 10
        print(f"  Waiting... ({elapsed}s)", file=sys.stderr)
        try:
            operation = client.operations.get(operation)
        except Exception as e:
            print(f"Error polling: {e}", file=sys.stderr)
            sys.exit(1)

    # Download result
    try:
        generated_video = operation.response.generated_videos[0]
        client.files.download(file=generated_video.video)
        generated_video.video.save(str(out_path))
        print(f"  Saved: {out_path}", file=sys.stderr)
    except Exception as e:
        print(f"Error downloading video: {e}", file=sys.stderr)
        sys.exit(1)

    print(str(out_path.resolve()))


def main():
    parser = argparse.ArgumentParser(description="Generate images (OpenAI default, Gemini optional) or videos (Gemini Veo)")
    parser.add_argument("--prompt", "-p", required=True, help="Text prompt")
    parser.add_argument("--input", "-i", action="append", default=[], help="Input image path(s)")
    parser.add_argument("--output", "-o", default=None, help="Output file path")
    parser.add_argument("--model", "-m", default=None,
                        help="Model (defaults: gpt-image-1 for OpenAI images, gemini-3.1-flash-image-preview for Gemini images, veo-3.1-generate-preview for video)")
    parser.add_argument("--quality", "-q", type=int, default=90, help="JPEG quality 1-100 (default: 90)")
    parser.add_argument("--video", "-v", action="store_true", help="Generate video instead of image (always uses Gemini Veo)")
    parser.add_argument("--aspect", default=None, help="Video aspect ratio: 16:9 (default) or 9:16")
    parser.add_argument(
        "--image-provider",
        default=None,
        choices=["openai", "gemini"],
        help="Override IMAGE_PROVIDER env var. Default: 'gemini'. Set 'openai' to use gpt-image-1.",
    )

    args = parser.parse_args()

    load_env()

    # Provider routing for images. Video stays on Gemini Veo regardless —
    # OpenAI has no public video model yet.
    image_provider = (args.image_provider or os.environ.get("IMAGE_PROVIDER") or "gemini").lower()
    if image_provider not in ("openai", "gemini"):
        print(f"Error: IMAGE_PROVIDER must be 'openai' or 'gemini' (got '{image_provider}')", file=sys.stderr)
        sys.exit(1)

    # Short-circuit for OpenAI image path — no google.genai dependency.
    if not args.video and image_provider == "openai":
        generate_image_openai(args)
        # Cloud telemetry — best-effort, lazy import.
        try:
            sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent.parent / "src"))
            from cloud_metrics import record_event, record_onboarding
            record_event("image.gen", units=1, metadata={"model": args.model or "gpt-image-1", "provider": "openai"})
            record_onboarding("first_image")
        except Exception:  # noqa: BLE001
            pass
        return

    api_key = os.environ.get("GEMINI_API_KEY")
    try:
        from google import genai
        from google.genai import types as genai_types
    except ImportError:
        print("Error: google-genai not installed. Run: pip3 install google-genai", file=sys.stderr)
        sys.exit(1)

    # Managed-gateway routing: when the user is signed in to a paid
    # Sutando tier, route image/video generation through
    # /api/gateway/llm/* so cloud master keys + per-call wallet debit
    # apply. Falls back to BYOK if the auth file is missing or the
    # user is on Free. Cloud returns 402/429 on cap-hit; we surface
    # those as a clean error so callers can show "top up at /billing".
    gateway = _resolve_gateway_for_image_gen()
    sutando_kind = "video.gen" if args.video else "image.gen"
    if gateway is not None:
        client = genai.Client(
            # api_key is ignored upstream because the gateway substitutes
            # its own master key, but the SDK still requires *some* value
            # to fall through its config validation.
            api_key=api_key or "sutando-gateway",
            http_options=genai_types.HttpOptions(
                base_url=gateway["base_url"],
                headers={
                    "Authorization": f"Bearer {gateway['token']}",
                    "X-Sutando-Kind": sutando_kind,
                },
            ),
        )
        print(f"  Routing via Sutando cloud gateway ({sutando_kind})", file=sys.stderr)
    else:
        if not api_key:
            print(
                "Error: GEMINI_API_KEY not set and no Sutando paid-tier sign-in. "
                "Add GEMINI_API_KEY to .env or sign in via the Sutando menu bar.",
                file=sys.stderr,
            )
            sys.exit(1)
        client = genai.Client(api_key=api_key)

    # Cloud telemetry: import lazily so missing src/cloud_metrics.py
    # doesn't break this script for users who haven't pulled main.
    def _emit_cloud_metric(kind: str, units: float, model: str | None) -> None:
        try:
            sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent.parent / "src"))
            from cloud_metrics import record_event
            record_event(kind, units=units, metadata={"model": model} if model else None)
        except Exception:  # noqa: BLE001 — telemetry must never break the call
            pass

    def _emit_first_step(step: str) -> None:
        try:
            sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent.parent / "src"))
            from cloud_metrics import record_onboarding
            record_onboarding(step)
        except Exception:  # noqa: BLE001
            pass

    def _probe_video_seconds(path: Path) -> int:
        """Return integer seconds for the saved video, or 8 (Veo 3 default)
        if ffprobe isn't available. Billing is per-second so a small under-
        count is preferable to over-counting."""
        try:
            import subprocess
            out = subprocess.run(
                ["ffprobe", "-v", "error", "-show_entries", "format=duration",
                 "-of", "default=noprint_wrappers=1:nokey=1", str(path)],
                capture_output=True, text=True, timeout=5,
            )
            if out.returncode == 0 and out.stdout.strip():
                return max(1, int(round(float(out.stdout.strip()))))
        except Exception:
            pass
        return 8

    if args.video:
        generate_video(client, args)
        # video.gen is billed per second of generated video — probe the
        # saved file rather than charging 1 unit per generation.
        out_path = Path(args.output) if args.output else None
        seconds = _probe_video_seconds(out_path) if out_path and out_path.exists() else 8
        _emit_cloud_metric("video.gen", units=seconds, model=args.model)
    else:
        try:
            from PIL import Image
        except ImportError:
            print("Error: Pillow not installed. Run: pip3 install Pillow", file=sys.stderr)
            sys.exit(1)
        generate_image(client, args)
        _emit_cloud_metric("image.gen", units=1, model=args.model)
        _emit_first_step("first_image")


if __name__ == "__main__":
    main()
