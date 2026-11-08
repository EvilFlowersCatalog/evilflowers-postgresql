# Stop lists for the Slovak and Czech dictionaries

The Dockerfile copies `*.stop` into `/usr/share/postgresql/<major>/tsearch_data/`
next to the hunspell files. PostgreSQL reads stop lists as one lowercase UTF-8
word per line, with no comments, so the provenance is recorded here and in
`versions.json`.

| File | Source | License |
|---|---|---|
| `slovak.stop` | [stopwords-iso/stopwords-sk](https://github.com/stopwords-iso/stopwords-sk) at `bd3c61983b761f7aed676de3c857313982de123e`, `stopwords-sk.txt`, unchanged | MIT |
| `czech.stop` | [stopwords-iso/stopwords-cs](https://github.com/stopwords-iso/stopwords-cs) at `e93e103f19297e60f69535e41dd216352c363698`, `stopwords-cs.txt`, trimmed (below) | MIT |

The Czech list was collected from web text and contains content words that a
library catalog must keep searchable. These entries were removed:

- web and forum words: `ahoj`, `čau`, `cz`, `design`, `email`, `neg`, `re`, `tipy`,
  `napiste`, `napište`, `děkovat`, `děkujeme`, `děkuji`, `pta`
- nouns and adjectives: `clanek`, `clanku`, `clanky`, `článek`, `článku`, `články`,
  `strana`, `tema`, `téma`, `zpravy`, `zprávy`, `den`, `večer`, `chut'`, `chuti`,
  `dobrý`, `nove`, `novy`, `nové`, `nový`, `prvni`, `první`
- adverbs of place and time: `blízko`, `daleko`, `brzo`, `pozdě`
- numerals: `nula`, `dva`, `dvě`, `tři`, `čtyři`, `pět`, `šest`, `sedm`, `osm`, `devět`,
  `deset`, `jedenáct` … `devatenáct`, `dvacet`, `sto`, `sta`, `sté`, `tisíc`, `tisíce`
- the mangled entry `ted'` (`teď` with an apostrophe)

The ispell template compares the stop list with the *lemma*, not the word as
written, so the lists also stop every inflected form whose lemma they contain.
Keep that in mind before adding a noun.
