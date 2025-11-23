
# Företagsmapp-struktur för enskilda företag

Detta PowerShell-skript skapar en logisk, arkivvänlig och revisorsvänlig mappstruktur för ett enskilt företag. Strukturen är utformad för att hantera fakturor, kvitton, avtal, bankdokument, bokföring och övriga administrativa dokument.

## Funktioner
- Skapar årsmappar (t.ex. 2025).
- Skapar huvudkategorier: Fakturor, Administration, Bank-Betalningar, Avtal, Skatt-Moms, Löneadministration, Bokföring, Rapporter-Årsbokslut.
- Skapar undermappar och månadsmappar (Fakturor & Kvitton).
- Loggar alla skapade mappar i FolderSetup_<år>.log.
- Flexibel med år som variabel.
- Frågar användaren efter basmapp.

## Användning
1. Öppna PowerShell.
2. Navigera till mappen där skriptet ligger.
3. Kör skriptet:
```powershell
.\New-CompanyFolderStructure.ps1
```
4. Ange basmapp och år när skriptet frågar.

## Tips
- Använd YYYY-MM-DD i filnamn för fakturor/kvitton.
- Undvik mellanslag i filnamn, använd - eller _.
- Backup: Kopiera hela basmappen till extern disk eller moln.
- Strukturen är revisorsvänlig och lätt att navigera.
