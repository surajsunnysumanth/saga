"""Offline regression tests for the site's link/privacy guard."""
import subprocess
import tempfile
import unittest
from pathlib import Path

CHECKER = Path(__file__).resolve().parents[1] / 'check_site.py'


class SiteCheckTests(unittest.TestCase):
    def check_site(self, html, files=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'index.html').write_text(html, encoding='utf-8')
            for name, content in (files or {}).items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content, encoding='utf-8')
            return subprocess.run(['python3', str(CHECKER), str(root)], capture_output=True, text=True)

    def test_relative_pages_and_fragments_pass(self):
        result = self.check_site('<a href="nested/page.html#hello">Read</a>',
                                 {'nested/page.html': '<h1 id="hello">Hello</h1><a href="../index.html">Home</a>'})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


    def test_broken_links_fail(self):
        for html in ('<a href="missing.html">Missing</a>', '<a href="#missing">Missing</a>'):
            with self.subTest(html=html):
                result = self.check_site(html)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('missing', result.stderr)

    def test_external_navigation_allowed_but_passive_requests_rejected(self):
        self.assertEqual(self.check_site('<a href="https://example.com">Source</a>').returncode, 0)
        for html in ('<script src="https://example.com/a.js"></script>',
                     '<img src="//example.com/image.png" alt="x">',
                     '<link rel="preconnect" href="https://example.com">',
                     '<iframe src="https://example.com"></iframe>'):
            with self.subTest(html=html):
                result = self.check_site(html)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('external request', result.stderr)

    def test_root_relative_and_escaping_paths_rejected(self):
        for href in ('/index.html', '../index.html', 'javascript:alert(1)'):
            with self.subTest(href=href):
                result = self.check_site(f'<a href="{href}">Link</a>')
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)


    def test_css_and_srcset_assets_checked(self):
        for html, files in (
            ('<link rel="stylesheet" href="style.css">', {'style.css': 'p { background: url(https://example.com/a.png) }'}),
            ('<link rel="stylesheet" href="style.css">', {'style.css': '@import "https://example.com/font.css";'}),
            ('<img srcset="missing.png 2x" alt="x">', {}),
            ('<div style="background:url(https://example.com/a.png)">x</div>', {}),
            ('<script>fetch("https://example.com")</script>', {}),
        ):
            with self.subTest(html=html, files=files):
                result = self.check_site(html, files)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def test_metadata_external_urls_are_not_requests(self):
        html = '<link rel="canonical" href="https://example.com/saga/"><meta property="og:image" content="https://example.com/card.png">'
        self.assertEqual(self.check_site(html).returncode, 0)

    @staticmethod
    def document(body, head='<title>Page</title><meta name="description" content="Summary">'):
        return f'<!doctype html><html lang="en"><head>{head}</head><body>{body}</body></html>'

    def test_unfinished_integration_placeholder_rejected(self):
        html = self.document('<h1>Page</h1><div data-integration="V01 hero image">Pending</div>')
        result = self.check_site(html)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('placeholder', result.stderr)

    def test_page_metadata_and_headings_required(self):
        cases = (
            self.document('<h1>Page</h1>', head='<meta name="description" content="Summary">'),
            self.document('<h1>Page</h1>', head='<title>Page</title>'),
            self.document('<h1>One</h1><h1>Two</h1>'),
            self.document('<h1>Page</h1>').replace('<html lang="en">', '<html>'),
        )
        for html in cases:
            with self.subTest(html=html[:60]):
                result = self.check_site(html)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def test_images_need_alt_and_dimensions(self):
        for image in ('<img src="assets/a.webp">',
                      '<img src="assets/a.webp" alt="A" width="10" height="10">'):
            with self.subTest(image=image):
                html = self.document(f'<h1>Page</h1>{image}')
                result = self.check_site(html, {'assets/a.webp': 'x'})
                if 'alt="A"' in image:
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                else:
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def test_oversized_screenshot_rejected(self):
        html = self.document('<h1>Page</h1><img src="assets/images/big.webp" alt="A" width="1" height="1">')
        result = self.check_site(html, {'assets/images/big.webp': 'x' * (500 * 1024 + 1)})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('exceeds', result.stderr)

    def test_demo_page_must_be_offline(self):
        base = self.document('<h1>Demo</h1>', head='<title>Demo</title><meta name="description" content="Demo">')
        self.assertEqual(self.check_site('', {'demo/index.html': base}).returncode, 0)
        for extra in ('<script>function play(id, src, h) {}</script>',
                      '<img src="https://example.com/a.png" alt="x">',
                      '<p>See https://example.com</p>'):
            with self.subTest(extra=extra):
                result = self.check_site('', {'demo/index.html': base + extra})
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)


    def test_placeholder_name_suffix_rejected(self):
        self.assertEqual(self.check_site('<h1>Page</h1>').returncode, 0)
        for name, content in (('notes.md', 'The capture said Jules (demo).'),
                              ('assets/site.css', '/* River (demo) */'),
                              ('demo/index.html', '<p>Little Garden (demo)</p>')):
            with self.subTest(name=name):
                result = self.check_site(self.document('<h1>Page</h1>'), {name: content})
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('placeholder name suffix', result.stderr)


if __name__ == '__main__':
    unittest.main()
