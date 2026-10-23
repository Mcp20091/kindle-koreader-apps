# Kindle apps for KOReader

A set of KOReader plugins for a jailbroken Kindle Scribe: a launcher, Home Assistant, Microsoft To Do, handwritten notes, crosswords, Wikipedia, Syncthing, SSH and a web page for running it all from a phone or computer.

For now this repo has the user guide. The plugins will follow.

## The guide

**[Kindle Apps Guide.pdf](Kindle%20Apps%20Guide.pdf)**: the whole guide, laid out for the Kindle Scribe's screen. Copy it to the Kindle and open it in KOReader; the contents page and KOReader's Table of contents jump to each chapter.

The chapters are also here as Markdown, so you can read them on GitHub:

1. [Getting started](guide/intro.md)
2. [Apps (the launcher)](guide/apps.md)
3. [Home Assistant](guide/homeassistant.md)
4. [To Do](guide/todo.md)
5. [Notes](guide/notes.md)
6. [Crosswords](guide/crosswords.md)
7. [Wikipedia](guide/wikipedia.md)
8. [Syncthing](guide/syncthing.md)
9. [SSH](guide/ssh.md)
10. [Web server](guide/webserver.md)
11. [Credits](guide/credits.md)

The screenshots use made-up data.

## Building the PDF

```bash
pip install reportlab pillow
python guide/build.py "Kindle Apps Guide.pdf" --fonts FONTS_FOLDER
```

The fonts folder needs NotoSans-Regular, -Bold, -Italic and -BoldItalic, and DroidSansMono (all in KOReader's `fonts` folder), plus Segoe UI Symbol (`seguisym.ttf`, from Windows) for symbols. The chapters and their order are in `guide/chapters.txt`; the cover is `guide/cover.txt`.

## Credits

See [Credits](guide/credits.md). The Syncthing plugin builds on [koreader-syncthing](https://github.com/jasonchoimtt/koreader-syncthing) by jasonchoimtt.
