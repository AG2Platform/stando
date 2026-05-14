// Terminal bridge for the Core CLI pane in the unified UI.
//
// Serves two things on 127.0.0.1:7847:
//
//   1. GET / — small HTML page that loads xterm.js from a CDN and
//      connects to the WS below. Rendered inside a WKWebView in
//      `UnifiedMainWindowController.cliPaneView()`.
//   2. WS /tty — bridges a real PTY ↔ the WebSocket. The PTY runs
//      `tmux -S /tmp/sutando-tmux.sock attach -t sutando-core`, so the
//      user sees the actual TUI of the core agent (Claude Code) instead
//      of a tail of pane.log.
//
// One client at a time is intentional. Multiple panes attaching to the
// same tmux pane fight over cursor + scroll state, and we only ever
// render the Core CLI in one window.

import { createServer, IncomingMessage, ServerResponse } from 'node:http';
import { existsSync } from 'node:fs';
import * as path from 'node:path';
import { WebSocketServer, type WebSocket } from 'ws';
import * as pty from 'node-pty';

const PORT = Number(process.env.TERMINAL_SERVER_PORT ?? 7847);
const SOCKET = process.env.SUTANDO_TMUX_SOCKET ?? '/tmp/sutando-tmux.sock';
const SESSION = process.env.SUTANDO_TMUX_SESSION ?? 'sutando-core';

function resolveTmuxBinary(): string {
	const candidates = [
		// Bundled runtime (production .app)
		process.env.SUTANDO_RUNTIME_TMUX,
		// Homebrew on Apple Silicon
		'/opt/homebrew/bin/tmux',
		// Intel
		'/usr/local/bin/tmux',
		// System fallback
		'/usr/bin/tmux',
	].filter(Boolean) as string[];
	for (const c of candidates) {
		if (existsSync(c)) return c;
	}
	return 'tmux';
}

/// Resolve the terminfo directory for the bundled tmux. The bundled tmux
/// is compiled against Homebrew ncurses, which bakes
/// `/opt/homebrew/share/terminfo` as its lookup path. On a fresh Mac
/// without Homebrew that path doesn't exist, so tmux exits with
/// "can't find terminfo database" the moment a TERM-using session
/// starts — which the xterm.js client then auto-reconnects on, producing
/// the [tmux attach exited: code=1] loop. Mirrors run-core-agent.sh's
/// resolution: look under the bundled runtime first, then fall back to
/// system paths.
function resolveTerminfoDirs(tmuxBin: string): string | undefined {
	// Explicit override always wins.
	if (process.env.TERMINFO_DIRS) return process.env.TERMINFO_DIRS;

	const candidates: string[] = [];
	// 1. Bundled runtime: <runtime>/share/terminfo, derived from the
	//    resolved tmux binary at <runtime>/bin/tmux.
	if (tmuxBin) {
		const runtimeShare = path.resolve(path.dirname(tmuxBin), '..', 'share', 'terminfo');
		candidates.push(runtimeShare);
	}
	// 2. Common system locations.
	candidates.push('/opt/homebrew/share/terminfo');
	candidates.push('/usr/local/share/terminfo');
	candidates.push('/usr/share/terminfo');

	for (const c of candidates) {
		if (existsSync(c)) return c;
	}
	return undefined;
}

const INDEX_HTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<title>Core CLI · Sutando</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/css/xterm.css" />
<style>
  html, body { background: #0a0a0a; color: #eaeaea; margin: 0; padding: 0; height: 100%; font-family: -apple-system, system-ui, sans-serif; }
  #status { position: absolute; top: 8px; right: 12px; font-size: 11px; color: #888; z-index: 5; pointer-events: none; }
  #term { position: absolute; inset: 0; padding: 8px; }
  .xterm .xterm-viewport { background: transparent !important; }
</style>
</head>
<body>
<div id="status">connecting…</div>
<div id="term"></div>
<script src="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/lib/xterm.js"></script>
<script src="https://cdn.jsdelivr.net/npm/@xterm/addon-fit@0.10.0/lib/addon-fit.js"></script>
<script>
(function () {
  const status = document.getElementById('status');
  function setStatus(t) { status.textContent = t; }

  const term = new window.Terminal({
    fontFamily: 'SF Mono, Menlo, monospace',
    fontSize: 12,
    theme: {
      background: '#0a0a0a',
      foreground: '#eaeaea',
      cursor: '#a78bfa',
      selectionBackground: 'rgba(167, 139, 250, 0.35)',
    },
    cursorBlink: true,
    scrollback: 10000,
    allowProposedApi: true,
  });
  const fit = new window.FitAddon.FitAddon();
  term.loadAddon(fit);
  term.open(document.getElementById('term'));
  fit.fit();

  // Exponential backoff so a tmux-can't-attach loop doesn't hot-spin —
  // each retry waits 1.5s, 3s, 6s, … up to 15s. Successful attach
  // (open event) resets the delay.
  let retryDelay = 1500;
  const MAX_RETRY_DELAY = 15000;

  function connect() {
    const url = (window.location.protocol === 'https:' ? 'wss:' : 'ws:') + '//' + window.location.host + '/tty';
    const ws = new WebSocket(url);
    ws.binaryType = 'arraybuffer';
    setStatus('connecting…');

    ws.addEventListener('open', () => {
      setStatus('attached');
      retryDelay = 1500;
      sendResize();
    });
    ws.addEventListener('message', (ev) => {
      if (typeof ev.data === 'string') {
        // control message — ignore (reserved for future use)
        return;
      }
      term.write(new Uint8Array(ev.data));
    });
    ws.addEventListener('close', () => {
      setStatus('disconnected · reconnecting in ' + Math.round(retryDelay / 1000) + 's…');
      setTimeout(connect, retryDelay);
      retryDelay = Math.min(retryDelay * 2, MAX_RETRY_DELAY);
    });
    ws.addEventListener('error', () => {
      try { ws.close(); } catch (_) {}
    });

    function sendResize() {
      if (ws.readyState !== 1) return;
      ws.send(JSON.stringify({ kind: 'resize', cols: term.cols, rows: term.rows }));
    }

    term.onData((d) => {
      if (ws.readyState === 1) ws.send(d);
    });
    term.onResize(sendResize);

    window.addEventListener('resize', () => { fit.fit(); });
  }

  connect();
})();
</script>
</body>
</html>`;

function serveIndex(_req: IncomingMessage, res: ServerResponse) {
	res.writeHead(200, {
		'content-type': 'text/html; charset=utf-8',
		'cache-control': 'no-store',
	});
	res.end(INDEX_HTML);
}

const httpServer = createServer((req, res) => {
	if (req.url === '/' || req.url === '/index.html') return serveIndex(req, res);
	if (req.url === '/healthz') {
		res.writeHead(200, { 'content-type': 'text/plain' });
		res.end('ok');
		return;
	}
	res.writeHead(404, { 'content-type': 'text/plain' });
	res.end('not found');
});

const wss = new WebSocketServer({ noServer: true });

httpServer.on('upgrade', (req, socket, head) => {
	if (req.url !== '/tty') {
		socket.write('HTTP/1.1 404 Not Found\r\n\r\n');
		socket.destroy();
		return;
	}
	// Only accept loopback connections. The HTTP server already binds to
	// 127.0.0.1 but this is belt-and-suspenders against config drift.
	const addr = req.socket.remoteAddress ?? '';
	if (addr !== '127.0.0.1' && addr !== '::1' && addr !== '::ffff:127.0.0.1') {
		socket.write('HTTP/1.1 403 Forbidden\r\n\r\n');
		socket.destroy();
		return;
	}
	wss.handleUpgrade(req, socket, head, (ws) => {
		wss.emit('connection', ws, req);
	});
});

wss.on('connection', (ws: WebSocket) => {
	const tmux = resolveTmuxBinary();
	const terminfoDirs = resolveTerminfoDirs(tmux);
	const env: NodeJS.ProcessEnv = {
		...process.env,
		TERM: 'xterm-256color',
		LANG: process.env.LANG ?? 'en_US.UTF-8',
	};
	if (terminfoDirs) env.TERMINFO_DIRS = terminfoDirs;
	const tty = pty.spawn(
		tmux,
		['-S', SOCKET, 'attach', '-t', SESSION],
		{
			name: 'xterm-256color',
			cols: 120,
			rows: 36,
			cwd: process.env.SUTANDO_HOME ?? process.env.HOME ?? '/tmp',
			env,
		},
	);

	let closed = false;
	const closeOnce = () => {
		if (closed) return;
		closed = true;
		try { tty.kill(); } catch (_) {}
		try { ws.close(); } catch (_) {}
	};

	tty.onData((d) => {
		if (ws.readyState === ws.OPEN) {
			ws.send(Buffer.from(d, 'binary'));
		}
	});
	tty.onExit(({ exitCode, signal }) => {
		const msg = `\r\n\x1b[33m[tmux attach exited: code=${exitCode} signal=${signal ?? '-'}]\x1b[0m\r\n`;
		try { ws.send(Buffer.from(msg)); } catch (_) {}
		closeOnce();
	});

	ws.on('message', (raw, isBinary) => {
		if (!isBinary) {
			const s = raw.toString('utf8');
			if (s.startsWith('{')) {
				try {
					const m = JSON.parse(s) as { kind?: string; cols?: number; rows?: number };
					if (m.kind === 'resize' && typeof m.cols === 'number' && typeof m.rows === 'number') {
						tty.resize(Math.max(2, m.cols | 0), Math.max(2, m.rows | 0));
						return;
					}
				} catch (_) { /* fall through to write as-is */ }
			}
			tty.write(s);
			return;
		}
		tty.write(Buffer.isBuffer(raw) ? raw.toString('utf8') : String(raw));
	});

	ws.on('close', closeOnce);
	ws.on('error', closeOnce);
});

httpServer.listen(PORT, '127.0.0.1', () => {
	console.log(`[terminal-server] listening on http://127.0.0.1:${PORT}`);
	console.log(`[terminal-server] tmux=${resolveTmuxBinary()} socket=${SOCKET} session=${SESSION}`);
});

process.on('SIGTERM', () => { httpServer.close(); process.exit(0); });
process.on('SIGINT', () => { httpServer.close(); process.exit(0); });
