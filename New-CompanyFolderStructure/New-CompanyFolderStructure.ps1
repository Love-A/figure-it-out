function New-CompanyFolderStructure {
    param (
        [Parameter(Mandatory=$true)]
        [string]$BasePath,

        [Parameter(Mandatory=$false)]
        [int]$Year = (Get-Date).Year
    )

    # Loggfil
    $LogFile = Join-Path -Path $BasePath -ChildPath "FolderSetup_$Year.log"

    try {
        # Skapa basmappen om den inte finns
        if (-not (Test-Path $BasePath)) {
            New-Item -Path $BasePath -ItemType Directory -Force
            Add-Content -Path $LogFile -Value "$(Get-Date) - Skapade basmappen: $BasePath"
        }

        # År-specifik mapp
        $YearPath = Join-Path -Path $BasePath -ChildPath $Year
        if (-not (Test-Path $YearPath)) {
            New-Item -Path $YearPath -ItemType Directory -Force
            Add-Content -Path $LogFile -Value "$(Get-Date) - Skapade årsmappen: $YearPath"
        }

        # Lista över månader
        $Months = @(
            "01-Januari","02-Februari","03-Mars","04-April","05-Maj","06-Juni",
            "07-Juli","08-Augusti","09-September","10-Oktober","11-November","12-December"
        )

        # Huvudkategorier och undermappar
        $FolderStructure = @{
            "Fakturor" = @("Skickat", "Mottagna", "Betalda", "Obetalda", "Makulerade", "Bestridda")
            "Administration" = @("Jobb-Projekt", "Leverantörsfakturor", "Övrigt")
            "Bank-Betalningar" = @("Konto1", "Konto2")
            "Avtal" = @("Kunder", "Leverantörer", "Övriga")
            "Skatt-Moms" = @("Momsrapport", "Deklarationer", "Skattebesked")
            "Löneadministration" = @("Anställda", "Löneunderlag", "Arbetsgivardeklarationer")
            "Bokföring" = @("Kvitton", "Inköp", "Försäljning", "Övrigt")
            "Rapporter-Årsbokslut" = @("Månatliga rapporter", "Årsbokslut")
        }

        foreach ($MainFolder in $FolderStructure.Keys) {
            $MainPath = Join-Path -Path $YearPath -ChildPath $MainFolder
            if (-not (Test-Path $MainPath)) {
                New-Item -Path $MainPath -ItemType Directory -Force
                Add-Content -Path $LogFile -Value "$(Get-Date) - Skapade mappen: $MainPath"
            }

            foreach ($SubFolder in $FolderStructure[$MainFolder]) {
                # Skapa undermapp
                $SubPath = Join-Path -Path $MainPath -ChildPath $SubFolder
                if (-not (Test-Path $SubPath)) {
                    New-Item -Path $SubPath -ItemType Directory -Force
                    Add-Content -Path $LogFile -Value "$(Get-Date) - Skapade undermappen: $SubPath"
                }

                # Om detta är fakturor eller kvitton, skapa månadsmappar
                if ($MainFolder -eq "Fakturor" -or ($MainFolder -eq "Bokföring" -and $SubFolder -eq "Kvitton")) {
                    foreach ($Month in $Months) {
                        $MonthPath = Join-Path -Path $SubPath -ChildPath $Month
                        if (-not (Test-Path $MonthPath)) {
                            New-Item -Path $MonthPath -ItemType Directory -Force
                            Add-Content -Path $LogFile -Value "$(Get-Date) - Skapade månadsmappar: $MonthPath"
                        }
                    }
                }
            }
        }

        Write-Host "Företagsmapp-strukturen med månadsmappar skapad framgångsrikt under $YearPath"

    } catch {
        $ErrorMsg = "$(Get-Date) - FEL: $_"
        Write-Host $ErrorMsg -ForegroundColor Red
        Add-Content -Path $LogFile -Value $ErrorMsg
    }
}

# Kör funktionen med input från användaren
$BasePathInput = Read-Host "Ange basmapp för företagsdokument (t.ex. C:\Users\DittNamn\Documents\Företag)"
$YearInput = Read-Host "Ange år (lämna blankt för innevarande år)"

if ([string]::IsNullOrWhiteSpace($YearInput)) {
    New-CompanyFolderStructure -BasePath $BasePathInput
} else {
    New-CompanyFolderStructure -BasePath $BasePathInput -Year [int]$YearInput
}
