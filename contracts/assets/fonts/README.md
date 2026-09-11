# Shared native fonts

These TTF containers carry the exact approved web font outlines and names; native clients require a TTF container. Source WOFF2 files remain authoritative. Conversion changes the container, with `TTFont(recalcTimestamp=False)`, `flavor=None`, then `save()`.

Build tooling: `fonttools==4.65.0`, `brotli==1.2.0`. Open each source with `TTFont(source, recalcTimestamp=False)`, assign `font.flavor = None`, then `font.save(destination)`. These are preparation tools, not runtime dependencies.

| File | SHA-256 |
| --- | --- |
| `backend/webrender/static/fonts/inter-latin.woff2` | `3100e775e8616cd2611beecfa23a4263d7037586789b43f035236a2e6fbd4c62` |
| `backend/webrender/static/fonts/jetbrains-mono-latin.woff2` | `14425ba9c695763c1547f48a206b7aa60350a33ae23de09f0407877f3fcd89eb` |
| `contracts/assets/fonts/inter-latin.ttf` | `0c32b5264a085067f4247b17d93324c7f3a536086ea42130a14a92004b7224e5` |
| `contracts/assets/fonts/jetbrains-mono-latin.ttf` | `b5b13dd9693e868ffc4376172fedca4dc40e34edb443f766d24e32e633caa09b` |

License notices: [Inter](https://raw.githubusercontent.com/rsms/inter/master/LICENSE.txt) and [JetBrains Mono](https://raw.githubusercontent.com/JetBrains/JetBrainsMono/master/OFL.txt), both SIL Open Font License 1.1; full notices are included beside the fonts. Inter retains family `Inter`, PostScript `Inter-Regular`, weight axis 100–900. JetBrains retains `JetBrains Mono`, PostScript `JetBrainsMono-Regular`. No names have changed.
