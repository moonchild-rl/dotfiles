## Backup commands
### Backup to external
rsync -aivh --delete "/home/moon/path/to/source/" "/run/media/moon/52344F12344EF90D/path/to/destination/"

### or inspect first with:
rsync -aivh --delete --dry-run "/home/moon/path/to/source/" "/run/media/moon/52344F12344EF90D/path/to/destination/" | less
