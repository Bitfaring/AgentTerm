# AgentTerm Privacy Policy

_Effective date: November 14, 2026_

## 1. Introduction

This Privacy Policy describes how **AgentTerm** ("the app") handles information when you use the
AgentTerm app for macOS and the AgentTerm app for iPhone (together, "the Software").

AgentTerm is a terminal for AI coding agents. The Mac app runs terminal sessions on your Mac. The
iPhone app is a remote control for those sessions.

The Software is developed and published by an individual developer:

- **Developer:** Manh Pham
- **Contact:** manhpv151090@gmail.com
- **Project page:** https://github.com/manhpham90vn/AgentTerm

## 2. The short version

**What you type, what your terminals show, your files, your folders and your conversations with
coding agents stay on your own devices.** AgentTerm has no account and no advertising, and no server that can read
what you do: the one it has, the relay of the iPhone's notifications through Apple, passes on what
your Mac encrypted for your iPhone and cannot open it (section 4).

The released apps can send two things to the developer through Google's Firebase, and you control
both:

- **Crash reports**, when the app crashes.
- **Usage statistics**, counts of which features are used.

At its first launch the app shows what each is, with a switch for each. Both switches are on; turn
off what you do not agree to, then continue. Nothing is sent before you have done that.

Neither ever contains what a terminal showed, a prompt, a file name or a folder. Section 6 lists
exactly what is sent. Both apps are open source, so this can be checked, and an app you build from
the source yourself sends nothing at all.

## 3. What stays on your devices

- **Terminal sessions.** Their input and output are kept in memory by the AgentTerm host on your Mac
  while a session runs. They are not written to disk by AgentTerm and are not sent to the developer.
- **Your project files and git repositories.** AgentTerm reads and changes them only on your Mac, when
  you browse, edit, stage or commit from the app. When an agent's turn begins and ends, it also looks at
  the folder with git, on your Mac, to show what changed during the turn; Settings > Git > "Show what
  each turn came to" turns this off.
- **Conversation history.** The History tab reads the files that Claude Code, Codex, Antigravity and
  Copilot CLI already keep on your Mac. When an agent's turn ends, AgentTerm reads the end of that
  agent's file for the turn, to show the commands it ran (the same switch turns it off). What it shows
  goes only to your paired devices. AgentTerm does not copy these files elsewhere. A handoff writes a
  summary file into the project folder, under `.agentterm/handoffs/`.
- **The agents' own configuration.** AgentTerm writes into an agent's configuration only when you ask,
  in Settings > Hooks & MCP or with the commands it shows: AgentTerm's MCP server, with the agent's own
  command (`claude mcp add …`), its hooks and, for Claude Code, its status line, for your user and
  every folder; Remove takes them out. For Codex it also turns off the background server Codex's
  sessions share (`codex features disable daemon_auto_start`), a setting of Codex's that holds outside
  AgentTerm too, and Remove turns it on again. To show what each has, the Mac asks each agent for its
  plugins and for AgentTerm's MCP server, asks Codex for its features and whether its shared server
  runs, and reads Claude Code's settings and Codex's `config.toml`, on your Mac only.
- **Your terminal sessions' environment.** Every session AgentTerm starts, a shell's too, names a file
  for the hooks to write what the agent is doing in, and holds a key with which an agent's MCP server
  in it reaches the AgentTerm host on your Mac, to open shells and pages you see as that session. Any
  program you run in that session can use it, on your Mac only. Outside AgentTerm's sessions the hooks
  and the server do nothing.
- **Pairing.** A paired iPhone holds a token in its Keychain. The Mac holds only a hash of it, in
  `~/Library/Application Support/AgentTerm`. You can remove a paired device in the Mac app at any time.
- **Settings.** Your folder list and preferences are stored on the device they belong to.
- **The browser (Mac).** The Mac app's browser keeps what any browser keeps, cookies, sign-ins,
  history and caches, on your Mac, in the profiles you name in Settings > Browser, under
  `~/Library/Application Support/AgentTerm/browser`; each can be cleared or deleted there. Its cookies are encrypted with a key kept in
  your Mac's keychain, under "AgentTerm Safe Storage". A development build of AgentTerm, built from
  source, uses a key of Chromium's own instead and never asks for your keychain. Your own browser's profile is never read.
  Downloads go to your Downloads folder. A picture you send to an agent from a page is saved in that
  project's `.agentterm/shots/` folder. The iPhone sees the tabs' titles and addresses, and a picture
  of a page when you ask for one, from your Mac only.

## 4. Connections the Software makes

- **Between your iPhone and your Mac.** The iPhone app connects only to the Mac you paired it with,
  over your local network or your own Tailscale network. The developer is not part of that
  connection. Tailscale is a separate service with its own privacy policy.
- **Notifications through Apple (iPhone, released app).** While the iPhone app is in the background
  or asleep (it tells your Mac, over their own connection, when it goes to the background and comes
  back), your Mac tells it that an agent is done or needs you through Apple's push service (APNs), by way of a small
  relay the developer runs on Cloudflare, which holds the key Apple asks for. What the notification
  says (the session's name, its folder, what the agent said or asks) is encrypted on your Mac with a
  key your iPhone made for that Mac alone, and only your iPhone can open it: the relay and Apple
  see the iPhone's push token, when a notification is sent, its size, and the address your Mac
  connects from. The relay keeps none of it. "Also While the App Is Closed" in the iPhone's
  Settings turns it off, and "Tell me when an agent is done or needs me" turns off all
  notifications; revoking the iPhone on the Mac forgets its token and key. When a notification was
  handled or read on another device, the Mac asks the relay to take it back from the iPhone: that request
  names the notification only. A build made from the source has no relay and sends nothing this way.
- **The Live Activity through Apple (iPhone, released app).** While agents work, and for 15 minutes
  after the last one stops, the Mac keeps the iPhone's Live Activity up to date through the same relay and Apple. Unlike a notification it
  cannot be encrypted for the iPhone, because iOS draws it from what the push carries: how many
  agents work, wait, are done or stopped, and the names of the sessions that wait or are done. It
  never carries what an agent said. The relay keeps none of it. "Live Activity of the Mac's agents"
  in the iPhone's Settings turns it off.
- **To the services of the coding agents you use.** To show what your account has left (the figures
  the agents show under `/usage` or `/status`), and to know when a schedule set for when your limit
  starts over is to run, the Mac app asks the agent's own service: Anthropic,
  OpenAI (ChatGPT), Google or GitHub. For this it reads the sign-in that the agent keeps on your Mac
  and sends it only to the service that issued it. It is not stored, logged, sent to the iPhone or
  sent to the developer. Starting the host with `agenttermd --no-account-usage` turns this off.
- **To the remotes of your git repositories.** While a folder's Git tab is shown, the Mac asks the
  remotes of that repository for what is new (`git fetch`) every five minutes, so that what is ahead
  and behind stays true. It is git on your Mac that connects, to the remotes your repository names,
  with the sign-in git already has for them; nothing in your folder changes, and nothing about it
  goes to the developer. "Fetch automatically" in Settings turns it off, on the Mac and on the
  iPhone alike; the remotes are then asked only when you fetch, pull or push.
- **The browser (Mac).** The browser loads the pages you, or an agent you allowed, open in it,
  as any browser does: those sites see a visit from your Mac. Words typed into its address bar that
  are not an address are searched for on Google. The agents use it through AgentTerm's MCP server, on
  your Mac only, always: there is no switch for it. No page, no picture and no
  address goes to the developer.
- **The agents themselves.** Claude Code, Codex, Antigravity and Copilot CLI are separate programs
  that you install and sign in to. What they send to their providers is governed by those providers'
  policies, not by this one.

## 5. Permissions on iPhone

- **Camera:** used only to scan the pairing QR code that the Mac app shows. No image is stored or sent.
- **Local network:** used to reach the AgentTerm host on your Mac.

## 6. Data the developer receives

The apps released by the developer (the disk image, the Homebrew cask, TestFlight and the App Store)
include Google's Firebase. Google processes the data below on the developer's behalf; see
[Firebase's privacy information](https://firebase.google.com/support/privacy).

**Usage statistics (Firebase Analytics).** Sent once you have continued past the first-launch screen
with its switch on, which is how it comes.

- The events, and all of them: the app was opened; a session was started, and with which agent
  (Claude Code, Codex, Antigravity, Copilot CLI or a shell); a phone was paired; a conversation was
  handed off, from which agent to which, and whether to another folder (yes or no); the Mac and the
  iPhone were of different versions.
- What Firebase records by itself once usage statistics are on: the first time the app is opened on
  a device, each time a period of use begins, and how long the app was in the foreground.
- What Firebase adds to every event: the app's version, your device's model and system version, your
  language and country, and an identifier that Firebase makes for this installation of the app. It is
  not tied to your name or account, and the advertising identifier is not used.
- Never: anything you type, anything a terminal shows, prompts, file names, folder names, the names
  of your Macs, or anything from the sign-ins of the coding agents. An event has no field that could
  hold such text.

**Crash reports (Firebase Crashlytics).** Sent once you have continued past the first-launch screen
with its switch on, which is how it comes.

- When the app crashes: where in the app's code it happened, the app's version, your device's model
  and system version, and the installation identifier.
- When the host on the Mac stops unexpectedly: only the fact that it did.

**Your choices.** The first time it is opened, the app shows a screen of its own with the two
switches, both on, and one button, Continue. Until you continue, neither kind is sent. Afterwards
both switches are in **Settings > Privacy** on the Mac and under **Privacy** in the Settings tab of
the iPhone app, and a change takes effect at once.

**Builds that send nothing.** An app built from the source code, and the development build
"AgentTerm Dev", contain no Firebase configuration and send nothing, whatever the switches say.

**Other.** If you install the iPhone app from TestFlight or the App Store, Apple may share crash
reports and usage statistics with the developer if you have agreed to that in your device's
settings. If you write to the support address, your message and email address are used only to
answer you.

## 7. Children

The Software is a developer tool and is not directed at children.

## 8. Changes

Changes to this policy are published on this page with a new effective date.

## 9. Contact

Questions about this policy: manhpv151090@gmail.com
