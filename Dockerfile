# syntax=docker/dockerfile:1
FROM archlinux:base

# Firefox's content sandbox uses CLONE_NEWUSER which Docker's default
# seccomp profile blocks -> content processes crash with I/O errors.
ENV MOZ_DISABLE_CONTENT_SANDBOX=1
# No screen readers in a container - skip the accessibility D-Bus.
ENV NO_AT_BRIDGE=1
ENV GTK_OVERLAY_SCROLLING=0

# ── Layer 0: keyring + install helper ──────────────────────────────
# The archlinux:base image is rebuilt monthly; if the mirrors carry packages
# signed with keys newer than the image, every download fails with
# "signature is unknown trust". Refreshing the keyring first avoids that.
RUN pacman -Sy --noconfirm archlinux-keyring && pacman -Su --noconfirm

# pacman aborts the whole transaction on the first unknown package name, which
# makes a rename anywhere in a 40-package list fail the build with no useful
# output. This helper checks each name first, reports the ones that no longer
# exist, and installs the rest.
RUN printf '%s\n' \
  '#!/bin/sh' \
  'ok=""' \
  'for p in "$@"; do' \
  '  if pacman -Si "$p" >/dev/null 2>&1; then' \
  '    ok="$ok $p"' \
  '  else' \
  '    echo "### SKIP (no such package): $p"' \
  '  fi' \
  'done' \
  'if [ -n "$ok" ]; then pacman -S --noconfirm --needed $ok; fi' \
  > /usr/local/bin/pac && chmod +x /usr/local/bin/pac

# ── Layer 1: XFCE desktop + essentials ─────────────────────────────
# Hand-picked instead of the full `xfce4` group (skips games, screensaver,
# ristretto, mousepad, etc). Cache mount keeps packages across rebuilds.
RUN --mount=type=cache,target=/var/cache/pacman/pkg,sharing=locked \
    pac \
      # Core XFCE
      xfce4-session xfce4-panel xfce4-settings xfwm4 xfdesktop xfconf \
      xfce4-terminal thunar xfce4-appfinder xfce4-notifyd \
      xfce4-whiskermenu-plugin \
      # Desktop infrastructure
      dbus mate-polkit xdg-utils \
      xorg-xauth xorg-xrandr xorg-xkbcomp xorg-xsetroot xkeyboard-config \
      # Look & feel
      arc-gtk-theme papirus-icon-theme archlinux-wallpaper \
      # Browser
      firefox \
      # Fonts
      ttf-hack-nerd noto-fonts noto-fonts-emoji cantarell-fonts ttf-dejavu \
      # CLI essentials
      wget curl nano sudo less openssh inetutils iproute2 net-tools \
      iputils traceroute htop lsof zip unzip file jq python \
      ca-certificates gnupg \
 && rm -rf /usr/share/doc/* /usr/share/man/* /var/cache/pacman/pkg/*

# Anything skipped above is cosmetic except these - fail now if one is missing.
RUN for p in xfce4-session xfce4-panel xfwm4 xfdesktop xfce4-terminal \
             firefox dbus xorg-xauth xkeyboard-config; do \
      pacman -Qi "$p" >/dev/null 2>&1 || { echo "MISSING CRITICAL: $p"; exit 1; }; \
    done; echo "core desktop OK"

# ── Layer 2: Perl deps for the KasmVNC vncserver script ────────────
# Everything the vncserver script needs is packaged except
# Hash::Merge::Simple, which is AUR-only. Rather than drag cpan + a build
# toolchain into the image for one tiny pure-Perl module, it's written out
# below. (Arch's perl doesn't reliably ship /usr/bin/cpan, which is what
# broke the earlier version of this layer with exit 127.)
RUN --mount=type=cache,target=/var/cache/pacman/pkg,sharing=locked \
    pac \
      perl perl-datetime perl-datetime-timezone perl-list-moreutils \
      perl-switch perl-try-tiny perl-yaml-tiny \
      perl-io-socket-ssl perl-net-ssleay \
 && rm -rf /var/cache/pacman/pkg/*

# Minimal Hash::Merge::Simple: right-hand values win, nested hashes merge
# recursively. Same contract as the CPAN module for how KasmVNC uses it
# (layering ~/.vnc/kasmvnc.yaml over /etc/kasmvnc/kasmvnc.yaml).
RUN mkdir -p /usr/share/perl5/vendor_perl/Hash/Merge \
 && cat > /usr/share/perl5/vendor_perl/Hash/Merge/Simple.pm << 'PERL'
package Hash::Merge::Simple;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(merge clone_merge);
our $VERSION = '0.051';

sub merge {
    my ($left, @rest) = @_;
    $left = {} unless defined $left;
    return $left unless @rest;

    my $right = shift @rest;
    $right = {} unless defined $right;

    my %merged = %$left;
    for my $key (keys %$right) {
        my $rv = $right->{$key};
        if (ref $rv eq 'HASH' && ref $merged{$key} eq 'HASH') {
            $merged{$key} = merge($merged{$key}, $rv);
        }
        else {
            $merged{$key} = $rv;
        }
    }

    return merge(\%merged, @rest);
}

sub clone_merge {
    require Storable;
    return Storable::dclone(merge(@_));
}

1;
PERL

RUN perl -e 'use lib "/usr/share/perl5/vendor_perl"; use Hash::Merge::Simple qw(merge); use YAML::Tiny; my $r = merge({a=>{x=>1,y=>2}}, {a=>{y=>9},b=>3}); die "merge broken" unless $r->{a}{x}==1 && $r->{a}{y}==9 && $r->{b}==3; print "perl deps OK\n"'

# ── Layer 3: KasmVNC ───────────────────────────────────────────────
# Kasm ships .deb/.rpm/.apk but no pacman package, so unpack the Debian
# bookworm build over the filesystem (this is what the AUR package does).
# Arch's @INC has /usr/share/perl5/vendor_perl, not /usr/share/perl5,
# so the KasmVNC perl modules have to be relocated.
ARG KASM_VERSION=1.4.0
RUN --mount=type=cache,target=/var/cache/pacman/pkg,sharing=locked \
    pac \
      libxfont2 pixman libunwind libjpeg-turbo libwebp libpng freetype2 \
      libbsd libxcrypt-compat libyaml openssl mesa libglvnd \
      libx11 libxext libxfixes libxdamage libxrandr libxtst libxcursor libxi \
      libxshmfence libxau libxdmcp zlib \
 && cd /tmp \
 && curl -fsSL -o kasm.deb \
      "https://github.com/kasmtech/KasmVNC/releases/download/v${KASM_VERSION}/kasmvncserver_bookworm_${KASM_VERSION}_amd64.deb" \
 && bsdtar -xf kasm.deb -C /tmp \
 && bsdtar -xf /tmp/data.tar.* -C / \
 && mkdir -p /usr/share/perl5/vendor_perl \
 && mv /usr/share/perl5/KasmVNC /usr/share/perl5/vendor_perl/ \
 && rm -f /tmp/kasm.deb /tmp/data.tar.* /tmp/control.tar.* /tmp/debian-binary \
 && rm -rf /var/cache/pacman/pkg/*

# The .deb ships kasmvncserver/kasmvncpasswd/kasmvncconfig and expects its
# postinst to create the classic vnc* names. We skipped the postinst, so make
# them here - the entrypoint calls `vncserver`, not `kasmvncserver`.
RUN ln -sf /usr/bin/kasmvncserver /usr/bin/vncserver \
 && ln -sf /usr/bin/kasmvncpasswd /usr/bin/vncpasswd \
 && ln -sf /usr/bin/kasmvncconfig /usr/bin/vncconfig

# Inventory of what the .deb actually put on disk, plus library and perl
# module checks. Deliberately non-fatal: a failure here should tell you what
# is wrong, not hide it behind an empty log and a dead layer.
RUN echo "=== binaries matching vnc/kasm ==="; \
    ls -l /usr/bin/ 2>/dev/null | grep -iE 'vnc|kasm' || echo "NONE FOUND in /usr/bin"; \
    echo "=== KasmVNC perl modules ==="; \
    ls /usr/share/perl5/vendor_perl/KasmVNC/ 2>/dev/null || echo "NO KasmVNC dir in vendor_perl"; \
    echo "=== www assets ==="; \
    ls -d /usr/share/kasmvnc/www 2>/dev/null || echo "NO www dir"; \
    XBIN="$(command -v Xkasmvnc || command -v Xvnc || true)"; \
    echo "=== X server: ${XBIN:-NOT FOUND} ==="; \
    if [ -n "$XBIN" ]; then \
      ldd "$XBIN" | grep 'not found' || echo "X server: all libs resolved"; \
    fi; \
    echo "=== kasmvncpasswd ==="; \
    if [ -x /usr/bin/kasmvncpasswd ]; then \
      ldd /usr/bin/kasmvncpasswd | grep 'not found' || echo "kasmvncpasswd: all libs resolved"; \
    else echo "kasmvncpasswd NOT FOUND"; fi; \
    echo "=== perl -c vncserver ==="; \
    perl -c /usr/bin/kasmvncserver 2>&1 || echo "### PERL CHECK FAILED (see above)"; \
    echo "=== verification complete (non-fatal) ==="

# Default the web client to the "High" quality preset (60fps, quality 7-9)
# instead of "Medium". Values are hardcoded in the bundled ui-*.js.
RUN sed -i 's/\(initSetting("video_quality",\)2)/\13)/g; s/\(updateSetting("video_quality",\)2)/\13)/g' \
      /usr/share/kasmvnc/www/assets/ui-*.js

# ── Layer 4: zrok tunnel ───────────────────────────────────────────
# The openziti install script is apt/dnf-oriented, so grab the release
# tarball directly. Installs the binary as /usr/local/bin/zrok.
RUN set -e; \
    URL="$(curl -fsSL https://api.github.com/repos/openziti/zrok/releases/latest \
          | grep -oE '"browser_download_url": *"[^"]*linux_amd64\.tar\.gz"' \
          | head -1 | cut -d'"' -f4)"; \
    echo "zrok tarball: $URL"; \
    mkdir -p /tmp/zrokx; \
    curl -fsSL "$URL" -o /tmp/zrok.tgz; \
    tar -xzf /tmp/zrok.tgz -C /tmp/zrokx; \
    echo "=== tarball contents ==="; find /tmp/zrokx -type f | head -20; \
    ZBIN="$(find /tmp/zrokx -type f -name 'zrok*' -perm -u+x | head -1)"; \
    [ -n "$ZBIN" ] || { echo "### no zrok binary found in tarball"; exit 1; }; \
    install -m 0755 "$ZBIN" /usr/local/bin/zrok; \
    rm -rf /tmp/zrok.tgz /tmp/zrokx; \
    zrok version

# ── Locale ─────────────────────────────────────────────────────────
RUN sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# ── Pre-bake KasmVNC + XFCE config ─────────────────────────────────
# Bypasses KasmVNC's interactive TTY prompts on first start.
RUN mkdir -p /root/.vnc /root/.config/xfce4/xfconf/xfce-perchannel-xml \
 && printf '#!/bin/sh\nexec xfce4-session\n' > /root/.vnc/xstartup \
 && chmod +x /root/.vnc/xstartup \
 && touch /root/.vnc/.de-was-selected /root/.Xauthority

# XFCE otherwise shows a "Default config or empty panel?" dialog on first
# launch, which is unclickable-ish over a fresh VNC session.
RUN if [ -f /etc/xdg/xfce4/panel/default.xml ]; then \
      cp /etc/xdg/xfce4/panel/default.xml \
         /root/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml; \
    fi

# Font rendering: Hack Nerd Font as monospace, grayscale AA (subpixel
# rendering causes color fringing over VNC - unknown client LCD layout).
RUN cat > /etc/fonts/local.conf << 'FONTCONF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <alias>
    <family>monospace</family>
    <prefer><family>Hack Nerd Font Mono</family></prefer>
  </alias>
  <match target="font">
    <edit mode="assign" name="antialias"><bool>true</bool></edit>
    <edit mode="assign" name="hinting"><bool>true</bool></edit>
    <edit mode="assign" name="hintstyle"><const>hintslight</const></edit>
    <edit mode="assign" name="rgba"><const>none</const></edit>
    <edit mode="assign" name="lcdfilter"><const>lcddefault</const></edit>
    <edit mode="assign" name="embeddedbitmap"><bool>false</bool></edit>
  </match>
</fontconfig>
FONTCONF
RUN fc-cache -f

# KasmVNC YAML config - optimized for tunneled WebSocket access.
# Written to both /etc/kasmvnc/ and /root/.vnc/ because the per-user file
# wins if it exists, and gets regenerated from defaults if it doesn't.
RUN cat > /tmp/kasmvnc.yaml << 'YAML'
network:
  protocol: http
  interface: 0.0.0.0
  websocket_port: 6901
  ssl:
    require_ssl: false
    pem_certificate:
    pem_key:
  udp:
    public_ip: auto
desktop:
  resolution:
    width: 1920
    height: 1080
  allow_resize: true
encoding:
  max_frame_rate: 60
  rect_encoding_mode:
    min_quality: 7
    max_quality: 9
    consider_lossless_quality: 7
  rectangle_compress_threads: auto
  video_encoding_mode:
    jpeg_quality: -1
    webp_quality: -1
    enter_video_encoding_mode:
      time_threshold: 5
      area_threshold: "45%"
    exit_video_encoding_mode:
      time_threshold: 3
    scaling_algorithm: progressive_bilinear
  compare_framebuffer: auto
  hextile_improved_compression: true
runtime_configuration:
  allow_client_to_override_kasm_server_settings: true
  allow_override_standard_vnc_server_settings: true
data_loss_prevention:
  clipboard:
    delay_between_operations: none
    allow_mimetypes:
      - chromium/x-web-custom-data
      - text/html
      - image/png
command_line:
  prompt: false
YAML
RUN mkdir -p /etc/kasmvnc \
 && cp /tmp/kasmvnc.yaml /etc/kasmvnc/kasmvnc.yaml \
 && cp /tmp/kasmvnc.yaml /root/.vnc/kasmvnc.yaml \
 && rm /tmp/kasmvnc.yaml

# Dark theme: GTK + icons + WM. Arc-Dark/Papirus replace Kali-Dark.
RUN cat > /root/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml << 'XML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="Arc-Dark"/>
    <property name="IconThemeName" type="string" value="Papirus-Dark"/>
    <property name="CursorThemeName" type="string" value="Adwaita"/>
    <property name="EnableEventSounds" type="bool" value="false"/>
    <property name="EnableInputFeedbackSounds" type="bool" value="false"/>
  </property>
  <property name="Gtk" type="empty">
    <property name="FontName" type="string" value="Cantarell 10"/>
  </property>
  <property name="Xft" type="empty">
    <property name="DPI" type="int" value="96"/>
    <property name="Antialias" type="int" value="1"/>
    <property name="Hinting" type="int" value="1"/>
    <property name="HintStyle" type="string" value="hintslight"/>
    <property name="RGBA" type="string" value="none"/>
  </property>
</channel>
XML

RUN cat > /root/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml << 'XML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="Arc-Dark"/>
    <property name="title_font" type="string" value="Cantarell Bold 10"/>
    <property name="title_alignment" type="string" value="center"/>
    <!-- Compositor tries GPU ops that fail in containers -->
    <property name="use_compositing" type="bool" value="false"/>
    <property name="vblank_mode" type="string" value="off"/>
    <property name="sync_to_vblank" type="bool" value="false"/>
    <property name="box_move" type="bool" value="false"/>
    <property name="box_resize" type="bool" value="false"/>
    <property name="cycle_preview" type="bool" value="false"/>
    <property name="zoom_desktop" type="bool" value="false"/>
    <property name="zoom_pointer" type="bool" value="false"/>
    <property name="show_dock_shadow" type="bool" value="false"/>
    <property name="show_frame_shadow" type="bool" value="false"/>
    <property name="show_popup_shadow" type="bool" value="false"/>
    <property name="frame_opacity" type="int" value="100"/>
    <property name="inactive_opacity" type="int" value="100"/>
    <property name="move_opacity" type="int" value="100"/>
    <property name="popup_opacity" type="int" value="100"/>
    <property name="resize_opacity" type="int" value="100"/>
    <property name="workspace_count" type="int" value="1"/>
  </property>
</channel>
XML

# Wallpaper path is resolved at build time - archlinux-wallpaper filenames
# change between releases.
RUN cat > /root/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml << 'XML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="desktop-icons" type="empty">
    <property name="style" type="int" value="0"/>
  </property>
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitorVNC-0" type="empty">
        <property name="workspace0" type="empty">
          <property name="last-image" type="string" value="@WALLPAPER@"/>
          <property name="image-style" type="int" value="5"/>
        </property>
      </property>
    </property>
  </property>
</channel>
XML
RUN WALL="$(find /usr/share/backgrounds/archlinux -type f \( -name '*.png' -o -name '*.jpg' \) 2>/dev/null | sort | head -1)" \
 && sed -i "s|@WALLPAPER@|${WALL}|" \
      /root/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml

# Disable Thunar thumbnails (saves CPU + I/O)
RUN cat > /root/.config/xfce4/xfconf/xfce-perchannel-xml/thunar.xml << 'XML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="thunar" version="1.0">
  <property name="misc-thumbnail-mode" type="string" value="THUNAR_THUMBNAIL_MODE_NEVER"/>
  <property name="misc-thumbnail-draw-frames" type="bool" value="false"/>
</channel>
XML

# ── Firefox: suppress first-run warnings and telemetry ─────────────
RUN mkdir -p /usr/lib/firefox/distribution \
 && cat > /usr/lib/firefox/distribution/policies.json << 'JSON'
{
  "policies": {
    "DisableTelemetry": true,
    "DontCheckDefaultBrowser": true,
    "OverrideFirstRunPage": "",
    "OverridePostUpdatePage": "",
    "UserMessaging": {
      "ExtensionRecommendations": false,
      "FeatureRecommendations": false,
      "UrlbarInterventions": false,
      "SkipOnboarding": true,
      "MoreFromMozilla": false
    },
    "Preferences": {
      "datareporting.policy.dataSubmissionEnabled": { "Value": false, "Status": "locked" },
      "toolkit.telemetry.reportingpolicy.firstRun": { "Value": false, "Status": "locked" },
      "browser.shell.checkDefaultBrowser": { "Value": false, "Status": "locked" },
      "app.shield.optoutstudies.enabled": { "Value": false, "Status": "locked" },
      "app.normandy.enabled": { "Value": false, "Status": "locked" }
    }
  }
}
JSON

# ── XFCE default terminal ──────────────────────────────────────────
RUN mkdir -p /etc/xdg/xfce4 \
 && printf 'TerminalEmulator=xfce4-terminal\nTerminalEmulatorDismissed=true\n' \
      > /etc/xdg/xfce4/helpers.rc

# ── Fix XFCE-in-Docker annoyances ──────────────────────────────────
RUN mkdir -p /etc/polkit-1/localauthority/50-local.d \
 && printf '[Allow Colord]\nIdentity=unix-user:*\nAction=org.freedesktop.color-manager.create-device;org.freedesktop.color-manager.create-profile;org.freedesktop.color-manager.delete-device;org.freedesktop.color-manager.delete-profile;org.freedesktop.color-manager.modify-device;org.freedesktop.color-manager.modify-profile\nResultAny=yes\nResultInactive=yes\nResultActive=yes\n' \
      > /etc/polkit-1/localauthority/50-local.d/45-allow-colord.pkla \
 && rm -f /etc/xdg/autostart/xfce4-power-manager.desktop \
          /etc/xdg/autostart/xfce4-screensaver.desktop \
          /etc/xdg/autostart/xscreensaver.desktop \
          /etc/xdg/autostart/light-locker.desktop \
          /etc/xdg/autostart/at-spi-dbus-bus.desktop 2>/dev/null; true

RUN if [ -f /etc/xdg/tumbler/tumbler.rc ]; then \
      sed -i 's/^Disabled=false/Disabled=true/' /etc/xdg/tumbler/tumbler.rc; \
    fi

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 6901
HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -sf http://localhost:6901/ > /dev/null 2>&1 || exit 1

ENTRYPOINT ["/entrypoint.sh"]
