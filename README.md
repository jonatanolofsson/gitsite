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
| `GITSITE_EAGER_INTERVAL` | `5` | pollintervall medan en knuff är aktiv, se nedan |
| `GITSITE_EAGER_WINDOW` | `120` | hur länge en knuff håller i sig, sekunder |

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

## Knuffa den när du vet att något kommit

`SIGHUP` till byggaren betyder *en push är på väg*. Runnern går då över till att
polla var `GITSITE_EAGER_INTERVAL` sekund i `GITSITE_EAGER_WINDOW` sekunder, och
stänger fönstret så snart något faktiskt publicerats.

```bash
kubectl -n gitsite exec deploy/gitsite-<sajt> -c builder -- kill -HUP 1
```

**Varför ett fönster och inte en enda pollning?** Därför att git saknar
post-push-hook. Den enda klienthook som ligger nära en push är `pre-push`, och
den kör *innan* objekten överförts. En knuff därifrån som utlöste exakt ett
`ls-remote` skulle nästan alltid se commiten före den man pushar, inte göra
något, och lämna ändringen att vänta ut hela det vanliga intervallet ändå —
triggern hade sett ut att fungera utan att köpa något. Ett fönster gör knuffen
okänslig för den kapplöpningen: pushen landar inom sekunder och nästa snabbvarv
tar den.

Knuffen är en vink, aldrig en order. Ingenting i den publicerar något som den
vanliga pollningen inte hade publicerat en minut senare, så en förlorad knuff
gör sajten sen — inte fel. Ett `pre-push` som knuffar bör därför aldrig kunna
stoppa en push.

En detalj värd att känna till om man ändrar i runnern: `sleep N` går inte att
avbryta. Bash kör en trap först när förgrundskommandot returnerat, så en signal
under en vanlig sleep verkar upp till ett helt intervall för sent. Sleepen körs
därför i bakgrunden med `wait`. Att trapen finns spelar också roll i sig:
byggaren är PID 1, och kärnan levererar inte signaler till PID 1 som saknar
handler.

## Att se om den mår bra

Garantin ovan har en baksida: **ett bygge som misslyckas varje varv syns inte
utifrån.** Sajten svarar 200 med förra veckans innehåll och ser fullt frisk ut.
Därför skriver runnern `$GITSITE_WORK/status.json` efter varje varv:

```json
{"state":"failing","ref":"main","attempted":"9f2c…","published":"4a71…",
 "consecutive_failures":7,"last_attempt":"2026-08-26T16:12:04Z",
 "last_success":"2026-08-24T09:31:55Z"}
```

`state` är `ok`, `failing`, `unreachable` eller `starting`. Filen ligger
**utanför** den servade katalogen — bytet ersätter den katalogen i sin helhet,
och statusen angår driften, inte besökaren.

Den bär medvetet ingen feltext. Orsaken står i loggen, som ändå läses när något
är fel; att kopiera in byggutdata i en statusfil betyder att vad bygget än
skrev — sökvägar, tokens, någon annans felmeddelande — hamnar någonstans det
aldrig granskats för.

Det billigaste larmet är på loggen, som skriver en räknare just för det:

```
keeping the previous site (failed 7 in a row)
```

En enstaka etta är en trasig commit som lagar sig själv. Ett tvåsiffrigt tal är
en deploy ingen tittat på. Larma på det andra, inte på det första.

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
- **Lägger du `/nix` på en volym som överlever imagen — slå ihop, seeda inte.**
  Imagens `$HOME/.nix-profile` ligger i containerlagret men symlänkar in i
  `/nix`. Kopierar du bara storen när volymen är tom fastnar den i den version
  som råkade komma först, och en nyare image får ett profilbibliotek utan mål:
  `direnv: command not found` vid varje bygge. `cp -a -n /nix/. <volym>/`
  lägger till det som saknas utan att röra det som finns — säkert eftersom
  store-sökvägar är innehållsadresserade och oföränderliga.

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

Imagen pinnar både nix-versionen och nixpkgs-revisionen (`ARG` överst i
`Dockerfile`). Revisionen är densamma som `flake.lock` — imagens direnv och
utvecklingsskalet kommer ur samma nixpkgs. **Bumpa dem tillsammans**, annars
säger repot en sak och imagen en annan.

## Licens

MIT, se [LICENSE](LICENSE).
