# RUTX Multi-VPN - DNS-basiertes Split-Tunneling

DNS-basiertes Multi-Tunnel Split-Tunneling fuer Streaming auf Teltonika RUTX Routern.

## Features

- **Automatisches Geo-Routing**: ARD -> DE Tunnel, SRF -> CH Tunnel, ORF -> AT Tunnel
- **Nur Streaming Devices**: Normale Geraete gehen ins Internet, nur definierte IPs nutzen VPN
- **Mehrere Tunnel gleichzeitig**: WireGuard DE, CH, AT laufen parallel
- **Management VPN Schutz**: WG/MGMT/HOME/VPN Interfaces werden NIEMALS angefasst
- **Home Assistant Integration**: Ein/Aus Schalter, Status, Provisioning Buttons

## Architektur

```
                                RUTX Router
+------------------------------------------------------------------+
|                                                                   |
|   +----------------+     +----------------+     +----------------+ |
|   |   SS_DE        |     |   SS_CH        |     |   SS_AT        | |
|   |   WireGuard    |     |   WireGuard    |     |   WireGuard    | |
|   |   -> Frankfurt |     |   -> Zuerich   |     |   -> Wien      | |
|   +-------+--------+     +-------+--------+     +-------+--------+ |
|           |                      |                      |          |
|           +----------------------+----------------------+          |
|                                  |                                 |
|                          +------+------+                           |
|                          | Routing     |                           |
|                          | Tables      |                           |
|                          | 110/111/112 |                           |
|                          +------+------+                           |
|                                 |                                  |
|                         +-------+-------+                          |
|                         | iptables      |                          |
|                         | MARK Rules    |                          |
|                         | 0x10/11/12    |                          |
|                         +-------+-------+                          |
|                                 |                                  |
|   +-----------------------------+-----------------------------+    |
|   |                     ipset Match                           |    |
|   |  de_ips: ard.de, zdf.de, ...  -> MARK 0x10 -> Table 110  |    |
|   |  ch_ips: srf.ch, rts.ch, ...  -> MARK 0x11 -> Table 111  |    |
|   |  at_ips: orf.at, atv.at, ...  -> MARK 0x12 -> Table 112  |    |
|   +-----------------------------+-----------------------------+    |
|                                 |                                  |
|                         +-------+-------+                          |
|                         |   dnsmasq     |                          |
|                         |   DNS->ipset  |                          |
|                         +-------+-------+                          |
|                                 |                                  |
|                  +--------------+--------------+                   |
|                  |    Source IP Filter         |                   |
|                  |    (Streaming Devices)      |                   |
|                  +--------------+--------------+                   |
|                                 |                                  |
+------------------------------------------------------------------+
                                  |
                  +---------------+---------------+
                  |               |               |
          +-------+------+ +-----+----+ +--------+-------+
          | Apple TV     | | Fire TV  | | Normaler PC   |
          | 192.168.x.100| | .x.101   | | .x.50         |
          | -> VPN       | | -> VPN   | | -> Internet   |
          +--------------+ +----------+ +---------------+
```

## Datenfluss

```
1. Streaming Device (z.B. Apple TV) macht DNS Request fuer "ard.de"
                    |
                    v
2. dnsmasq loest Domain auf -> fuegt IP zu ipset "de_ips" hinzu
                    |
                    v
3. Verbindung zu ard.de IP wird aufgebaut
                    |
                    v
4. iptables PREROUTING:
   - Prueft Source IP (ist es Streaming Device?)
   - Prueft Destination IP (ist sie in de_ips/ch_ips/at_ips?)
   - Setzt MARK (0x10 fuer DE, 0x11 fuer CH, 0x12 fuer AT)
                    |
                    v
5. ip rule: MARK 0x10 -> verwende Routing Table 110
                    |
                    v
6. Routing Table 110: default via SS_DE Interface
                    |
                    v
7. Traffic geht durch WireGuard Tunnel nach Frankfurt
                    |
                    v
8. Surfshark Server in Frankfurt -> ARD Mediathek
```

## Nicht-Streaming Device Fluss

```
1. Normaler PC macht Request zu "ard.de"
                    |
                    v
2. dnsmasq loest auf -> IP in de_ips (spielt keine Rolle)
                    |
                    v
3. iptables PREROUTING:
   - Source IP NICHT in Streaming Devices Liste
   - KEIN MARK gesetzt
                    |
                    v
4. Normale Routing Table (main) wird verwendet
                    |
                    v
5. Traffic geht normal ins Internet (KEIN VPN)
```

## Installation

### 1. Package kopieren

```bash
# Nach /config/packages/rutx_multivpn/
cp -r rutx_multivpn /config/packages/
```

### 2. WireGuard Configs

Surfshark WireGuard Configs herunterladen und umbenennen:

```
profiles/
  wg_DE_surfshark.conf   # Deutschland (Frankfurt)
  wg_CH_surfshark.conf   # Schweiz (Zuerich)
  wg_AT_surfshark.conf   # Oesterreich (Wien)
```

Namenskonvention: `wg_<LAND>_<provider>.conf`

### 3. Home Assistant configuration.yaml

```yaml
homeassistant:
  packages: !include_dir_named packages
```

### 4. SSH Key (falls nicht vorhanden)

```bash
./scripts/setup_ssh_key.sh 192.168.110.1
```

### 5. In Home Assistant

1. RUTX IP eintragen: `input_text.rutx_multivpn_host`
2. Streaming Device IPs: `input_text.rutx_multivpn_streaming_devices`
3. Button "Multi-VPN Setup" druecken
4. Toggle "Multi-VPN Aktiviert" einschalten

## Dateien

```
rutx_multivpn/
  rutx_multivpn.yaml          # HA Package
  profiles/                    # WireGuard Configs
    wg_DE_surfshark.conf
    wg_CH_surfshark.conf
    wg_AT_surfshark.conf
  domains/                     # Streaming Domain Listen
    de_streaming.txt
    ch_streaming.txt
    at_streaming.txt
  scripts/
    rutx_multivpn_cmd.sh       # HA Command Wrapper
    rutx_multivpn_provision.sh # Initial Setup
    rutx-multivpn-setup.sh     # RUTX Setup Script
    rutx-multivpn-cleanup.sh   # Cleanup (mit Schutz!)
    setup_ssh_key.sh           # SSH Key Generator
```

## Home Assistant Entities

### Input Helpers

| Entity | Beschreibung |
|--------|-------------|
| `input_boolean.rutx_multivpn_enabled` | Multi-VPN Ein/Aus |
| `input_text.rutx_multivpn_host` | RUTX IP Adresse |
| `input_text.rutx_multivpn_streaming_devices` | Streaming Device IPs |

### Sensoren

| Entity | Beschreibung |
|--------|-------------|
| `sensor.rutx_multi_vpn_aktiv` | Routing aktiv? |
| `sensor.rutx_multi_vpn_tunnel_de` | DE Tunnel Status |
| `sensor.rutx_multi_vpn_tunnel_ch` | CH Tunnel Status |
| `sensor.rutx_multi_vpn_tunnel_at` | AT Tunnel Status |
| `sensor.rutx_multi_vpn_de_ips` | Anzahl IPs im DE ipset |

### Buttons

| Entity | Beschreibung |
|--------|-------------|
| `button.multi_vpn_setup` | Initial Setup ausfuehren |
| `button.multi_vpn_cleanup` | Konfiguration entfernen |
| `button.multi_vpn_status_aktualisieren` | Status refresh |

## Sicherheit

### Geschuetzte Management VPNs

Folgende Interface-Namen werden NIEMALS angefasst:
- `WG` / `wg`
- `MGMT` / `mgmt`
- `HOME` / `home`
- `VPN` / `vpn`

Das Cleanup Script prueft jeden Interface-Namen gegen diese Blacklist.

### Unsere Tunnel

Alle Streaming Tunnel verwenden das Prefix `SS_`:
- `SS_DE` - Deutschland
- `SS_CH` - Schweiz
- `SS_AT` - Oesterreich

## Troubleshooting

### SSH Verbindung pruefen

```bash
ssh -i /config/.ssh/id_rsa root@192.168.110.1 "echo OK"
```

### Tunnel Status auf RUTX

```bash
ssh root@RUTX_IP "/root/multivpn/vpn-control.sh status"
```

### ipset Inhalt pruefen

```bash
ssh root@RUTX_IP "ipset list de_ips"
```

### Routing Rules pruefen

```bash
ssh root@RUTX_IP "ip rule show"
ssh root@RUTX_IP "ip route show table 110"
```

### dnsmasq Logs

```bash
ssh root@RUTX_IP "logread | grep dnsmasq"
```

## Parallelnutzung mit rutx_vpn

Dieses Package kann parallel zum bestehenden `rutx_vpn` Package laufen:

- Eigene Host-Datei: `/config/.rutx_multivpn_host`
- Eigene Entities: alle mit `rutx_multivpn_` prefixed
- Eigene Scripts: in `/config/packages/rutx_multivpn/scripts/`
- Eigene RUTX Interfaces: `SS_*` (Streaming) vs `vpn_*` (OpenVPN)

**Achtung**: Nicht beide gleichzeitig aktivieren auf demselben RUTX!
