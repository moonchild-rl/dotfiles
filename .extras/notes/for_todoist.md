# Source:
# AppImageLauncher release page:
# https://github.com/TheAssassin/AppImageLauncher/releases/tag/v2.2.0
#
# Download the RPM asset, for example:
# appimagelauncher-2.2.0-travis995.0f91801.x86_64.rpm
#
# Todoist official Linux instructions recommend AppImageLauncher,
# and say to use the standard version if the Lite version has issues.

# 1. Install FUSE v2 support for AppImages
sudo dnf install fuse-libs

# 2. Install AppImageLauncher RPM
cd ~/Downloads
sudo dnf --setopt=tsflags=nocrypto install ./appimagelauncher-*.rpm

# 3. Verify AppImageLauncher/ail-cli exists
command -v ail-cli
rpm -q appimagelauncher

# 4. Optional: allow AppImageLauncher to intercept/manage future AppImages
systemctl --user daemon-reload
systemctl --user enable --now appimagelauncherd.service

# 5. Make the downloaded Todoist AppImage executable
chmod u+x ~/Downloads/Todoist-linux-*.AppImage

# 6. Integrate Todoist directly from Downloads
ail-cli integrate ~/Downloads/Todoist-linux-*.AppImage
