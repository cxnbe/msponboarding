# cxnmsp onboarding

## Quick Start

### Production (cxnbe/msponboarding)

**Standard Mode:**
```bash
curl -fsSL https://raw.githubusercontent.com/cxnbe/msponboarding/main/src/cxnmsponboarding.sh | bash
```

**Verbose Mode:**
```bash
curl -fsSL https://raw.githubusercontent.com/cxnbe/msponboarding/main/src/cxnmsponboarding.sh | bash -s -- -v
```

### Development (cxnmsp/msponboarding - dev branch)

**Standard Mode:**
```bash
curl -fsSL -o setup-app-registration.ps1 https://raw.githubusercontent.com/cxnbe/msponboarding/refs/heads/dev/src/setup-app-registration.ps1 && pwsh ./setup-app-registration.ps1
```

**Verbose Mode:**
```bash
curl -fsSL -o setup-app-registration.ps1 https://raw.githubusercontent.com/cxnbe/msponboarding/refs/heads/dev/src/setup-app-registration.ps1 && pwsh ./setup-app-registration.ps1 -VerboseMode
```
