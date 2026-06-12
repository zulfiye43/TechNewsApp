#!/usr/bin/env python3
"""
TechDigest Pipeline
News holen (RSS + Hacker News) → Claude fasst zusammen (Digest mit detail-Feld)
→ optional Podcast-MP3 mit ElevenLabs (Stimme: Bella, deutsch).

Setup:
    pip install -r requirements.txt
    export ANTHROPIC_API_KEY=sk-ant-...
    export ELEVENLABS_API_KEY=...        # nur für --audio

Nutzung:
    python digest_pipeline.py            # → out/digest.json
    python digest_pipeline.py --audio    # → zusätzlich out/digest.mp3
"""

import argparse
import json
import os
import re
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import feedparser
import requests

# ---------------------------------------------------------------- Konfiguration

SOURCES_FILE = Path(__file__).parent / "sources.json"
OUT_DIR = Path(__file__).parent / "out"
MAX_ITEMS_PER_SOURCE = 15
MAX_AGE_HOURS = 30
DIGEST_ITEM_COUNT = 9
# Kommagetrennt, z.B. "de,en". Achtung: jede Sprache kostet eigene
# Claude- und ElevenLabs-Credits (eigener Podcast pro Sprache!).
LANGUAGES = [l.strip() for l in os.environ.get("DIGEST_LANGS", "de").split(",")]
LANG_INSTRUCTION = {
    "de": "Schreibe ALLES auf Deutsch.",
    "en": "Write EVERYTHING in English (headlines, summaries, details, greeting, podcast title).",
}
CLAUDE_MODEL = "claude-sonnet-4-6"

# ElevenLabs
ELEVEN_VOICE_NAME = "Bella"              # professional, bright, warm
# eleven_multilingual_v2 = beste Qualität (1 Credit/Zeichen)
# eleven_flash_v2_5      = halber Preis (0,5 Credits/Zeichen), fast so gut
ELEVEN_MODEL = os.environ.get("ELEVEN_MODEL", "eleven_multilingual_v2")
ELEVEN_VOICE_SETTINGS = {
    "stability": 0.45,        # niedriger = lebendiger
    "similarity_boost": 0.75,
    "style": 0.5,             # deutlich mehr Ausdruck – Podcast, nicht Nachrichten
    "use_speaker_boost": True,
}

DIGEST_PROMPT = """Du bist Redakteurin eines täglichen Tech-Digests für eine \
iOS-Entwicklerin. Sie will in 2 Minuten auf dem Stand sein: allgemeine \
Tech-News, AI/ML und iOS/Apple-Entwicklung.

Hier die heutigen Roh-News (Titel, Quelle, URL):

{items}

Wähle die {count} relevantesten Stories (Mix aus AI, iOS/Apple und allgemeinen \
Tech-News, keine Duplikate). Sortiere nach Wichtigkeit: Die ersten 3 Einträge \
sind die Top-News des Tages. Schreibe pro Story:
- eine knackige deutsche Headline
- "summary": 1-2 lockere, präzise Sätze
- "detail": 4-5 Sätze Vertiefung, wo sinnvoll mit einem konkreten \
"was heißt das für Entwicklerinnen"-Dreh

Achtung JSON-Validität: Innerhalb der Texte KEINE doppelten \
Anführungszeichen verwenden – nutze »…« oder ‚…' für Zitate/Titel.

{lang_instruction}

Antworte NUR mit validem JSON in genau diesem Format:
{{
  "date": "{today}",
  "greeting": "Ein Satz Begrüßung mit dem Tages-Highlight – ZEITNEUTRAL, \
also kein 'Guten Morgen' (man weiß nicht, wann gelesen wird)",
  "podcast_title": "Knackiger Episodentitel (max. 6 Wörter) zum spannendsten \
Thema des Tages, wie ein Podcast-Folgentitel",
  "items": [
    {{"topic": "ai|ios|tech", "headline": "...", "summary": "...",
      "detail": "...", "source": "...", "url": "..."}}
  ]
}}"""

PODCAST_PROMPT = """Verwandle diesen Tech-Digest in ein deutsches \
Podcast-Skript für eine einzelne Sprecherin.

HARTE LÄNGENGRENZE: maximal 570 Wörter (= 4 Minuten Sprechzeit). Zähle nach \
und kürze, wenn du drüber liegst – lieber eine Geschichte streichen als alle \
hetzen.

Stil: wie eine charismatische Podcast-Hosterin, die unterhält – lebendig, \
mit Persönlichkeit, Augenzwinkern und pointierter Einordnung, nie trocken. \
Erzähle die News als zusammenhängende Geschichte mit eleganten Übergängen.

Das Wichtigste: KEINE Info-Bombe. Du musst nicht jede News unterbringen. \
Nimm die 4-6 spannendsten Geschichten und erzähle sie richtig – mit Kontext, \
warum es interessant ist und was es bedeutet. Den Rest kannst du in einem \
Satz zusammen abfrühstücken oder ganz weglassen. Qualität vor Vollständigkeit.

Außerdem:
- KEINE Quellen oder Artikelnamen nennen (kein "laut TechCrunch", kein \
"in einem Artikel namens..."), keine URLs, keine Punktezahlen
- ZEITNEUTRALE Begrüßung und Verabschiedung – kein "Guten Morgen", denn \
man weiß nicht, wann gehört wird ("Schön, dass du da bist", "Hi, hier ist \
dein Tech-Update" o.ä.)
- Direkte Ansprache ("du"), kurze gesprochene Sätze
- Keine Regieanweisungen, keine Aufzählungszeichen, kein Jingle-Text

{lang_instruction}

Antworte nur mit dem Sprechtext.

{digest}"""

# ---------------------------------------------------------------- News holen


def fetch_rss(url: str, source_name: str) -> list[dict]:
    feed = feedparser.parse(url)
    cutoff = datetime.now(timezone.utc) - timedelta(hours=MAX_AGE_HOURS)
    items = []
    for e in feed.entries[:MAX_ITEMS_PER_SOURCE]:
        published = None
        for key in ("published_parsed", "updated_parsed"):
            if getattr(e, key, None):
                published = datetime(*getattr(e, key)[:6], tzinfo=timezone.utc)
                break
        if published and published < cutoff:
            continue
        items.append({
            "title": e.get("title", "").strip(),
            "url": e.get("link", ""),
            "source": source_name,
        })
    return items


def fetch_hackernews(min_points: int = 80) -> list[dict]:
    r = requests.get(
        "https://hn.algolia.com/api/v1/search",
        params={"tags": "front_page", "hitsPerPage": 30},
        timeout=20,
    )
    r.raise_for_status()
    return [
        {
            "title": hit["title"],
            "url": hit.get("url") or f"https://news.ycombinator.com/item?id={hit['objectID']}",
            "source": "Hacker News",
        }
        for hit in r.json()["hits"]
        if hit.get("points", 0) >= min_points
    ]


def dedupe(items: list[dict]) -> list[dict]:
    seen, out = set(), []
    for it in items:
        key = re.sub(r"\W+", "", it["title"].lower())[:60]
        if key and key not in seen:
            seen.add(key)
            out.append(it)
    return out


# ---------------------------------------------------------------- Claude API


def claude(prompt: str, max_tokens: int = 6000) -> str:
    import anthropic

    client = anthropic.Anthropic()  # nutzt ANTHROPIC_API_KEY
    msg = client.messages.create(
        model=CLAUDE_MODEL,
        max_tokens=max_tokens,
        messages=[{"role": "user", "content": prompt}],
    )
    return msg.content[0].text


def build_digest(items: list[dict], lang: str = "de") -> dict:
    listing = "\n".join(f"- {i['title']} ({i['source']}) {i['url']}" for i in items)
    raw = claude(DIGEST_PROMPT.format(
        items=listing, count=DIGEST_ITEM_COUNT, today=date.today().isoformat(),
        lang_instruction=LANG_INSTRUCTION.get(lang, LANG_INSTRUCTION["de"]),
    ))
    raw = re.sub(r"^```(json)?|```$", "", raw.strip(), flags=re.MULTILINE).strip()
    try:
        return json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"JSON kaputt ({e}) – lasse Claude reparieren …", file=sys.stderr)
        fixed = claude(
            "Dieses JSON ist invalide (vermutlich unescapte Anführungszeichen). "
            "Repariere es und antworte NUR mit dem validen JSON, ohne Codeblock:\n\n" + raw
        )
        fixed = re.sub(r"^```(json)?|```$", "", fixed.strip(), flags=re.MULTILINE).strip()
        return json.loads(fixed)


# ---------------------------------------------------------------- ElevenLabs


def eleven_headers() -> dict:
    key = os.environ.get("ELEVENLABS_API_KEY")
    if not key:
        sys.exit("ELEVENLABS_API_KEY fehlt (https://elevenlabs.io → Profile → API Keys)")
    return {"xi-api-key": key}


def find_voice_id(name: str) -> str:
    """Sucht die Voice-ID per Name in der Voice Library des Accounts."""
    r = requests.get("https://api.elevenlabs.io/v1/voices",
                     headers=eleven_headers(), timeout=20)
    r.raise_for_status()
    voices = r.json()["voices"]
    target = name.lower()
    for v in voices:  # exakter Treffer zuerst
        if v["name"].lower() == target:
            return v["voice_id"]
    for v in voices:  # sonst Präfix, z.B. "Bella - Professional, Bright, Warm"
        if v["name"].lower().startswith(target):
            return v["voice_id"]
    available = ", ".join(v["name"] for v in voices)
    sys.exit(f"Stimme '{name}' nicht gefunden. Verfügbar: {available}\n"
             f"Tipp: Bella in der ElevenLabs Voice Library zu 'My Voices' hinzufügen.")


def build_audio(digest: dict, out_path: Path, lang: str = "de") -> None:
    script = claude(PODCAST_PROMPT.format(
        digest=json.dumps(digest, ensure_ascii=False),
        lang_instruction=LANG_INSTRUCTION.get(lang, LANG_INSTRUCTION["de"])))
    words = len(script.split())
    print(f"Podcast-Skript: {words} Wörter (~{words / 145:.1f} Min)")
    (out_path.with_suffix(".txt")).write_text(script, encoding="utf-8")

    voice_id = find_voice_id(ELEVEN_VOICE_NAME)
    r = requests.post(
        f"https://api.elevenlabs.io/v1/text-to-speech/{voice_id}",
        headers={**eleven_headers(), "Content-Type": "application/json"},
        json={
            "text": script,
            "model_id": ELEVEN_MODEL,
            "voice_settings": ELEVEN_VOICE_SETTINGS,
        },
        timeout=300,
    )
    if not r.ok:
        sys.exit(f"ElevenLabs-Fehler {r.status_code}: {r.text}\n"
                 "Tipp: API-Key-Permissions prüfen (Text to Speech muss aktiviert sein).")
    out_path.write_bytes(r.content)


# ---------------------------------------------------------------- Main


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", action="store_true", help="zusätzlich MP3 mit ElevenLabs erzeugen")
    args = parser.parse_args()

    sources = json.loads(SOURCES_FILE.read_text(encoding="utf-8"))
    items: list[dict] = []
    for s in sources["rss"]:
        try:
            items += fetch_rss(s["url"], s["name"])
        except Exception as e:
            print(f"WARN {s['name']}: {e}", file=sys.stderr)
    items += fetch_hackernews(sources.get("hn_min_points", 80))
    items = dedupe(items)
    print(f"{len(items)} Stories gesammelt")

    OUT_DIR.mkdir(exist_ok=True)
    for lang in LANGUAGES:
        digest = build_digest(items, lang=lang)
        out_json = OUT_DIR / f"digest_{lang}.json"

        # JSON sofort schreiben – ein Audio-Fehler soll den Digest nicht kosten
        digest["audio_file"] = None
        out_json.write_text(json.dumps(digest, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"Digest ({lang}): {out_json}")

        if args.audio:
            try:
                audio_path = OUT_DIR / f"digest_{lang}.mp3"
                build_audio(digest, audio_path, lang=lang)
                digest["audio_file"] = audio_path.name
                out_json.write_text(json.dumps(digest, ensure_ascii=False, indent=2), encoding="utf-8")
                print(f"Audio ({lang}): {audio_path}")
            except SystemExit as e:    # Audio-Fehler darf den Digest nicht kosten
                print(f"WARN Audio ({lang}) fehlgeschlagen: {e}", file=sys.stderr)
            except Exception as e:
                print(f"WARN Audio ({lang}) fehlgeschlagen: {e}", file=sys.stderr)

        # Abwärtskompatibilität: deutsche Version zusätzlich als digest.json/.mp3
        if lang == "de":
            (OUT_DIR / "digest.json").write_text(
                json.dumps(digest, ensure_ascii=False, indent=2), encoding="utf-8")
            mp3 = OUT_DIR / "digest_de.mp3"
            if mp3.exists():
                (OUT_DIR / "digest.mp3").write_bytes(mp3.read_bytes())
    return 0


if __name__ == "__main__":
    sys.exit(main())
