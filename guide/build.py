"""The plugins' user guide as a PDF for the Kindle Scribe: the chapters (Markdown, listed in
chapters.txt) laid out on pages the shape of its screen, with a contents page whose entries
are links, and PDF bookmarks (KOReader's Table of contents).

    python build.py OUT.pdf [--fonts DIR]

Needs reportlab and Pillow. Fonts: KOReader's own (NotoSans-Regular/Bold/Italic/BoldItalic,
Segoe UI Symbol (seguisym.ttf) for symbols, DroidSansMono), from DIR (default: ./fonts).

The Markdown understood: # chapter, ## section, ### subsection, paragraphs, "- " bullets (and
"  - " under them), "1. " steps, **bold**, *italic*, `code`, > a note, ![caption](picture.png)
on a line of its own, and --- for a new page.
"""
import argparse
import os
import re
import sys

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import inch
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (BaseDocTemplate, CondPageBreak, Flowable, Frame, Image, KeepTogether,
                                NextPageTemplate, PageBreak, PageTemplate, Paragraph, Spacer, Table,
                                TableStyle)
from reportlab.platypus.tableofcontents import TableOfContents

HERE = os.path.dirname(os.path.abspath(__file__))
# The Scribe's screen (1860 x 2480 at 300 dpi) in points.
PAGE = (1860 / 300 * inch, 2480 / 300 * inch)
MARGIN_X, MARGIN_TOP, MARGIN_BOTTOM = 26, 38, 34
GREY = colors.HexColor('#555555')
LINE = colors.HexColor('#999999')
SHADE = colors.HexColor('#eeeeee')


def fonts(folder):
    for name, file in (('Sans', 'NotoSans-Regular.ttf'), ('Sans-Bold', 'NotoSans-Bold.ttf'),
                       ('Sans-Italic', 'NotoSans-Italic.ttf'), ('Sans-BoldItalic', 'NotoSans-BoldItalic.ttf'),
                       ('Sym', 'seguisym.ttf'), ('Mono', 'DroidSansMono.ttf')):
        pdfmetrics.registerFont(TTFont(name, os.path.join(folder, file)))
    pdfmetrics.registerFontFamily('Sans', normal='Sans', bold='Sans-Bold', italic='Sans-Italic', boldItalic='Sans-BoldItalic')
    return set(pdfmetrics.getFont('Sans').face.charToGlyph), set(pdfmetrics.getFont('Sym').face.charToGlyph)


SANS, SYM = set(), set()

STYLES = {
    'body': ParagraphStyle('body', fontName='Sans', fontSize=10.5, leading=14.6, spaceAfter=6),
    'bullet': ParagraphStyle('bullet', fontName='Sans', fontSize=10.5, leading=14.6, leftIndent=14, bulletIndent=3, spaceAfter=3),
    'bullet2': ParagraphStyle('bullet2', fontName='Sans', fontSize=10.5, leading=14.6, leftIndent=28, bulletIndent=17, spaceAfter=2),
    'note': ParagraphStyle('note', fontName='Sans', fontSize=10, leading=14, textColor=colors.black),
    'h1': ParagraphStyle('h1', fontName='Sans-Bold', fontSize=22, leading=27, spaceAfter=4),
    'h2': ParagraphStyle('h2', fontName='Sans-Bold', fontSize=14, leading=18, spaceBefore=10, spaceAfter=5),
    'h3': ParagraphStyle('h3', fontName='Sans-Bold', fontSize=11.5, leading=15, spaceBefore=6, spaceAfter=3),
    'caption': ParagraphStyle('caption', fontName='Sans-Italic', fontSize=9, leading=12, textColor=GREY, alignment=TA_CENTER, spaceAfter=8),
    'toc1': ParagraphStyle('toc1', fontName='Sans-Bold', fontSize=12, leading=17, spaceBefore=7),
    'toc2': ParagraphStyle('toc2', fontName='Sans', fontSize=10.5, leading=14.5, leftIndent=12),
    'title': ParagraphStyle('title', fontName='Sans-Bold', fontSize=28, leading=34, alignment=TA_CENTER),
    'subtitle': ParagraphStyle('subtitle', fontName='Sans', fontSize=12.5, leading=18, alignment=TA_CENTER, textColor=GREY),
}


def inline(text):
    """Markdown inline to reportlab markup; characters Noto Sans lacks in the symbol font."""
    text = text.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
    text = re.sub(r'`([^`]+)`', r'<font name="Mono" size="9.5">\1</font>', text)
    text = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', text)
    text = re.sub(r'(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])', r'<i>\1</i>', text)
    out, in_tag = [], False
    for ch in text:
        if ch == '<':
            in_tag = True
        if in_tag:
            out.append(ch)
            if ch == '>':
                in_tag = False
            continue
        cp = ord(ch)
        if cp < 128 or cp in SANS:
            out.append(ch)
        elif cp in SYM:
            out.append('<font name="Sym">%s</font>' % ch)
        else:
            print('no glyph for U+%04X' % cp, file=sys.stderr)
            out.append('?')
    return ''.join(out)


class Heading(Paragraph):
    """A heading that goes into the contents and the bookmarks."""

    def __init__(self, text, style, level, key):
        Paragraph.__init__(self, inline(text), style)
        self.toc_text, self.level, self.key = text, level, key


class Note(Flowable):
    """A grey box with a note in it."""

    def __init__(self, text):
        Flowable.__init__(self)
        self.p = Paragraph(inline(text), STYLES['note'])

    def wrap(self, w, h):
        self.width = w
        pw, ph = self.p.wrap(w - 20, h)
        self.height = ph + 14
        return w, self.height + 6

    def draw(self):
        c = self.canv
        c.setFillColor(SHADE)
        c.setStrokeColor(LINE)
        c.roundRect(0, 6, self.width, self.height, 5, stroke=1, fill=1)
        c.setFillColor(colors.black)
        self.p.drawOn(c, 10, 13)


class Chapter(Flowable):
    """Sets the name in the pages' header from here on."""

    def __init__(self, name):
        Flowable.__init__(self)
        self.name = name

    def wrap(self, w, h):
        return 0, 0

    def draw(self):
        pass


class Doc(BaseDocTemplate):
    def __init__(self, path, **kw):
        BaseDocTemplate.__init__(self, path, pagesize=PAGE, leftMargin=MARGIN_X, rightMargin=MARGIN_X,
                                 topMargin=MARGIN_TOP, bottomMargin=MARGIN_BOTTOM, **kw)
        frame = Frame(MARGIN_X, MARGIN_BOTTOM, PAGE[0] - 2 * MARGIN_X, PAGE[1] - MARGIN_TOP - MARGIN_BOTTOM, id='f',
                      leftPadding=0, rightPadding=0, topPadding=0, bottomPadding=0)
        self.addPageTemplates([PageTemplate('cover', [frame]), PageTemplate('page', [frame], onPageEnd=self.decorate)])
        self.chapter = ''

    def decorate(self, canv, doc):
        canv.saveState()
        canv.setFont('Sans', 8.5)
        canv.setFillColor(GREY)
        canv.drawString(MARGIN_X, PAGE[1] - 22, self.chapter)
        canv.drawRightString(PAGE[0] - MARGIN_X, 16, str(doc.page))
        canv.setStrokeColor(LINE)
        canv.setLineWidth(0.5)
        canv.line(MARGIN_X, PAGE[1] - 27, PAGE[0] - MARGIN_X, PAGE[1] - 27)
        canv.restoreState()

    def beforeDocument(self):
        self.chapter = ''

    def afterFlowable(self, f):
        if isinstance(f, Chapter):
            self.chapter = f.name
        if isinstance(f, Heading):
            if f.level == 0:
                self.chapter = f.toc_text
            self.canv.bookmarkPage(f.key)
            self.canv.addOutlineEntry(f.toc_text, f.key, f.level, closed=f.level > 0)
            if f.level <= 1:
                self.notify('TOCEntry', (f.level, f.toc_text, self.page, f.key))


def parse(path, story, counter):
    """One chapter's Markdown into flowables."""
    base = os.path.dirname(path)
    lines = open(path, encoding='utf-8').read().splitlines()
    para = []

    def flush():
        if para:
            story.append(Paragraph(inline(' '.join(para)), STYLES['body']))
            para.clear()

    i = 0
    while i < len(lines):
        line = lines[i].rstrip()
        i += 1
        m = re.match(r'^(#{1,3}) (.+)$', line)
        if m:
            flush()
            level = len(m.group(1)) - 1
            counter[0] += 1
            key = 'h%d' % counter[0]
            if level == 0:
                story.append(NextPageTemplate('page'))
                story.append(PageBreak())
                story.append(Heading(m.group(2), STYLES['h1'], 0, key))
                story.append(Rule())
            else:
                style = STYLES['h2' if level == 1 else 'h3']
                story.append(CondPageBreak(90 if level == 1 else 60))
                story.append(Heading(m.group(2), style, level, key))
            continue
        if line.strip() == '---':
            flush()
            story.append(PageBreak())
            continue
        m = re.match(r'^!\[(.*)\]\((.+)\)$', line.strip())
        if m:
            flush()
            story.append(picture(os.path.join(base, m.group(2)), m.group(1)))
            continue
        m = re.match(r'^(\s*)([-*]|\d+\.) (.+)$', line)
        if m:
            flush()
            text = m.group(3)
            # A bullet's lines that follow, indented, belong to it.
            while i < len(lines) and re.match(r'^\s{2,}\S', lines[i]) and not re.match(r'^\s*([-*]|\d+\.) ', lines[i]):
                text += ' ' + lines[i].strip()
                i += 1
            deep = len(m.group(1)) >= 2
            mark = m.group(2)
            bullet = '\u2022' if mark in '-*' else mark
            if deep and mark in '-*':
                bullet = '\u2013'
            story.append(Paragraph(inline(text), STYLES['bullet2' if deep else 'bullet'], bulletText=bullet))
            continue
        if line.startswith('> '):
            flush()
            text = line[2:]
            while i < len(lines) and lines[i].startswith('> '):
                text += ' ' + lines[i][2:]
                i += 1
            story.append(Note(text))
            continue
        if not line.strip():
            flush()
            continue
        para.append(line.strip())
    flush()


class Rule(Flowable):
    def wrap(self, w, h):
        self.width = w
        return w, 12

    def draw(self):
        self.canv.setStrokeColor(colors.black)
        self.canv.setLineWidth(1.6)
        self.canv.line(0, 6, self.width, 6)


def picture(path, caption):
    """A screenshot, greyscale, as wide as fits (and not too tall), with its caption."""
    from PIL import Image as PILImage
    im = PILImage.open(path).convert('L')
    w, h = im.size
    maxw = PAGE[0] - 2 * MARGIN_X - 40
    maxh = (PAGE[1] - MARGIN_TOP - MARGIN_BOTTOM) * 0.5
    scale = min(maxw / w, maxh / h)
    import tempfile
    flat = os.path.join(tempfile.gettempdir(), 'guide-grey-' + os.path.basename(path))
    im.save(flat)
    img = Image(flat, width=w * scale, height=h * scale)
    frame = Table([[img]], style=TableStyle([('BOX', (0, 0), (-1, -1), 0.6, LINE), ('ALIGN', (0, 0), (-1, -1), 'CENTER'),
                                             ('LEFTPADDING', (0, 0), (-1, -1), 0), ('RIGHTPADDING', (0, 0), (-1, -1), 0),
                                             ('TOPPADDING', (0, 0), (-1, -1), 0), ('BOTTOMPADDING', (0, 0), (-1, -1), 0)]))
    parts = [Spacer(1, 4), frame]
    if caption:
        parts += [Spacer(1, 4), Paragraph(inline(caption), STYLES['caption'])]
    return KeepTogether(parts)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('out')
    ap.add_argument('--fonts', default=os.path.join(HERE, 'fonts'))
    ap.add_argument('--chapters', default=os.path.join(HERE, 'chapters.txt'))
    ap.add_argument('--cover', default=os.path.join(HERE, 'cover.txt'))
    ap.add_argument('--no-contents', action='store_true')
    args = ap.parse_args()
    global SANS, SYM
    SANS, SYM = fonts(args.fonts)
    story = []
    # The cover.
    meta = {}
    for line in open(args.cover, encoding='utf-8'):
        k, __, v = line.partition(':')
        meta[k.strip()] = v.strip()
    story += [Spacer(1, 150), Paragraph(inline(meta.get('title', '')), STYLES['title']), Spacer(1, 14),
              Paragraph(inline(meta.get('subtitle', '')), STYLES['subtitle']), Spacer(1, 200),
              Paragraph(inline(meta.get('footer', '')), STYLES['subtitle'])]
    # The contents.
    if not args.no_contents:
        story += [NextPageTemplate('page'), PageBreak(), Chapter('Contents'), Paragraph('Contents', STYLES['h1']), Rule(), Spacer(1, 4)]
        toc = TableOfContents()
        toc.levelStyles = [STYLES['toc1'], STYLES['toc2']]
        toc.dotsMinLevel = 0
        story.append(toc)
    counter = [0]
    root = os.path.dirname(os.path.abspath(args.chapters))
    for line in open(args.chapters, encoding='utf-8'):
        line = line.strip()
        if line and not line.startswith('#'):
            path = line if os.path.isabs(line) else os.path.join(root, line)
            parse(path, story, counter)
    doc = Doc(args.out, title=meta.get('title', ''), author='', subject=meta.get('subtitle', ''))
    doc.multiBuild(story)
    print(args.out, doc.page, 'pages')


if __name__ == '__main__':
    main()
