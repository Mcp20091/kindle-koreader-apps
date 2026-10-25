# Setting up the services

Most of the apps work straight away. A few connect to something else, and need a one-time setup first: a Microsoft app ID for To Do and OneNote, your Home Assistant's address, a key for the AI features, and the Syncthing program. This chapter gathers what each one needs and where to get it, and what you get without it (**If you skip it**, at the end). **Settings > Set up your Kindle** (on the launcher, **⋮ > Settings**) walks through the same steps on the Kindle, and you can skip any of them: each step says what skipping it means, and the last page lists what was skipped.

## Before you start

- **A jailbroken Kindle Scribe with KOReader.** The jailbreak wizard at kindlemodding.org (kindlemodding.org/jailbreak-wizard.html) finds the right jailbreak for your Kindle and its software version, and links to installing KOReader. These apps aren't made by or affiliated with kindlemodding.org or the KOReader project, and jailbreaking is at your own risk.
- **The plugins.** Download **kindle-plugins.zip** from the Releases page of github.com/Mcp20091/kindle-koreader-apps, unzip it, and copy the plugin folders into KOReader's `plugins` folder on the Kindle (`koreader/plugins/`, over USB), then restart KOReader. You can leave out apps you don't want (Crosswords needs Notes). Later versions come the same way, and install from the web page without the USB cable (see Updating the plugins in Getting started).
- Wi-Fi on the Kindle, for everything in this chapter.

## Microsoft (To Do and OneNote)

To Do and Notes' OneNote sync use Microsoft's own services, and Microsoft needs to know which app is asking. You make that app once, for free, and get an **App ID**. The Kindle has one Microsoft account for both: one App ID and one sign-in, in the launcher's **Settings > Microsoft**.

You can skip this for To Do: without signing in it keeps lists on the Kindle only, and you can move them to Microsoft To Do later.

**You need a Microsoft directory (a "tenant").** Registering an app happens in a Microsoft Entra directory. A work or school account already has one. A personal Microsoft account (Outlook.com, Hotmail, Xbox, or a personal Microsoft 365 subscription) usually doesn't: create a free Azure account with that personal account at azure.microsoft.com/free first, which sets one up for you. Microsoft asks for a phone number and a card to check who you are, and registering an app doesn't cost anything.

**Make the app:**

1. Sign in at portal.azure.com (or entra.microsoft.com) and open **App registrations** (search for it at the top), then **New registration**.
2. **Name**: anything, such as "Kindle".
3. **Supported account types**: choose **Accounts in any organizational directory and personal Microsoft accounts**, so both a personal and a work account can sign in. (**Personal Microsoft accounts only** works too, for a personal account.) This can't be changed later.
4. **Redirect URI**: leave it empty. Then tap **Register**.
5. Under **Authentication**, set **Allow public client flows** to **Yes**, and **Save**. (The Kindle signs in with a code you type on your phone or computer, which needs this.)
6. Under **API permissions**, tap **Add a permission > Microsoft Graph > Delegated permissions**, and add **Tasks.ReadWrite** (for To Do) and **Notes.ReadWrite** (for OneNote). With a personal account there's nothing to approve here: you agree when you sign in.
7. On the app's **Overview** page, copy the **Application (client) ID**. That's the App ID.

**Use it:**

- In the launcher's **Settings > Microsoft** (or **Set up your Kindle > Microsoft**, or the **Microsoft account** card on the web page's To Do or Notes tab), enter the **App ID**, then **Sign in**: the Kindle shows a code; enter it at the address it shows, on your phone or computer. One sign-in covers To Do and OneNote.
- The page then shows **Signed in as** and your account, and under **USED BY** whether each app is **Allowed**. An app added later, or a sign-in from before both used it, says **Sign in again to allow**: signing in once more covers it.
- To Do's and OneNote's own settings have a **Microsoft account** row that opens the same page.

Renaming the app later is fine. Deleting it, or turning off **Allow public client flows**, stops the sign-in.

## Home Assistant

Nothing needs changing in Home Assistant. The Kindle only needs to reach it:

- **Internal URL**: the address on your home Wi-Fi, such as `http://homeassistant.local:8123` or `http://192.168.1.50:8123`.
- **External URL (optional)**: an address that works away from home, such as a Home Assistant Cloud (Nabu Casa) address or your own. An address behind a sign-in page of its own (a proxy that asks for a password before Home Assistant) won't work.

Then sign in, one of two ways:

- **Sign in with Home Assistant**: its own sign-in page, with two-step codes if you use them. The Kindle then shows up in Home Assistant under your profile > **Security** (where you can remove it).
- **A long-lived access token**: in Home Assistant, open your profile > **Security** > **Long-lived access tokens** > **Create token**, and copy it. Paste it on the web page's Home Assistant tab (easiest), or copy it to the Kindle as a text file and use **Load from file**.

The Kindle sees what your Home Assistant user can see. To show fewer devices, hide them in the app (**Devices**) rather than in Home Assistant.

## AI (Notes and Crosswords)

Reading handwriting, Ask, Make PDF, drawing help and the crossword hints and checks use an AI. Pick one in the launcher's **Settings > AI** (Notes' and Crosswords' **AI settings** rows open it too), under **AI services**; every app uses the same. Each needs a key or an address:

- **Claude**: an API key from platform.claude.com (an Anthropic account with API credit).
- **Gemini**: a key from aistudio.google.com. Gemini Flash and Flash-Lite have a free tier.
- **OpenRouter**: a key from openrouter.ai. **openrouter/free** picks a free model; others are paid.
- **Groq**: a key from console.groq.com.
- **Local AI (Ollama)**: your own computer running Ollama with a model that reads pictures. Ollama has to accept connections from the network (set `OLLAMA_HOST=0.0.0.0` on that computer). Enter its address and port as the **Internal URL**, such as `http://192.168.1.50:11434`. To use it away from home too, add an **External URL** (and an **API key** if it needs one); the AI chapter says what works there.
- **Custom**: any other service with an OpenAI-compatible API: its address, key and model.

On free tiers, the service may use what you send to improve its products. Keep private pages on Claude, a paid tier, or a local AI. The AI chapter has the details.

## Syncthing

The Syncthing app runs the Syncthing program, which isn't included (it's large, and made for each kind of device). Get it once:

1. On a computer, run `syncthing.koplugin/tools/fetch-syncthing.sh`. It downloads the Syncthing release for the Kindle (ARM) and puts the `syncthing` program in the plugin's folder.
2. Copy `syncthing.koplugin` (with the program in it) to the Kindle, as with the other plugins.

Then pair it with Syncthing on your computer or phone: see the Syncthing chapter (Setting it up).

## SSH

The SSH app needs nothing on the Kindle. The device you connect to needs an SSH server (most Linux machines and a Raspberry Pi have one; on Windows, add **OpenSSH Server** in Settings > System > Optional features; on a Mac, turn on **Remote Login**). For signing in with a key instead of a password, add the Kindle's public key to that device: see the SSH chapter (Keys).

## Weather

Nothing to sign up for. Without Home Assistant, the launcher's **Weather** tile uses Open-Meteo, a free forecast that needs no account or key: tap the tile (or Settings > Launcher > WEATHER > **Place**), type your town or city and pick it from the matches. In the US, weather alerts come from the National Weather Service, also free. Both need Wi-Fi to update; the last forecast stays for when it's off. With Home Assistant, its weather is used instead (Settings > Launcher > WEATHER > **Weather from** to choose).

## Library

Nothing to sign up for. Set up your Kindle asks once how to browse your books: **The Library** (covers, what you're reading, authors, collections and folders, in the apps' design) or **KOReader's file browser** as KOReader has it. Change it later in Library settings > **Browse books with**. Covers and titles come from KOReader's Cover browser plugin and reading time from its Reading statistics plugin, so leave those two on.

## Wikipedia and Crosswords

Nothing to set up: Wikipedia and the crossword sources are free and need no account. Crosswords needs the Notes plugin installed.

## If you skip it

Every service is optional, and each app only needs its own, so any mix works. Without one:

- **Wi-Fi**: reading, Notes, the crosswords you already have, reading statistics and lists on this Kindle all work. Syncing, downloads, Home Assistant and the AI wait until Wi-Fi is on.
- **Home Assistant**: its tile opens the sign-in. The **Dashboard** tile stays hidden until it's set up, and the launcher's weather can come from Open-Meteo instead. Nothing else needs it.
- **Microsoft (To Do)**: To Do works on its own with lists kept on this Kindle: due dates, reminders, repeats, steps, the sleep screen, the launcher's tile and At a glance. Only syncing with Microsoft To Do needs the App ID and sign-in; sign in later and you can move those lists to To Do.
- **Microsoft (OneNote)**: Notes works fully; only sending to and getting from OneNote needs it.
- **AI**: Notes and Crosswords work fully without it, and their AI buttons and menu items are left out until a service is set up (**Settings > AI** shows which services are set up, and Notes' and Crosswords' **AI settings** rows lead there). Search still finds typed text and handwriting already read.
- **Weather**: with neither Home Assistant nor a place set, At a glance and the sleep screen leave the weather out, and the Weather tile asks for your town.
- **Library**: the Library is used to browse books; Library settings > **Browse books with** switches to KOReader's file browser.
- **Syncthing**: nothing else needs it. Copy books over USB or with the web page instead.
- **SSH**: nothing else needs it.
- **The web page's password**: the page still works, but anyone on your Wi-Fi can open it while the web server runs. Start it only when you need it, or set a password.

A fresh install with nothing set up starts without errors: each app shows what it needs, in plain words, the first time you open it.
