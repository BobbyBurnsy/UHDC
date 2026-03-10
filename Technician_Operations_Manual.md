# UHDC Technician Operations Manual
**Version:** 1.0.0 | **Audience:** Help Desk & IT Support Staff

## Welcome to the Unified Help Desk Console
The Unified Help Desk Console (UHDC) is your new command center. It is designed to eliminate the friction of modern IT support by aggregating Active Directory, Microsoft Intune, and remote endpoint management into a single, lightning-fast interface. 

Our goal is **Live-Call Remediation**: resolving complex tickets on the first touch without ever putting the user on hold to navigate slow web portals.

---

## 1. Launching the Console
The UHDC runs locally on your machine, acting as a secure bridge between your administrative credentials and the network.

1. Navigate to the central UHDC network share provided by your Systems Administrator.
2. Double-click `Launch-UHDC.cmd`.
3. If prompted, accept the UAC (User Account Control) elevation prompt. The console requires local administrative rights to route network traffic securely.
4. A Microsoft Edge window will open in "App Mode," displaying the UHDC Workspace.

*Note: On your first launch, you may see a brief command prompt window asking you to authenticate to Microsoft Graph. Log in using your standard administrative Entra ID credentials.*

---

## 2. The "No Hostname" Workflow
Traditionally, the first question a technician asks a user is, *"What is your computer name?"* With the UHDC, you no longer need to ask.

1. **Search by Identity:** Click the search bar at the top of the console (or press the `/` key on your keyboard) and type the user's username (e.g., `jsmith`). Press **Enter**.
2. **Instant Correlation:** The UHDC Intelligence Engine will instantly query Active Directory and the background telemetry database.
3. **The Results:**
   * The **Identity Panel** will populate with their AD profile, highlighting critical access groups (like VPN or Finance) and their exact password expiration date.
   * The **Target PC** dropdown will automatically populate with the physical computer they are currently logged into.
4. **Ready to Execute:** With the Target PC auto-filled, all remote tools in the Arsenal are instantly armed and ready to fire.

*Fallback:* If a user is hot-desking or their PC isn't in the local history, the UHDC will automatically pivot to the Cloud (Intune) and then perform a targeted subnet sweep to find them.

---

## 3. The Arsenal: Core Capabilities

### Active Directory Actions
Located in the top-left panel, these actions execute instantly against the Domain Controller.
* **Unlock Account:** Instantly clears the AD lockout flag.
* **Reset Password:** Generates a secure, temporary password, forces the user to change it on their next login, and copies the temporary password to your clipboard.

### Cloud Identity Orchestrator
Click the **Cloud Orchestrator** button in the left sidebar to open the Entra ID / Intune overlay.
* **BitLocker & LAPS:** Select a managed device to instantly retrieve its 48-digit BitLocker recovery key or rotating Local Administrator (LAPS) password.
* **MFA Remediation:** View a user's registered authentication methods, clear broken Microsoft Authenticator links, or inject a new cell phone number for SMS MFA directly into their profile.
* **Device Actions:** Force an Intune policy sync, reboot, or remotely wipe a lost device.

### Endpoint Remediation & Diagnostics
Located in the main grid, these tools execute directly against the user's computer in the background (Session 0), meaning you will not interrupt their workflow.
* **Print Spooler Orchestration:** Safely stops the print service, deletes corrupted print jobs, and restarts the service in under 3 seconds.
* **Chromium Profile Rebuild:** Resets a corrupted Chrome or Edge browser while automatically backing up and restoring the user's local bookmarks.
* **Deep Storage Clean:** Purges the MECM (SCCM) cache, Windows Temp, and triggers a background Disk Cleanup to resolve "out of space" deployment errors.
* **Event Forensics:** Deep-scans the remote computer's Event Viewer for application crashes or blue screens, returning a clean table directly in your dashboard.

---

## 4. Mass Deployment & Custom Scripts
The UHDC allows you to deploy software or run custom PowerShell scripts against dozens of computers simultaneously.

1. Click **Zero-Touch Deploy** or **Custom Scripts**.
2. In the **Target(s)** box, you can type a single computer name, or paste an entire column of computer names directly from an Excel spreadsheet. The console will automatically format them.
3. Select the application or script from the central library and click **Deploy/Run**.
4. **Wake-on-LAN:** If a target computer is powered off, the UHDC will automatically look up its MAC address, send a "Magic Packet" to turn it on, wait 45 seconds, and then deploy the software.

---

## 5. The Interactive Training Engine
If you are a newer technician, your Administrator may have placed your account into **Training Mode**. 

When Training Mode is active, clicking a tool will not execute it immediately. Instead, the console will pause and display a training modal.
* **The "Why":** It explains exactly what the tool is doing behind the scenes.
* **The Code:** It shows you the actual PowerShell or Graph API syntax being used.
* **The In-Person Equivalent:** It translates the remote automation into the physical clicks you would make if you were standing at the user's desk.

Read the prompt, learn the logic, and click **Acknowledge & Execute** to fire the tool.

---

## 6. Understanding Execution Fallbacks
The UHDC is engineered for maximum reliability. When you click a tool, you may notice the Telemetry Stream outputting different connection methods.

1. **WinRM (Primary):** The console always attempts to use Windows Remote Management first. It is lightning-fast and highly secure.
2. **PsExec (Fallback):** If the target computer's firewall is blocking WinRM, or if the machine is severely locked up, the UHDC will automatically encode your command and deploy it via PsExec. This bypasses the firewall and executes the command as the `SYSTEM` account, guaranteeing the fix goes through.


If both methods fail, the computer is either completely offline, disconnected from the VPN, or experiencing a catastrophic hardware failure.
