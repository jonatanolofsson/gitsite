# gitsite

En byggcontainer som följer ett git-repo, bygger om när något landat och lägger
resultatet i en katalog. Samma image för alla sajter — skillnaden ligger i
konfigurationen.

Den ersätter mönstret där en sajt byggs som en bieffekt av utvecklingsmiljön:
då dör sajten när utvecklingspodden startar om, den byggs bara vid podstart,
och det som publiceras är arbetsträdet — ocommitterat och allt.

## Vad den gör, och inte gör

**gitsite bygger. Den servar inte.** Containern klonar, bygger och skriver
resultatet till `/work/site`. Att exponera den katalogen på HTTP är någon
annans jobb — en webbserver i samma pod, en sidovagn, en volym som en befintlig
server läser. Vi kör den med `nginx-unprivileged` i samma pod, men ingenting i
containern förutsätter just det.

Den vet inte heller något om autentisering. Vad som står framför webbservern —
en identity-proxy, basic auth, eller ingenting — är ditt val.

## Förutsättning: appens repo måste ha nix och direnv

Bygget körs som `direnv exec . <build>` i det klonade repot. Det förutsätter
att repot har en `.envrc` och normalt en `flake.nix`.

Skälet är att byggkommandon i praktiken anropar bara kommandonamn — `hugo`,
`mkdocs build`, `python -m mysite` — som förutsätter en miljö någon redan satt
upp. `nix develop -c` räcker inte när `.envrc` också gör något (installerar
Python-beroenden, lägger `.venv/bin` på PATH); direnv gör allt.

**Ett repo utan `.envrc` kan alltså inte byggas av gitsite i dag.** Vill du
använda den till ett vanligt hugo- eller npm-projekt behöver du lägga till en
`.envrc` som sätter upp verktygen, eller ändra runnern så att den kan hoppa
över direnv. Det senare tas gärna emot som en PR.

## Konfigurationen är delad

**Infrastrukturen äger** vilket repo som gäller, via miljövariabler:

| Variabel | Förval | Betydelse |
|---|---|---|
| `GITSITE_REPO` | *(krävs)* | klon-URL, normalt SSH med en read-only deploy key |
| `GITSITE_REF` | `main` | grenen som följs |
| `GITSITE_INTERVAL` | `120` | sekunder mellan pollningarna |
| `GITSITE_SSH_KEY` | `/etc/gitsite/ssh` | privatnyckeln; saknas den antas anonym remote |
| `GITSITE_WORK` | `/work` | klonen och den byggda sajten (`$GITSITE_WORK/site`) |
| `HOME` | *(krävs)* | skrivbar och beständig; direnv, uv och nix cachar där |
| `TMPDIR` | `$GITSITE_WORK/tmp` | nix bygger devskalet här; lägg det på volymen, inte i containern |

`HOME` **måste** sättas och peka någonstans skrivbart — runnern avbryter
direkt annars. Imagen sätter `HOME=/home/gitsite`, vilket fungerar men ligger i
containerns eget lager: sätt den till något beständigt, annars hämtas alla
beroenden om vid varje omstart.

**Appen äger** hur den byggs, i en `gitsite.toml` i repots rot:

```toml
build = "just build"     # kommandot som producerar sajten
out   = "public"         # katalogen det lägger resultatet i, relativt repots rot
lfs   = false            # kör git lfs pull före bygget
```

`out` måste peka på en katalog **under** repots rot. Sökvägen kanoniseras med
`realpath` innan den godtas, så `.`, `./`, `..`, absoluta sökvägar och
symlänkar som pekar ut ur katalogen avvisas — annars hade `out = "."`
publicerat hela checkouten inklusive `.git`, och därmed appens hela historik.
`.git` avvisas separat, som sökvägskomponent: `site/.github` är tillåtet.

Kontrollen körs innan bygget, så ett felaktigt värde kostar inte ett bygge per
pollvarv. Det som publiceras är katalogens *innehåll*, aldrig katalogposten
själv — annars hade en symlänkad utkatalog blivit en symlänk i den servade
katalogen.

En symlänk *inuti* utkatalogen följer med som den är. Vill du hindra att den
följs är det webbservern som avgör: `disable_symlinks on;` i nginx.

Att byggkommandot bor i appen är avsiktligt: den som byter utkatalog ändrar
filen i samma commit som orsakar bytet. Priset är att ett trasigt byggkommando
upptäcks först i containern — därför behandlas en saknad eller ogiltig
`gitsite.toml` som ett byggfel, och den förra sajten står kvar.

## Kom igång

```bash
docker run --rm \
  -e GITSITE_REPO=https://github.com/dig/din-sajt.git \
  -e HOME=/work/home \
  -v gitsite-data:/work \
  ghcr.io/jonatanolofsson/gitsite:latest
```

Sajten hamnar i `/work/site`. Peka en webbserver på den katalogen — **inte på
en montering av den**, se nedan.

Första bygget tar minuter, inte sekunder: nix hämtar appens beroenden och
cachar dem i `HOME` och `/nix`.

## Vad som är garanterat

- **Ett misslyckat bygge tar aldrig ner sajten.** Förra versionen står kvar och
  runnern försöker igen nästa varv.
- **Ett tomt pollvarv kostar ett nätanrop.** `git ls-remote` jämförs mot senast
  byggda commit; först vid skillnad hämtas något.
- **Något finns i katalogen från första sekunden.** Innan det första bygget är
  klart ligger en enkel "bygger…"-sida där, så att en webbserver inte svarar
  403 på en tom katalog.

## Kända begränsningar

- **Publiceringen är inte atomär i strikt mening.** Bygget sker vid sidan om
  och katalogen byts med två `mv` — mellan dem finns ett kort glapp där
  `site/` inte existerar. Dör containern precis där ligger bygget kvar som
  `site.new` och nästa varv publicerar om.
- **Montera inte `site/` direkt.** Bytet ersätter katalogens inode, så en
  bind-montering av just `site/` fortsätter peka på den gamla och servar första
  bygget för alltid. Montera föräldern och låt webbservern lösa sökvägen per
  förfrågan.
- **Byggkommandot kommer från appens repo och körs som det står.** Den som kan
  pusha till app-repot kan köra godtycklig kod i containern. Det är oundvikligt
  — ett bygge *är* godtycklig kod — men det är skälet att deploy-nyckeln bör
  vara read-only och per repo, och att containern inte bör ha några andra
  rättigheter.
- Ett repo utan `.envrc` stöds inte, se ovan.

## Utveckling

```
just check     # lint + test
just test      # bara testerna
just lint      # shellcheck
```

Testerna kör utan ramverk och stubbar `git`, `direnv` och `nix`. Tyngdpunkten
ligger på felvägarna: att ett trasigt bygge behåller förra sajten, att en
ogiltig `gitsite.toml` inte publiceras, och att `out` inte kan peka ut ur
repot.

Verktygen deklareras i `flake.nix` så att `just check` fungerar i varje miljö,
inte bara där en python råkar vara installerad. CI kör exakt samma `just check`
genom samma nix-skal.

## Licens

MIT, se [LICENSE](LICENSE).
