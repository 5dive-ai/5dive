## Unreleased — feat(marketplace): a Vultr server connects with one link and a Google sign-in, no server password (DIVE-7756)

- **A server made from the 5dive Vultr app connects itself.** Vultr makes a random one-time code for each new server and puts it in the link on the server's page. Open the link, sign in with Google, tap Connect: the server picks up its link over HTTPS and shows up in your 5dive app. Nothing listens on the server and its password is never asked for. The link works for 24 hours; after that, the command on the self-host page still works.
