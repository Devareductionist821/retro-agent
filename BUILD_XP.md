# Compilazione per Windows XP

Questa guida spiega come compilare `micro-agent` per Windows XP (32-bit) con Zig 0.15.2.

## Requisiti

- Zig 0.15.2 o superiore
- Sistema operativo: Windows, Linux o macOS (per la cross-compilation)

## Metodi di Compilazione

### Metodo 1: Build System Dedicato (Consigliato)

Usa il file `build-xp.zig` che configura automaticamente tutti i parametri per XP:

```bash
zig build --build-file build-xp.zig --prefix xp-build
```

Il binario sarà disponibile in: `xp-build/bin/agentxp.exe`

### Metodo 2: Compilazione Diretta

Compila direttamente specificando tutti i parametri:

```bash
zig build-exe src/main.zig \
  -target x86-windows-gnu \
  -O ReleaseSmall \
  -fstrip \
  -fsingle-threaded \
  --name agentxp
```

### Metodo 3: Build System Principale

Usa il build system principale con target specifico:

```bash
zig build -Dtarget=x86-windows-gnu -Doptimize=ReleaseSmall --prefix xp-build
```

## Parametri di Compilazione

| Parametro | Valore | Descrizione |
|-----------|--------|-------------|
| `-target` | `x86-windows-gnu` | Target Windows XP 32-bit con ABI GNU |
| `-O` | `ReleaseSmall` | Ottimizzazione per dimensione minima |
| `-fstrip` | - | Rimuove simboli di debug |
| `-fsingle-threaded` | - | Disabilita threading (riduce dipendenze) |
| `--stack` | `16777216` | Stack size 16 MB |
| `os_version_min` | `.xp` | Versione minima Windows XP |

## Caratteristiche del Binario

- **Dimensione**: ~750 KB
- **Dipendenze**: Nessuna (staticamente linkato)
- **Compatibilità**: Windows XP SP3+ (32-bit)
- **RAM minima**: 64 MB
- **CPU minima**: Pentium III o superiore

## Compatibilità API

Il binario include shim per API moderne non disponibili su XP:

### RtlGetSystemTimePrecise
```zig
// Disponibile solo da Windows 8+
// Fallback automatico a GetSystemTimeAsFileTime su XP
fn RtlGetSystemTimePrecise() callconv(.winapi) i64 {
    var ft: FILETIME = undefined;
    kernel32.GetSystemTimeAsFileTime(&ft);
    return @bitCast(ft);
}
```

## Limitazioni su Windows XP

### TLS/HTTPS
Windows XP non supporta TLS 1.2+ richiesto dalla maggior parte delle API moderne.

**Soluzioni:**
1. Usa un proxy locale (es. stunnel, nginx) che gestisce TLS
2. Configura `base_url` HTTP se il provider lo supporta
3. Usa modalità `bridge` o `offline` per comunicare tramite un device moderno

Esempio configurazione con proxy locale:
```json
{
  "transport": {
    "api": {
      "provider": "openai",
      "base_url": "http://localhost:8080",
      "api_key": "sk-..."
    }
  }
}
```

### Memoria
XP ha limiti di memoria per processo (2 GB su 32-bit). Il binario è ottimizzato per:
- Stack: 16 MB
- Heap: allocazione dinamica minimale
- Buffer: dimensioni fisse per evitare frammentazione

## Test su Windows XP

### Opzione 1: Macchina Fisica
1. Copia `agentxp.exe` su una macchina Windows XP reale
2. Esegui da cmd.exe: `agentxp.exe --version`

### Opzione 2: Macchina Virtuale
1. Installa VirtualBox o VMware
2. Crea VM con Windows XP SP3
3. Condividi cartella o trasferisci via rete
4. Esegui il binario

### Opzione 3: Wine (Linux)
```bash
# Installa Wine 32-bit
sudo dpkg --add-architecture i386
sudo apt update
sudo apt install wine32

# Esegui il binario
wine agentxp.exe --version
```

## Verifica del Binario

### Controllo Architettura
```bash
# Su Linux
file agentxp.exe
# Output: PE32 executable (console) Intel 80386, for MS Windows

# Su Windows
dumpbin /headers agentxp.exe | findstr machine
# Output: 14C machine (x86)
```

### Test Funzionale
```bash
# Test versione
agentxp.exe --version

# Test help
agentxp.exe --help

# Test modalità interattiva
agentxp.exe --interactive
```

## Risoluzione Problemi

### "Non è un'applicazione Win32 valida"
- **Causa**: Stai eseguendo un binario 32-bit su Windows 64-bit senza supporto
- **Soluzione**: Usa una VM Windows XP 32-bit o abilita WOW64

### "Punto di ingresso non trovato"
- **Causa**: API non disponibile su XP
- **Soluzione**: Ricompila con Zig 0.15.2+ che include gli shim corretti

### Crash all'avvio
- **Causa**: Stack overflow o memoria insufficiente
- **Soluzione**: Verifica RAM disponibile (minimo 64 MB liberi)

### Errore TLS/HTTPS
- **Causa**: XP non supporta TLS 1.2+
- **Soluzione**: Usa proxy locale o modalità offline/bridge

## Build Automatizzata

Script per build automatica multi-target:

```bash
#!/bin/bash
# build-all.sh

echo "Building for Windows XP..."
zig build --build-file build-xp.zig --prefix dist/xp

echo "Building for Windows 7+ (x64)..."
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSmall --prefix dist/win64

echo "Building for Linux (x86)..."
zig build -Dtarget=x86-linux-musl -Doptimize=ReleaseSmall --prefix dist/linux32

echo "Done! Binaries in dist/"
```

## Sicurezza

### Validazione Path
Il binario include whitelist per operazioni file:

```json
{
  "tools": {
    "file_read_allowed_paths": ["C:\\logs\\*", "C:\\data\\*"],
    "file_write_allowed_paths": ["C:\\temp\\agent\\*"],
    "exec_allowed_commands": ["systeminfo", "tasklist"]
  }
}
```

### Sandbox
Su XP, il sandboxing è limitato. Usa:
- Account utente con privilegi minimi
- Cartelle con permessi restrittivi
- Whitelist rigorose per comandi e path

## Riferimenti

- [Zig 0.15.2 Release Notes](https://ziglang.org/download/0.15.2/release-notes.html)
- [Windows XP API Compatibility](https://learn.microsoft.com/en-us/windows/win32/winprog/using-the-windows-headers)
- [Cross-compilation con Zig](https://ziglang.org/learn/overview/#cross-compiling-is-a-first-class-use-case)

## Supporto

Per problemi specifici di Windows XP:
1. Verifica la versione di Zig (deve essere 0.15.2+)
2. Controlla i log di compilazione per warning
3. Testa su VM prima di deployment su hardware legacy
4. Apri una issue su GitHub con dettagli sistema e log
