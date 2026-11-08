# FT-891 DigiPi CAT Setup

A small installer for connecting a Yaesu FT-891 to DigiPi through Hamlib `rigctld`.

It creates a stable `/dev/ttyFT891` device name so the setup continues working when Linux changes the adapter from `/dev/ttyUSB0` to `/dev/ttyUSB1` (or another number) after a reboot.

## What it configures

- Detects the FT-891 USB serial adapter by USB vendor/product ID and USB interface.
- Reads the adapter's unique USB serial number instead of assuming a particular serial number.
- Creates `/etc/udev/rules.d/99-ft891.rules`.
- Creates `/etc/systemd/system/rigctld.service`.
- Configures Hamlib model `1036`, 38400 baud, TCP port `4532`.
- Enables and starts `rigctld`.
- Attempts a CAT frequency read and reports the result.
- On DigiPi systems with a read-only root filesystem, temporarily remounts `/` read/write and restores read-only mode when the installer exits.

## Requirements

- DigiPi with the FT-891 connected by its USB CAT interface.
- Hamlib tools installed (`rigctld` and `rigctl`).
- The FT-891 USB serial adapter must identify as Silicon Labs CP2105 USB `10c4:ea70`, interface `00`.
- The default DigiPi service account is `pi`.

## Install on DigiPi

Open a terminal on DigiPi and run these commands one at a time:

```bash
sudo remount
cd /home/pi
git clone https://github.com/WA1PB/FT-891-DigiPi-CAT-Setup.git
cd FT-891-DigiPi-CAT-Setup
chmod +x install.sh
sudo bash ./install.sh
```

The installer also detects a read-only root filesystem and attempts to handle the remount itself. The first `sudo remount` above is included to match DigiPi's normal workflow.

After installation, use the DigiPi homepage **Save Configuration** function if you have made other DigiPi configuration changes.

## Verify after reboot

```bash
ls -l /dev/ttyFT891
readlink -f /dev/ttyFT891
sudo systemctl status rigctld --no-pager
rigctl -m 2 -r localhost:4532 f
```

The symlink may point to either `/dev/ttyUSB0`, `/dev/ttyUSB1`, or another ttyUSB number. That is normal. Applications should use `/dev/ttyFT891`; they should not depend on the changing ttyUSB number.

A successful frequency test returns a frequency in Hz, for example `7101500` means 7.101500 MHz.

## Troubleshooting

### No matching adapter found

- Confirm the FT-891 is powered on and connected with a data-capable USB cable.
- Check `lsusb` and `ls -l /dev/ttyUSB*`.
- Confirm the adapter is the CP2105 interface expected by this installer.
- If your adapter has a different USB ID or interface layout, the udev match needs to be adjusted for that hardware.

### rigctld does not start

```bash
sudo systemctl status rigctld --no-pager
sudo journalctl -u rigctld -n 50 --no-pager
sudo ss -ltnp | grep 4532
```

Check whether another rigctld instance is already using TCP port 4532.

### The service is active but CAT does not respond

```bash
ls -l /dev/ttyFT891
readlink -f /dev/ttyFT891
rigctl -m 2 -r localhost:4532 f
```

Check the FT-891 CAT baud rate and USB connection. This installer configures 38400 baud.

## Uninstall

Run the following commands on DigiPi:

```bash
sudo remount
sudo systemctl disable --now rigctld
sudo rm -f /etc/systemd/system/rigctld.service
sudo rm -f /etc/udev/rules.d/99-ft891.rules
sudo rm -f /dev/ttyFT891
sudo systemctl daemon-reload
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=tty
```

## Notes

- This project is separate from Winlink Propagation Advisor.
- The installer uses the adapter serial number it detects at install time. It does not hard-code one user's serial number.
- Review scripts before running them on a radio computer.
