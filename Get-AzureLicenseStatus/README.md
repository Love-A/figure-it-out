
# Azure License Monitoring Script

We (me and ChatGPT) put together a script to extract our Azure license information — how many we have, how many are assigned, and whether anything has changed, such as a SKU being added or removed.

---

## ⚙️ Key Features
- 🔐 Secure authentication via Azure App + certificate  
- 📊 Report export (CSV, HTML)  
- 🧠 Smart difference comparison against previous run  
- 📩 Teams notifications *only* when changes occur  
- 🧪 Simulated alert mode using `-TestMode`  
- 💾 JSON cache for comparison history  

Perfect for IT organizations that want control, insight, and early warnings — without getting overwhelmed by noise.

---

## 🗓️ Log Example
```
[2025-06-23 11:15:10] [INFO] Connecting to Microsoft Graph...
[2025-06-23 11:15:12] [INFO] Connected to Microsoft Graph.
[2025-06-23 11:15:16] [INFO] License summary exported to AzureLicenseSummary.csv.
[2025-06-23 11:15:16] [INFO] License summary exported to AzureLicenseSummary.html.
[2025-06-23 11:15:16] [INFO] License status unchanged. Skipping notification.
[2025-06-23 11:15:16] [INFO] Will notify on @{SkuPartNumber=O365_w/o_Teams_Bundle_M5; TotalLicenses=xxx; AssignedLicenses=xxx; AvailableLicenses=x; DisplayName=Office 365 without Teams (bundle M5)}.SkuPartNumber - Available: x
[2025-06-23 11:15:16] [INFO] licensesToNotify.Count = 
[2025-06-23 11:15:16] [INFO] changeDetails.Count = 0
```

---

## 📄 Prerequisites for Running the Script
The script uses **client credential flow** with a certificate for secure authentication against Microsoft Graph.

1. **Create an App Registration** in Azure AD
2. **Assign the Following API Permissions** (Application permissions):
   - `Organization.Read.All`
   - `Directory.Read.All`
3. **Upload a Public X.509 Certificate (CER)** to the App
4. **Note the Following Values**:
   - `Client ID (AppId)`
   - `Tenant ID (TenantId)`
   - `Certificate Thumbprint (Thumbprint)`

> 📌 These three are used as script parameters.

5. **Certificate Installation**  
   The certificate must be installed in `CurrentUser\My` or `LocalMachine\My` on the client/server where the script is executed.

```powershell
-Thumbprint "XXXX..." -AppId "XXXX..." -TenantId "XXXX..."
```

---

## ⚖️ How It Works
The script retrieves license data using `Get-MgSubscribedSku` and creates a current-state snapshot in the form of:

- 📊 HTML report
- 📄 CSV export
- 💾 JSON cache

It then compares the current state to the previous run and triggers a notification flow if any of the SKUs specified via the `NotifySku` parameter are:

- Out of licenses
- Running low
- Have changed in quantity

---

## 🚀 Recommended Setup
We suggest scheduling the script as a **Scheduled Task**, ideally running under a **Group Managed Service Account (gMSA)**. Alternatively, Azure Automate can also be used, if you know how to work that..

In our case, we created a dedicated **Azure App Registration** that the task calls. It’s granted read permissions, which is why `AppId`, `TenantId`, and `Thumbprint` are required.

We liked that this approach doesn’t rely on a user account — it just felt cleaner.

---

## 🧑‍💼 Monitoring & Notifications
We ended up with what we think is a pretty nifty little monitoring solution for our Azure license status.

Here's what the notification flow looks like if you want changes reported to a **Teams channel or direct chat**.
<img width="475" alt="image" src="https://github.com/user-attachments/assets/34a331cc-f3ef-421c-820b-862d40dfaaa5" />

<img width="474" alt="image" src="https://github.com/user-attachments/assets/ad51d428-8f2e-48ce-90e2-dd99b47fe689" />

> 📆 The flow includes a condition called `non-weekend`, which skips direct notifications on Saturdays and Sundays to avoid disturbing people during the weekend. (Checking for bank holidays is a bit trickier.)

---

## 🎩 Friendly License Names (`$friendlyNames`)
When fetching license data via Microsoft Graph, the returned SKU part numbers can be cryptic and unclear. To improve readability in both the report and Teams notifications, we use a friendly name mapping table like this:

```powershell
$friendlyNames = @{
    "ENTERPRISEPACK" = "M365 E3"
    "EMS" = "Enterprise Mobility + Security"
    "SPE_E5" = "Microsoft 365 E5"
    "VISIOCLIENT" = "Visio Plan 2"
    "PROJECTPREMIUM" = "Project Plan 3"
}
```

> 📝 You can define this mapping inline in the script, or...

### ✨ ...If You're Really Cool
You’d probably externalize this mapping into a `.json` file next to the script so you don't have to edit the script directly when new SKUs are introduced.

---

## ⚙️ Get All SKUs in Your Tenant
To retrieve all available SKU part numbers in your tenant:

```powershell
$licenses = Get-MgSubscribedSku

$summary = foreach ($lic in $licenses) {
    [PSCustomObject]@{
        SkuPartNumber     = $lic.SkuPartNumber
        TotalLicenses     = $lic.PrepaidUnits.Enabled
        AssignedLicenses  = $lic.ConsumedUnits
        AvailableLicenses = $lic.PrepaidUnits.Enabled - $lic.ConsumedUnits
    }
}
```

---

## 🔄 The Flow
I didn’t really have the energy to clean up the exported files from the flow setup — so if you're curious about how the notification flow is configured, just reach out and I’ll be happy to walk you through it.

> 📰 **Spoiler:** It’s honestly quite simple — most of the setup is done directly through the **Teams Workflow UI**.

---

Happy licensing ✌️

/ Love A
