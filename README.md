# Pivot-Merp – SSH Pivoting Automation Framework

## Overview

**Pivot-Merp** is a lightweight, operator-focused SSH pivoting framework designed to streamline lateral movement, internal reconnaissance, and controlled access into segmented environments.

It abstracts common SSH pivoting techniques into a single command interface, enabling operators to rapidly transition between:

- SOCKS proxying (proxychains / Burp)
- Local port forwarding (targeted service access)
- Full network tunneling (sshuttle)

Pivot-Merp is built for **red team operations, adversary emulation, and lab environments**, with emphasis on:

- Speed  
- Reusability  
- Low operator friction  
- Clean session management  
- Real-world tradecraft alignment  

---

## Inspiration

Inspired by:

 https://grahamhelton.com/blog/ssh-cheatsheet

That resource provides foundational SSH tradecraft.  
**Pivot-Merp operationalizes those techniques into a repeatable framework for real engagements.**

---

## Core Design Philosophy

Pivot2 follows a layered pivoting model:

| Layer       | Method    | Use Case                          |
|------------|----------|-----------------------------------|
| App Layer  | SOCKS    | Burp, ffuf, proxychains           |
| Targeted   | URL      | Specific services                 |
| Network    | SSHuttle | Full internal recon               |

 Operators choose the right level of access, not just “more access”

---

## Features

### Persistent Control Sessions
- Uses SSH ControlMaster  
- Reuses authenticated sessions  
- Reduces noise + re-authentication  

### Intelligent Route Awareness
- Enumerates internal routes via jump host  
- Extracts private CIDRs automatically  
- Enables informed pivot decisions  

### Pivot Recommendation Engine

```bash
./pivot.sh suggest user host
```

Analyzes environment and recommends:

- sshuttle → multiple internal networks  
- socks → unknown / unstable environments  
- url → targeted service access  

---

### One-Command Full Pivot

```bash
./pivot2.sh full user host
```

Modes:

```bash
auto      # intelligent selection
socks     # force SOCKS pivot
sshuttle  # force full network tunnel
```

Handles:
- session setup  
- route discovery  
- pivot execution  
- operator guidance  

---

### Multi-Mode Pivoting

| Mode     | Description                              |
|----------|------------------------------------------|
| SOCKS    | Proxy-based pivot (proxychains, Burp)    |
| URL      | Local port forwarding                    |
| SSHuttle | Transparent network pivot                |

---

### Auto Port Management
- Detects port collisions  
- Automatically selects next available port  
- Prevents failed pivots  

---

### SOCKS Auto-Reuse
- Detects existing tunnels  
- Reuses active SOCKS sessions  
- Avoids duplicate listeners  

---

### Built-in Visibility

```bash
./pivot.sh status
```

Shows:
- Active control sockets  
- Listening ports  
- sshuttle processes  

---

### Logging

```
~/.pivot/logs/pivot.log
```

Tracks:
- session creation  
- pivot activity  
- errors  

---

## Installation

```bash
chmod +x pivot2.sh
```

Dependencies:

```bash
sudo apt install ssh proxychains sshuttle iproute2
```

---

## Usage

### SOCKS Proxy (Most Common)

```bash
./pivot.sh socks user target_host
```

Configure:

```
proxychains → socks5 127.0.0.1 1080
```

---

### URL Forwarding (Targeted Access)

```bash
./pivot.sh url user target_host internal_ip 443
```

Access:

```
https://127.0.0.1:<port>
```

---

### SSHuttle (Full Network Pivot)

```bash
./pivot.sh sshuttle user target_host X.X.0.0/12 --dns
```

Enables:
- native nmap  
- DNS resolution  
- full internal visibility  

---

### Route Discovery

```bash
./pivot2.sh routes user target_host
```

---

### Pivot Recommendation

```bash
./pivot.sh suggest user target_host
```

---

### One-Command Pivot

```bash
./pivot2.sh full user target_host
```

---

### Status

```bash
./pivot.sh status
```

---

### Stop Pivot

```bash
./pivot.sh stop user target_host
./pivot.sh stop all
```

---

## ⚠️ Important Operational Notes

### SOCKS + Internal DNS

When using SOCKS:

- Internal hostnames may not resolve  

Use:

```bash
https://<internal_ip>
-H "Host: target.domain"
```

Example:

```bash
proxychains curl -k https://x.x.x.x \
-H "Host: test.tesst.io"
```

---

### Tool Behavior Over SOCKS

| Tool  | Behavior                          |
|------|----------------------------------|
| ffuf | Needs tuning (threads ↓)         |
| dirb | More stable                      |
| nmap | Limited (use sshuttle instead)   |

---

### Recommended FFUF Settings (SOCKS)

```
-t 10–25
-rate 50–100
```

---

### When to Switch to SSHuttle

Switch when:
- scanning subnets  
- DNS enumeration needed  
- tools failing over SOCKS  

```bash
./pivot.sh sshuttle user host X.X.0.0/12 --dns
```

---

## Operational Workflow

### Typical Red Team Flow

1. Initial foothold (SSH access)

2. Analyze environment:
```bash
./pivot.sh suggest user host
```

3. Establish pivot:
```bash
./pivot.sh full user host
```

4. Begin recon:
- ffuf  
- nmap  
- Burp Suite  
- custom tooling  

---

## Use Cases

- Red Team Operations  
- Adversary Emulation (ART)  
- Internal Recon  
- Segmented Enterprise Networks  
- OT / ICS Environments  
- Cyber Ranges / Labs (HTB, CPTC)  

---

## OPSEC Considerations

Pivot intentionally balances usability and stealth.

### Observable Artifacts

- SSH control sockets (~/.pivot)  
- Local listening ports  
- sshuttle processes  
- proxychains usage  

---

### Recommendations

- Use SOCKS for low-noise operations  
- Use sshuttle only when needed  

Cleanup:

```bash
./pivot.sh stop all
```

---

## Future Improvements

- Multi-hop auto chaining (jump1,jump2,target)  
- Stealth mode (ephemeral sockets, no disk artifacts)  
- Auto proxychains config injection  
- Burp auto-config helper  
- Session metadata tracking  
- Detection-aware pivot throttling  

---

## Author Notes

Pivot was built to eliminate friction in real-world pivoting scenarios and provide a repeatable, operator-friendly workflow.

It is not just a wrapper around SSH — it is a **decision engine + execution layer for pivoting operations**.
