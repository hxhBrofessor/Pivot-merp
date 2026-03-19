# Pivot-MERP

> **Modular, operator-focused SSH pivoting framework for red teamers and penetration testers**

---

## Overview

**Pivot-MERP** is a lightweight, operator-friendly framework for managing SSH-based pivots during red team engagements and penetration tests.

It simplifies:

* SOCKS proxying
* SSH tunneling (local & remote)
* Multi-hop pivoting
* Transparent routing with `sshuttle`
* Session tracking & cleanup

Built for **real-world operations**, not just lab demos.

---

## Features

### Core Capabilities

*  SOCKS proxy pivoting (`ssh -D`)
*  Transparent pivoting (`sshuttle`)
*  Local port forwarding (`ssh -L`)
*  Remote port forwarding (`ssh -R`)
*  Multi-hop chaining (`ProxyJump`)
*  Session tracking & lifecycle management
*  Clean teardown (no orphaned processes)

---

###  Security Improvements

* Safer SSH defaults (no blind trust)
* Dedicated `known_hosts` file
* `--insecure` flag for lab environments
* No unsafe `source` usage
* Controlled process cleanup

---

###  Operator UX

* Simple CLI interface
* Persistent sessions
* Status visibility
* Logging with timestamps
* Multi-target awareness

---

##  Installation

```bash
git clone https://github.com/hxhBrofessor/Pivot-merp.git
cd Pivot-merp
chmod +x pivot.sh
```

Optional:

```bash
sudo ln -s $(pwd)/pivot.sh /usr/local/bin/pivot
```

---

##  Usage

```bash
./pivot.sh [--insecure] <mode> <user> <target> [options]
```

---

##  Target Format

Supports **multi-hop pivoting** using comma-separated hosts:

```bash
jump1,jump2,target
```

Example:

```bash
./pivot.sh socks kali jump1,jump2,internal-host 1080
```

---

##  Modes

---

###  SOCKS Proxy

Create a SOCKS5 proxy for tools like Burp, proxychains, etc.

```bash
./pivot.sh socks <user> <target> <port>
```

Example:

```bash
./pivot.sh socks kali target.internal 1080
```

Multi-hop:

```bash
./pivot.sh socks kali jump1,target.internal 1080
```

---

###  Transparent Pivot (sshuttle)

Route traffic through target network.

```bash
./pivot.sh sshuttle <user> <target> <subnet> [sshuttle options]
```

Example:

```bash
./pivot.sh sshuttle kali target.internal 172.16.0.0/12 --dns
```

Advanced:

```bash
./pivot.sh sshuttle kali jump1,target 10.0.0.0/8 --dns --auto-nets
```

---

###  Local Port Forward

Expose remote service locally.

```bash
./pivot.sh local <user> <target> <local_port> <remote_host> <remote_port>
```

Example:

```bash
./pivot.sh local kali target.internal 8443 127.0.0.1 443
```

---

###  Remote Port Forward

Expose local service to remote host.

```bash
./pivot.sh remote <user> <target> <remote_port> <local_host> <local_port>
```

Example:

```bash
./pivot.sh remote kali target.internal 8080 127.0.0.1 8080
```

---

##  Session Management

---

###  View Active Sessions

```bash
./pivot.sh status
```

Displays:

* Mode (socks / sshuttle / local / remote)
* Target & jump chain
* Ports / routes
* Session health

---

###  Stop a Session

```bash
./pivot.sh stop <user> <target>
```

---

###  Stop Everything

```bash
./pivot.sh stop all
```

 Gracefully closes:

* SSH ControlMaster sessions
* sshuttle processes

---

##  Tool Integration

---

###  Proxychains

Edit:

```bash
sudo nano /etc/proxychains.conf
```

Enable:

```bash
dynamic_chain
socks5 127.0.0.1 1080
```

Run:

```bash
proxychains nmap -sT target.internal
proxychains firefox
```

---

###  Burp Suite

* Set SOCKS proxy:

  * Host: `127.0.0.1`
  * Port: `1080`
* Enable SOCKS in Burp settings

---

##  Security Modes

---

###  Default (Safe)

* Uses local `known_hosts`
* Validates host keys

---

###  Insecure Mode (Lab Only)

```bash
./pivot.sh --insecure socks kali target 1080
```

Disables:

* Host key checking
* Known hosts validation

---

##  Project Structure

```
Pivot-merp/
│
├── pivot.sh
├── README.md
└── .pivot/
    ├── logs/
    ├── *.meta
    └── known_hosts
```

---

##  Example Workflow

```bash
# Step 1: Establish SOCKS pivot
./pivot.sh socks kali jump,target 1080

# Step 2: Use proxychains
proxychains nmap -Pn target.internal

# Step 3: Pivot full subnet
./pivot.sh sshuttle kali jump,target 10.10.0.0/16 --dns

# Step 4: Check sessions
./pivot.sh status

# Step 5: Cleanup
./pivot.sh stop all
```

---

##  Troubleshooting

---

###  DNS Not Resolving

Use:

```bash
--dns
```

---

###  Cannot Connect Through SOCKS

* Verify port is open:

```bash
ss -tulnp | grep 1080
```

---

###  sshuttle Requires Root

Run with sudo:

```bash
sudo ./pivot.sh sshuttle ...
```

---

##  Roadmap

* [ ] Reverse pivoting (SOCKS bind / reverse tunnels)
* [ ] JSON session tracking
* [ ] Plugin/module architecture
* [ ] Auto proxychains integration
* [ ] Burp launcher
* [ ] Route conflict detection
* [ ] OPSEC modes (jitter, shaping)

---

## Disclaimer

This tool is intended for:

* Authorized penetration testing
* Red team engagements
* Lab environments

**Do not use without proper authorization.**

---

##  Author

**hxhBrofessor**
Cyber Warfare | Red Team | Pivot Goblin

---

