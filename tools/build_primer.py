"""Render docs/PRIMER.md into a styled HTML page.

Usage: uv run --with markdown python tools/build_primer.py docs/PRIMER.md <out.html> tools/primer_shell.html [--standalone]

Without --standalone the output is the Artifact body (the Artifact host adds the
document skeleton). With it, the output is a complete page you can open locally.
"""
import html
import re
import sys
import markdown

src, out = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()

# Drop the H1 + intro (rendered by the page header instead).
body_md = text.split("\n---\n", 1)[1]

# <details> blocks are raw HTML, so markdown won't touch their inline code; do it here.
def inline_code(line: str) -> str:
    return re.sub(r"`([^`]+)`", lambda m: f"<code>{html.escape(m.group(1))}</code>", line)
def flashcard(match: re.Match) -> str:
    question, answer = inline_code(match.group(1)), inline_code(match.group(2).strip())
    return f'<details><summary>{question}</summary><div class="answer">{answer}</div></details>'
body_md = re.sub(r"<details><summary>(.*?)</summary>(.*?)</details>", flashcard, body_md, flags=re.S)

md = markdown.Markdown(extensions=["fenced_code", "tables", "toc", "sane_lists"],
                       extension_configs={"toc": {"slugify": lambda v, s: re.sub(r"[^a-z0-9]+", "-", v.lower()).strip("-")}})
content = md.convert(body_md)
content = content.replace("<hr />", "")
content = content.replace("<table>", '<div class="table-wrap"><table>').replace("</table>", "</table></div>")
# Mark ASCII diagrams (fenced blocks with no language) so they get the diagram treatment.
content = content.replace("<pre><code>", '<pre class="diagram"><code>')

toc_items = []
for tok in md.toc_tokens:
    m = re.match(r"(\d+)\.\s*(.*)", tok["name"])
    num, label = (m.group(1), m.group(2)) if m else ("", tok["name"])
    toc_items.append(f'<li><a href="#{tok["id"]}"><span class="n">{num}</span>{label}</a></li>')
toc = "\n".join(toc_items)

shell = open(sys.argv[3], encoding="utf-8").read()
page = shell.replace("{{TOC}}", toc).replace("{{CONTENT}}", content)
if "--standalone" in sys.argv:
    page = ('<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
            '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\n'
            "</head>\n<body>\n" + page + "\n</body>\n</html>\n")
open(out, "w", encoding="utf-8").write(page)
print("[build] wrote", out, len(content), "chars,", len(toc_items), "sections")
