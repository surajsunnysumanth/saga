#!/usr/bin/env python3
"""Offline static-site guard, not a JS sandbox or a substitute for browser QA.

Checks links/fragments, passive external requests, page metadata, image hygiene
and the demo page's offline promise. Run by scripts/check_site.sh.
"""
import re
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit

# Screenshots ship at the harness's native 2x (2400x1588) so they stay crisp on a
# Retina display, where a 1x file is stretched across ~1100 CSS px and goes soft.
# The cap is the ceiling for one 2x capture, not the target: at q86 most land under
# 400 KB; only the thirteen-photo Gallery grid needs q80 to stay inside it.
MAX_IMAGE_BYTES = 500 * 1024
ASSET_ROOTS = ('assets/images',)


def css_urls(source):
    source = re.sub(r'/\*.*?\*/', '', source, flags=re.S)
    return re.findall(r'''url\(\s*["']?([^\s)'";]+)|@import\s+["']([^"']+)''', source, flags=re.I)


class Page(HTMLParser):
    def __init__(self, source):
        super().__init__(convert_charrefs=True)
        self.source = source
        self.ids = set()
        self.references = []
        self.inline = []
        self.active_tag = None
        self.images = []
        self.iframes = []
        self.h1 = 0
        self.has_html_root = bool(re.search(r'<html\b', source, flags=re.I))
        self.lang = ''
        self.title = ''
        self.description = ''
        self._in_title = False
        self.feed(source)

    def handle_starttag(self, tag, attrs):
        attrs = {key: value or '' for key, value in attrs}
        if tag == 'html':
            self.lang = attrs.get('lang', '')
        if 'id' in attrs:
            self.ids.add(attrs['id'])
        if tag in ('style', 'script'):
            self.active_tag = tag
        if tag == 'title':
            self._in_title = True
        if tag == 'h1':
            self.h1 += 1
        if tag == 'meta' and attrs.get('name') == 'description':
            self.description = attrs.get('content', '')
        if tag == 'img':
            self.images.append(attrs)
        if tag == 'iframe':
            self.iframes.append(attrs)
        if attrs.get('style'):
            self.inline.append(('css', attrs['style']))
        for key in ('href', 'src', 'poster', 'data', 'action'):
            if not attrs.get(key):
                continue
            metadata = tag == 'link' and attrs.get('rel', '').lower() in ('canonical', 'alternate')
            if not metadata:
                self.references.append((attrs[key], tag == 'a' and key == 'href'))
        if attrs.get('srcset'):
            for candidate in attrs['srcset'].split(','):
                if candidate.strip():
                    self.references.append((candidate.split()[0], False))

    def handle_endtag(self, tag):
        if tag == self.active_tag:
            self.active_tag = None
        if tag == 'title':
            self._in_title = False

    def handle_data(self, data):
        if self._in_title:
            self.title += data
        if self.active_tag:
            self.inline.append(('css' if self.active_tag == 'style' else 'js', data))


def audit_page(path, page, root, pages):
    """Metadata and asset hygiene for a real document (not a test fragment)."""
    errors = []
    label = str(path.relative_to(root))
    if not page.has_html_root:
        return errors
    if not page.lang:
        errors.append(f'{label}: missing html lang')
    if not page.title.strip():
        errors.append(f'{label}: missing title')
    if not page.description.strip():
        errors.append(f'{label}: missing meta description')
    if page.h1 != 1:
        errors.append(f'{label}: expected exactly one h1, found {page.h1}')
    if 'data-integration' in page.source:
        errors.append(f'{label}: unfinished integration placeholder remains')
    for image in page.images:
        src = image.get('src', '')
        if 'alt' not in image:
            errors.append(f'{label}: img without alt ({src or "inline"})')
        if image.get('src', '').split('/')[0] == 'http' or src.startswith('//'):
            continue  # reported as an external request already
        if not (image.get('width') and image.get('height')) and '/assets/' in src:
            errors.append(f'{label}: img without width/height attributes ({src})')
    for frame in page.iframes:
        if not frame.get('title'):
            errors.append(f'{label}: iframe without a title')
        if 'sandbox' not in frame:
            errors.append(f'{label}: iframe without sandbox')
    return errors


def audit_images(root):
    """Every produced screenshot stays small enough for a phone connection."""
    errors = []
    for directory in ASSET_ROOTS:
        for path in (root / directory).rglob('*'):
            if path.is_file() and path.suffix.lower() in ('.webp', '.png', '.jpg', '.jpeg', '.avif'):
                if path.stat().st_size > MAX_IMAGE_BYTES:
                    size = path.stat().st_size // 1024
                    errors.append(f'{path.relative_to(root)}: {size} KB exceeds {MAX_IMAGE_BYTES // 1024} KB')
    return errors


def audit_demo(root):
    """The hosted demo must be a self-contained page with no remote references."""
    errors = []
    demo = root / 'demo' / 'index.html'
    if not demo.is_file():
        return errors
    source = demo.read_text(encoding='utf-8')
    if re.search(r'https?://|//[a-z0-9.-]+\.[a-z]{2,}/', source, flags=re.I):
        errors.append('demo/index.html: contains an absolute or protocol-relative URL')
    for hook in ('play(', 'youtube.com/embed', 'spotify.com/embed', 'w.soundcloud.com/player'):
        if hook in source:
            errors.append(f'demo/index.html: provider player hook remains ({hook})')
    if '<img' in source or '<iframe' in source:
        errors.append('demo/index.html: unexpected embedded resource')
    return errors


def audit_placeholder_names(root):
    """Fixture names must read as real names; '(demo)' never ships.

    The demo fixture was renamed to natural-sounding fictional names, so a
    literal placeholder suffix in any text file under the site (page copy,
    captions, alt text, aria labels, the docs next to the pages) is a regression.
    """
    errors = []
    for suffix in ('*.html', '*.css', '*.js', '*.md', '*.txt', '*.xml'):
        for path in root.rglob(suffix):
            if '(demo)' in path.read_text(encoding='utf-8', errors='replace'):
                errors.append(f'{path.relative_to(root)}: placeholder name suffix "(demo)"')
    return errors


def check(root):
    root = root.resolve()
    pages = {path: Page(path.read_text(encoding='utf-8')) for path in root.rglob('*.html')}
    errors = []
    if not (root / 'index.html').is_file():
        errors.append('Missing index.html')

    def reference(path, value, navigation=False):
        label = str(path.relative_to(root))
        url = urlsplit(value)
        if url.scheme or url.netloc:
            if url.scheme == 'javascript':
                errors.append(f'{label}: unsafe URL {value}')
            elif not navigation and url.scheme != 'data':
                errors.append(f'{label}: external request {value}')
            return
        if url.path.startswith('/'):
            errors.append(f'{label}: root-relative URL breaks project hosting: {value}')
            return
        target = (path.parent / unquote(url.path)).resolve() if url.path else path
        try:
            target.relative_to(root)
        except ValueError:
            errors.append(f'{label}: URL escapes site: {value}')
            return
        if target.is_dir():
            target /= 'index.html'
        if not target.is_file():
            errors.append(f'{label}: missing target {value}')
        elif url.fragment and target in pages and unquote(url.fragment) not in pages[target].ids:
            errors.append(f'{label}: missing fragment {value}')

    def code(path, kind, source):
        if kind == 'css':
            for url, imported in css_urls(source):
                reference(path, url or imported)
        elif re.search(r'\b(fetch|XMLHttpRequest|WebSocket|EventSource|sendBeacon|importScripts)\b|\bimport\s*\(', source):
            errors.append(f'{path.relative_to(root)}: network-capable script requires review')

    for path, page in pages.items():
        for value, navigation in page.references:
            reference(path, value, navigation)
        for kind, source in page.inline:
            code(path, kind, source)
        errors.extend(audit_page(path, page, root, pages))
    for suffix, kind in (('*.css', 'css'), ('*.js', 'js')):
        for path in root.rglob(suffix):
            code(path, kind, path.read_text(encoding='utf-8'))
    errors.extend(audit_images(root))
    errors.extend(audit_demo(root))
    errors.extend(audit_placeholder_names(root))
    return pages, errors


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / 'site'
    pages, errors = check(root)
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        return 1
    print(f'Site check passed: {len(pages)} HTML pages; links/fragments resolve; metadata and images valid; '
          'no detected passive external requests.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
