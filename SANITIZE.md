# SANITIZE

Everything in this repo was published from a live workstation. These are the rules applied
before anything is committed here, and they must be applied to every new log, transcript,
or config dump.

## Rules

| What | Replace with | Why |
|---|---|---|
| Windows user name in paths (`C:\Users\<name>\…`) | `C:\Users\<you>` | identifies the machine owner |
| Home directory shorthand with a real name | `~` | same |
| LAN / internal IP addresses | `<LAN-IP>` | internal topology |
| Peer / machine names | `peer-a`, `peer-b`, … | internal topology |
| Session tokens in URLs (`?token=…`) | `?token=<REDACTED>` | **live credential** |
| API keys, bearer tokens in config | `apiKeyEnv` reference only, never the value | live credential |
| `.credentials.yaml` content | never copy the file | live credential |
| Internal hostnames in LLM provider config | `<LAN-IP>` | internal topology |

## Check before committing

```powershell
# from the repo root — every line should print 0
foreach ($pat in 'C:\\Users\\[^<]', '\b\d{1,3}(\.\d{1,3}){3}\b', 'token=[A-Za-z0-9_\-]{16,}', 'sk-[A-Za-z0-9]{10,}') {
  $n = (Get-ChildItem . -Recurse -File | Select-String -Pattern $pat -EA SilentlyContinue).Count
  "{0,-46} {1}" -f $pat, $n
}
```

## What is fine to publish

- version numbers, file counts, timings, CPU/wall ratios
- OS build numbers, CPU model
- log lines **after** the substitutions above
- `package.json` `dsh.profile.bundles` lists (plugin names are public)

## What must never be published

- `.credentials.yaml`, `cordis.patch.yml` with inline keys, browser tokens
- full session logs (`~/.dsh/sessions/`) — they contain conversation content
- screenshots that show token-bearing URLs in the address bar
