# Interactive File Sorter

An interactive terminal tool for sorting top-level files into folders based on likely usernames or existing folder names.

The tool scans one folder, suggests username/folder candidates, lets you confirm or edit them, then shows a summary before moving anything.

By default it runs in **dry-run mode**. Files are moved only when you pass `-apply`.

---

## Features

- Scans only the selected folder’s top-level files.
- Ignores hidden files and hidden folders.
- Detects existing subfolders and can match files to them.
- Suggests usernames from common filename patterns:
  - text after `by`
  - text before `original`
  - text inside parentheses
  - beginning of the filename
- Lets you confirm, skip, or edit suggested usernames.
- Shows a final move preview before applying.
- Creates destination folders automatically when needed.
- Avoids simple filename collisions by appending numbers like:
  - `file.txt`
  - `file (1).txt`
  - `file (2).txt`

---

## Installation

Clone the project and (dry-)run it with Go:

```bash
go run . /path/to/folder
```

Apply moves:

```
go run . -apply /path/to/folder
```

Folder-first syntax also works:

```
go run . /path/to/folder -apply
```

With custom worker count:

```
go run . -apply -workers 16 /path/to/folder
```

Using a custom config file:

```
go run . -config ./sorter.config.yaml /path/to/folder
```

### Config file

On first run, the tool creates a config file named:

```
sorter.config.yaml
```

By default this file is created in the current working directory.
