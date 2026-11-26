# Stations are decoded by BitMachine, not played by AVPlayer

AVPlayer would play an internet radio stream, and even surface its ICY titles, in a few lines. But it plays through its own output, so a Station would get none of BitMachine's volume, balance, equalizer or visualizer, the very thing ADR 0003 went out of its way to give Apple Music. Instead BitMachine reads the stream itself: URLSession brings the bytes, BitMachine takes out the ICY metadata, Core Audio's file stream parser and an audio converter decode the MP3 or AAC, and the samples go into the same AudioOutput every Source plays through.

## Consequences

- BitMachine only plays what it decodes: MP3 and AAC (including HE-AAC) streams. HLS, Ogg and Opus Stations are left out of the Station Directory's results rather than shown and failing.
- A stream drop is BitMachine's to handle: it tunes in again a few times, then shows the Station as lost.
- Most Stations stream over plain http from hosts no one can list in advance, so the app allows arbitrary loads under App Transport Security (`project.yml`).
