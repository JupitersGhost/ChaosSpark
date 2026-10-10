PROJECT := chaos_spark.gpr
BINARY := bin/chaos_spark

PREFIX ?= /usr/local
BINDIR := $(PREFIX)/bin
SHAREDIR := $(PREFIX)/share/chaos-spark

SERVICE := /etc/sv/chaos-spark
STATE := /var/lib/chaos-spark
RUNTIME := /run/chaos-spark
LOGDIR := /var/log/chaos-spark

# Example Raspberry Pi 5 deployment profile.
#
# The device paths, ALSA card, network interface, and USB identifiers below
# describe one tested hardware configuration. Adapt them to the target system;
# they are examples, not universal ChaosSpark requirements.

.PHONY: all build prove clean count install install-service uninstall-service

all: build

build:
	gprbuild -p -P $(PROJECT)

prove:
	gnatprove -P $(PROJECT) \
		--mode=all \
		--level=2 \
		--checks-as-errors=on \
		--report=all

clean:
	gprclean -q -P $(PROJECT) || true
	rm -rf obj bin

count:
	@find . -type f \
		-not -path './obj/*' \
		-not -path './bin/*' \
		-not -path './.git/*' | sort
	@printf "\nFILE COUNT: "
	@find . -type f \
		-not -path './obj/*' \
		-not -path './bin/*' \
		-not -path './.git/*' | wc -l

install: build
	install -Dm755 $(BINARY) $(DESTDIR)$(BINDIR)/chaos-spark
	install -Dm644 web/index.html \
		$(DESTDIR)$(SHAREDIR)/index.html

install-service: install
	getent group chaos-spark >/dev/null 2>&1 || \
		groupadd -r chaos-spark

	id chaos-spark >/dev/null 2>&1 || \
		useradd -r -g chaos-spark -M \
		-d $(STATE) -s /sbin/nologin chaos-spark

	install -d -o chaos-spark -g chaos-spark -m750 $(STATE)
	install -d -o chaos-spark -g chaos-spark -m750 $(LOGDIR)
	install -d -m755 $(SERVICE)
	install -d -m755 $(SERVICE)/log

	if [ ! -s "$(STATE)/chvs.key" ]; then \
		umask 077; \
		openssl rand -hex 32 > "$(STATE)/chvs.key"; \
		chown chaos-spark:chaos-spark "$(STATE)/chvs.key"; \
		chmod 600 "$(STATE)/chvs.key"; \
	fi

	if [ ! -e "$(STATE)/peers" ]; then \
		touch "$(STATE)/peers"; \
		chown chaos-spark:chaos-spark "$(STATE)/peers"; \
		chmod 600 "$(STATE)/peers"; \
	fi

	@printf '%s\n' \
		'#!/bin/sh' \
		'set -eu' \
		'' \
		'STATE=/var/lib/chaos-spark' \
		'RUNTIME=/run/chaos-spark' \
		'WEB=/usr/local/share/chaos-spark' \
		'' \
		'mkdir -p "$$RUNTIME"' \
		'chown chaos-spark:chaos-spark "$$RUNTIME"' \
		'chmod 700 "$$RUNTIME"' \
		'' \
		'BIND_IP="$$(tailscale ip -4 2>/dev/null | head -n1 || true)"' \
		'[ -n "$$BIND_IP" ] || BIND_IP=127.0.0.1' \
		'' \
		'KEY="$$(tr -d "\r\n " < "$$STATE/chvs.key")"' \
		'PEERS="$$(tr -d "\r\n " < "$$STATE/peers" 2>/dev/null || true)"' \
		'' \
		'exec chpst -u chaos-spark env \' \
		'  CHAOS_SPARK_STATE="$$STATE" \' \
		'  CHAOS_SPARK_RUNTIME="$$RUNTIME" \' \
		'  CHAOS_SPARK_WEB_ROOT="$$WEB" \' \
		'  CHAOS_SPARK_BIND_IP="$$BIND_IP" \' \
		'  CHAOS_SPARK_PEERS="$$PEERS" \' \
		'  CHAOS_SPARK_CHVS_KEY_HEX="$$KEY" \' \
		'  CHAOS_SPARK_CHAOSFIELD="/dev/chaosfield" \' \
		'  CHAOS_SPARK_CAMERA="/dev/video0" \' \
		'  CHAOS_SPARK_AUDIO="plughw:CARD=H4,DEV=0" \' \
		'  CHAOS_SPARK_WIFI="wlan0" \' \
		'  /usr/local/bin/chaos-spark' \
		> $(SERVICE)/run

	chmod 755 $(SERVICE)/run

	@printf '%s\n' \
		'#!/bin/sh' \
		'exec chpst -u chaos-spark svlogd -tt /var/log/chaos-spark' \
		> $(SERVICE)/log/run

	chmod 755 $(SERVICE)/log/run

	@printf '%s\n' \
		'# Example hardware: Raspberry Pi hardware RNG' \
		'SUBSYSTEM=="misc", KERNEL=="hwrng", GROUP="chaos-spark", MODE="0640"' \
		'' \
		'# Example hardware: Chaosfield ESP32 with CP2102 USB-to-UART' \
		'SUBSYSTEM=="tty", ATTRS{idVendor}=="10c4", ATTRS{idProduct}=="ea60", ATTRS{serial}=="0001", GROUP="chaos-spark", MODE="0660", SYMLINK+="chaosfield"' \
		'' \
		'# Example hardware: Adesso CyberTrack H4 video interface' \
		'SUBSYSTEM=="video4linux", ATTRS{idVendor}=="0c45", ATTRS{idProduct}=="636b", GROUP="chaos-spark", MODE="0660"' \
		'' \
		'# Example hardware: Adesso CyberTrack H4 audio interface' \
		'SUBSYSTEM=="sound", ATTRS{idVendor}=="0c45", ATTRS{idProduct}=="636b", GROUP="chaos-spark", MODE="0660"' \
		> /etc/udev/rules.d/70-chaos-spark.rules

	udevadm control --reload-rules
	udevadm trigger || true

	ln -sfn $(SERVICE) /var/service/chaos-spark

	@echo
	@echo "chaos-spark installed."
	@echo "CHVS key: $(STATE)/chvs.key"
	@echo "Peers:    $(STATE)/peers"
	@echo "Service:  /var/service/chaos-spark"

uninstall-service:
	rm -f /var/service/chaos-spark
	rm -rf $(SERVICE)
	rm -f /etc/udev/rules.d/70-chaos-spark.rules
	udevadm control --reload-rules || true
