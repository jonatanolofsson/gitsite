# gitsite

En generisk container som följer ett git-repo, bygger om när något landat och
servar resultatet. Samma image för alla sajter — skillnaden ligger i
konfigurationen.

Den ersätter mönstret där en sajt byggs och servas som en bieffekt av
utvecklingsmiljön: då dör sajten när utvecklingspodden startar om, den byggs
bara vid podstart, och det som servas är arbetsträdet — ocommitterat och allt.

## Konfigurationen är delad

**Infrastrukturen äger** vilket repo som gäller, via miljövariabler:

| Variabel | Förval | Betydelse |
|---|---|---|
| `GITSITE_REPO` | *(krävs)* | klon-URL, normalt SSH med en read-only deploy key |
| `GITSITE_REF` | `main` | grenen som följs |
| `GITSITE_INTERVAL` | `120` | sekunder mellan pollningarna |
| `GITSITE_SSH_KEY` | `/etc/gitsite/ssh` | privatnyckeln; saknas den antas anonym remote |
| `GITSITE_WORK` | `/work` | klon, HOME och den servade katalogen |

**Appen äger** hur den byggs, i en `gitsite.toml` i repots rot:

```toml
build = "just place && just build"   # kommandot som producerar sajten
out   = "out"                        # katalogen det lägger resultatet i
lfs   = true                         # kör git lfs pull före bygget
```

Att byggkommandot bor i appen är avsiktligt: den som byter utkatalog ändrar
filen i samma commit som orsakar bytet. Priset är att ett trasigt byggkommando
upptäcks först i podden — därför behandlas en saknad eller ogiltig
`gitsite.toml` som ett byggfel, och den förra sajten står kvar.

## Hur bygget körs

Runnern går in i appens **egen** nix-miljö via direnv:

```
direnv allow . && direnv exec . <build>
```

Inte `nix develop`: byggkommandona anropar oftast bara kommandonamn
(`plotdata app`, `python -m markplan.site`) som förutsätter att `.envrc` kört
`uv sync` och lagt `.venv/bin` på PATH. Flaken ensam räcker inte.

Ordningen spelar roll när `lfs = true`: `git-lfs` kommer ur appens flake, så
`git lfs pull` måste köras *efter* att direnv-miljön finns, inte som en del av
klonen.

## Vad som är garanterat

- **Ett misslyckat bygge tar aldrig ner sajten.** Förra versionen står kvar och
  runnern försöker igen nästa varv.
- **Bytet är atomiskt.** Bygget sker vid sidan om och katalogen byts med `mv`,
  så en besökare aldrig ser ett halvskrivet resultat.
- **Ett tomt pollvarv kostar ett nätanrop.** `git ls-remote` jämförs mot senast
  byggda commit; först vid skillnad hämtas något.
- **Något servas från första sekunden.** Innan det första bygget är klart —
  vilket kan ta 10–20 minuter medan beroenden cachas — ligger en enkel
  "bygger…"-sida där, så att nginx inte svarar 403 på en tom katalog.

## Utveckling

```
just check     # lint + test
just test      # bara testerna
just lint      # shellcheck
```

Testerna kör utan ramverk och stubbar `git`, `direnv` och `nix`. Tyngdpunkten
ligger på felvägarna: att ett trasigt bygge behåller förra sajten, att bytet
är atomiskt, och att en ogiltig `gitsite.toml` inte publiceras.

Verktygen deklareras i `flake.nix` så att `just check` fungerar i varje miljö,
inte bara där en python råkar vara installerad.
