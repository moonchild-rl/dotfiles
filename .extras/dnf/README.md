# DNF / Fedora notes

## VS Code Microsoft repo: do not block system updates

The Microsoft VS Code RPM repo sometimes becomes temporarily unavailable.
Since this can otherwise stop `dnf upgrade` completely, configure the repo to be skipped when unavailable.

Run once per Fedora machine:

```bash
sudo dnf5 config-manager setopt code.skip_if_unavailable=true
```
That writes a repo override to `/etc/dnf/repos.override.d/99-config_manager.repo`
