"""Builds app.html (class desk only, full window) from ../studywhitney.html so both stay in sync."""
import sys, re
src = open('../studywhitney.html', encoding='utf-8').read()
out = sys.argv[1]

head_links = src[src.index('<link rel="preconnect"'):src.index('<script src="https://cdn.jsdelivr.net/npm/mermaid')]
style = src[src.index('<style>') + 7:src.index('</style>')]
sec = src[src.index('<section aria-label="Class desk mockup">'):]
app = sec[sec.index('<div class="app">'):sec.index('</section>')].strip()
app = re.sub(r'\s*<div class="app-bar">.*?</div>', '', app, count=1)  # the Mac window already has a title bar

script = src[src.index('<script>', src.index('</header>')) + 8:]
sprite = script[script.index('/* ---------------- sprite engine'):script.index('/* ---------------- live pet')]
desk = script[script.index('/* ---------------- class desk'):script.index('/* ---------------- diagrams')]

app_css = '''
/* ---------- full-window app ---------- */
html, body { height: 100% }
body { padding: 0; overflow: hidden }
.app { height: 100%; border: 0; border-radius: 0; box-shadow: none; display: flex; flex-direction: column }
.app-grid { flex: 1; min-height: 0 }
.main { overflow-y: auto }
.side { overflow-y: auto }
.chat { min-height: 0 }
.log { height: auto; flex: 1 }
.app-grid { grid-template-columns: 220px minmax(0, 1fr) }
.main { padding: 22px 28px 40px }
@media (max-width: 760px) { body { overflow: auto } .app { height: auto } .app-grid { grid-template-columns: 1fr } }
.toast { position: fixed }
'''

page = f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>StudyWhitney</title>
{head_links.strip()}
<style>{style}{app_css}</style>
</head>
<body>
{app}
<script>
{sprite}const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;

{desk}</script>
</body>
</html>
'''
open(out, 'w', encoding='utf-8').write(page)
